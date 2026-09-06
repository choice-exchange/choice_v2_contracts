// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManagerOwner} from "infinity-core/src/interfaces/IPoolManagerOwner.sol";
import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {DirectTransferBurnSink} from "../src/fees/DirectTransferBurnSink.sol";
import {ExchangeSubaccountBurnSink} from "../src/fees/ExchangeSubaccountBurnSink.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";
import {BaseScript} from "./BaseScript.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/**
 * M1 step 1, in place of upstream core scripts 04 and 05.
 *
 * Upstream deploys its stock `ProtocolFeeController`, whose `collectProtocolFee` is onlyOwner
 * and takes an arbitrary recipient - protocol revenue as a trusted manual action. Choice
 * deploys `ChoiceFeeController` instead: same audited fee MATH, inherited unchanged, but the
 * destination of the money is fixed in advance and `harvest` is permissionless (plan §4).
 *
 * Both burn sinks go out too, though the burn leg ships PARKED at treasuryBps = 100% (D10).
 * Nothing is burnt until the auction path is settled per currency, and turning it on is one
 * `setTreasuryBps(5000)` call from the timelock - the sink is already wired at construction.
 *
 * forge script script/02_DeployFeeControllers.s.sol:DeployFeeControllers -vv \
 *     --rpc-url $RPC_URL --broadcast
 *
 * No --slow: Injective never serves a receipt, so --slow strands the run after its first tx.
 * No --resume, ever. Re-run this script instead; every step below is idempotent.
 */
contract DeployFeeControllers is BaseScript {
    bytes32 internal constant DIRECT_SINK_SALT = keccak256("CHOICE-V2/DirectTransferBurnSink/1.0.0");
    bytes32 internal constant EXCHANGE_SINK_SALT = keccak256("CHOICE-V2/ExchangeSubaccountBurnSink/1.0.0");
    // 1.1.0 carries `zeroLaunchPoolProtocolFee` (plan A0, tokenomics D30/D31): a sprout
    // graduate pays Choice no protocol fee, so `protocolFeesAccrued` holds only Choice's own
    // revenue by construction. Bumped on BOTH controllers so a fresh deployment runs one
    // version of this contract; only the CL one has launch pools to gate.
    bytes32 internal constant CL_FEE_CONTROLLER_SALT = keccak256("CHOICE-V2/CLProtocolFeeController/1.1.0");
    bytes32 internal constant BIN_FEE_CONTROLLER_SALT = keccak256("CHOICE-V2/BinProtocolFeeController/1.1.0");

    Create3Factory internal factory;
    address internal timelock;
    address internal treasury;
    uint256 internal outstanding;

    function run() public {
        factory = Create3Factory(readAddress("governance.create3Factory"));
        timelock = readAddress("governance.timelock");
        treasury = readAddress("choice.treasury");
        address clPoolManager = readAddress("infinity.clPoolManager");
        address binPoolManager = readAddress("infinity.binPoolManager");

        requireCode("timelock", timelock);
        requireCode("clPoolManager", clPoolManager);
        requireCode("binPoolManager", binPoolManager);

        uint256 pk = deployerKey();
        vm.startBroadcast(pk);

        // --- burn sinks -------------------------------------------------------------------
        // Stateless and ownerless: it only ever moves its own balance to one hardcoded
        // address, so there is nothing to configure and no backrun payload.
        address directSink = _deploy(DIRECT_SINK_SALT, type(DirectTransferBurnSink).creationCode, "");

        // The fallback sink (D8) reproduces v1's two-call deposit + externalTransfer route.
        // Owned by the timelock from birth - plain OZ Ownable, so no acceptance step - because
        // its only owner action, `setDenom`, is a per-currency governance decision anyway.
        address exchangeSink = _deploy(
            EXCHANGE_SINK_SALT,
            abi.encodePacked(type(ExchangeSubaccountBurnSink).creationCode, abi.encode(timelock)),
            ""
        );

        // --- fee controllers --------------------------------------------------------------
        // The backrun payload matters. Under CREATE3 the constructor's msg.sender is the
        // factory's one-shot proxy child, so `Ownable(msg.sender)` makes that proxy the owner
        // and it can never be called again. The backrun runs FROM the same proxy, which is the
        // only moment it can hand ownership on. `ProtocolFeeController` is Ownable2Step, so
        // this only sets pendingOwner: the timelock MUST call acceptOwnership or the
        // controller is stranded with a dead owner. That is the D2 brick, one level down.
        // `08_VerifyOwnership` is what checks it happened and prints the Safe payload if it
        // has not; run it at the end of every deploy.
        bytes memory toTimelock = abi.encodeWithSelector(Ownable.transferOwnership.selector, timelock);

        address clFeeController = _deploy(
            CL_FEE_CONTROLLER_SALT,
            abi.encodePacked(
                type(ChoiceFeeController).creationCode, abi.encode(clPoolManager, treasury, IBurnSink(directSink))
            ),
            toTimelock
        );
        address binFeeController = _deploy(
            BIN_FEE_CONTROLLER_SALT,
            abi.encodePacked(
                type(ChoiceFeeController).creationCode, abi.encode(binPoolManager, treasury, IBurnSink(directSink))
            ),
            toTimelock
        );

        // --- point the pool managers at them ----------------------------------------------
        // On a FIRST deploy this runs while the DEPLOYER still owns the pool managers, which
        // saves a governance round trip. On a re-run after script 03 the managers sit behind
        // their `PoolManagerOwner` contracts and this becomes a timelock operation, so the
        // payload is printed instead of sent - see `_setController`.
        _setController(clPoolManager, "infinity.clPoolManagerOwner", clFeeController);
        _setController(binPoolManager, "infinity.binPoolManagerOwner", binFeeController);

        vm.stopBroadcast();

        writeAddress("choice.directTransferBurnSink", directSink);
        writeAddress("choice.exchangeSubaccountBurnSink", exchangeSink);
        writeAddress("choice.clFeeController", clFeeController);
        writeAddress("choice.binFeeController", binFeeController);

        _reportLaunchPoolGate(clFeeController);
        _reportOutstanding();
    }

    /// @dev A0/D30. `zeroLaunchPoolProtocolFee` is gated on the pool key carrying the launch
    /// pool's guard hook, and that hook does not exist until script 05 - so the controller
    /// ships with the gate UNSET and a timelock call turns it on. Until it is set, EVERY
    /// graduation reverts: `InfinitySettler.settle` calls the controller and this contract
    /// refuses rather than match a hookless key against `address(0)`.
    ///
    /// Deliberately loud. Failing closed is right - a graduate that quietly paid Choice's
    /// protocol fee would put sprout's revenue into a global bucket nobody can ever unpick -
    /// but it is only safe if the missing step is impossible to miss. `08_VerifyOwnership`
    /// checks the same thing at the end of a deploy.
    function _reportLaunchPoolGate(address clFeeController) internal {
        address guardHook = readAddressOrZero("choice.launchPoolGuardHook");
        if (guardHook == address(0)) {
            console.log("");
            console.log("  [note] the launch-pool gate is unset and the guard hook does not exist yet.");
            console.log("         Run script 05, then come back and run THIS script again for the payload.");
            return;
        }
        address current = address(ChoiceFeeController(payable(clFeeController)).launchPoolGuardHook());
        if (current == guardHook) {
            console.log("");
            console.log("  [ok]   launch-pool gate is set:", guardHook);
            return;
        }

        outstanding++;
        console.log("");
        console.log("  [TODO] the launch-pool gate is NOT set - every graduation will revert.");
        console.log("         Safe -> timelock -> clFeeController.setLaunchPoolGuardHook(%s)", guardHook);
        _printTimelockPayloads(
            clFeeController, abi.encodeCall(ChoiceFeeController.setLaunchPoolGuardHook, (IHooks(guardHook)))
        );
    }

    /// @dev CREATE3 addresses depend only on the salt, so the target address is known before
    /// the deploy and "already there" is a code check rather than a bookkeeping question.
    function _deploy(bytes32 salt, bytes memory creationCode, bytes memory backrun) internal returns (address at) {
        at = factory.computeAddress(salt);
        if (at.code.length > 0) {
            console.log("  already deployed, skipping:", at);
            return at;
        }
        address deployed = factory.deploy(salt, creationCode, keccak256(creationCode), 0, backrun, 0);
        require(deployed == at, "create3 address mismatch");
        console.log("  deployed:", deployed);
    }

    /// @dev Send it if we still own the manager, print the governance payload if we do not.
    ///
    /// 🔴 The `owner()` check is the whole point. After script 03 the pool managers sit behind
    /// their `PoolManagerOwner` contracts, so a plain `setProtocolFeeController` from the
    /// deploy key reverts - and a re-run of this script (which is how a controller is
    /// REPLACED) would die halfway, after the new controller is already on chain and before
    /// anything points at it.
    function _setController(address poolManager, string memory ownerKey, address controller) internal {
        address current = address(IProtocolFees(poolManager).protocolFeeController());
        if (current == controller) {
            console.log("  protocolFeeController already set on", poolManager);
            return;
        }

        address managerOwner = IOwnable(poolManager).owner();
        if (managerOwner == vm.addr(deployerKey())) {
            IProtocolFees(poolManager).setProtocolFeeController(IProtocolFeeController(controller));
            console.log("  setProtocolFeeController on", poolManager, "->", controller);
            return;
        }

        outstanding++;
        console.log("");
        console.log("  [TODO] the pool manager is behind", managerOwner);
        console.log("         it still points at", current);
        console.log("         Safe -> timelock -> %s.setProtocolFeeController(%s)", ownerKey, controller);
        _printTimelockPayloads(
            managerOwner,
            abi.encodeCall(IPoolManagerOwner.setProtocolFeeController, (IProtocolFeeController(controller)))
        );
    }

    /// @dev Both halves, because matching `execute`'s arguments to the `schedule` they came
    /// from is the whole trick with a `TimelockController`. Same shape as script 08's.
    function _printTimelockPayloads(address target, bytes memory payload) internal {
        uint256 delay = readUint("governance.timelockMinDelay");
        console.log(
            string.concat(
                "           1. Safe -> timelock.schedule: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                        target,
                        uint256(0),
                        payload,
                        bytes32(0),
                        bytes32(0),
                        delay
                    )
                )
            )
        );
        console.log(
            string.concat(
                "           2. after ",
                vm.toString(delay),
                "s, anyone -> timelock.execute: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "execute(address,uint256,bytes,bytes32,bytes32)",
                        target,
                        uint256(0),
                        payload,
                        bytes32(0),
                        bytes32(0)
                    )
                )
            )
        );
    }

    function _reportOutstanding() internal view {
        if (outstanding == 0) return;
        console.log("");
        console.log(string.concat(vm.toString(outstanding), " governance step(s) OUTSTANDING - see above."));
        console.log("Re-run this script after they land; it is idempotent and will confirm them.");
    }
}
