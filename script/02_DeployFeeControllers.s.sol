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

interface IDirectSinkView {
    function AUCTION() external view returns (address);
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
    // 1.1.0 carries `zeroLaunchPoolProtocolFee` (plan A0, tokenomics D30/D31): a launchpad
    // graduate pays Choice no protocol fee, so `protocolFeesAccrued` holds only Choice's own
    // revenue by construction.
    //
    // 🔴 BOTH salts move this time, and the reason the bin one did not move for 1.1.0 no
    // longer holds. That bump added `zeroLaunchPoolProtocolFee`, which is unreachable on the
    // bin manager (the settler is CL-only), so leaving bin at 1.0.0 cost nothing. This bump
    // changes the CONSTRUCTOR - the fee policy is now an argument - so a bin controller left
    // at its old salt would be a live contract whose policy came from upstream's defaults
    // rather than from the address book, on a chain where the book says zero. Both must move.
    bytes32 internal constant CL_FEE_CONTROLLER_SALT = keccak256("CHOICE-V2/CLProtocolFeeController/1.2.0");
    bytes32 internal constant BIN_FEE_CONTROLLER_SALT = keccak256("CHOICE-V2/BinProtocolFeeController/1.1.0");

    /// @dev Injective's real `ExchangeAuctionFeesAddress`, not a placeholder - it is
    /// `inj1zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3t5qxqh`, swept into the burn auction basket by the
    /// exchange module. Asserted rather than assumed because the whole burn leg is one
    /// hardcoded constant in a contract this script only ever deploys by salt.
    address internal constant AUCTION_ADDRESS = 0x1111111111111111111111111111111111111111;

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

        // The fee policy, per network, from the book rather than from upstream's defaults.
        // Mainnet launches at 0/0 - Choice takes no protocol cut at all, so a partner routing
        // volume against their own liquidity pays only an LP fee they earn straight back -
        // while testnet keeps 330000/300 so the fee path stays exercised. See the constructor.
        uint256 splitRatio = readUint("choice.protocolFeeSplitRatio");
        uint256 dynamicDefault = readUint("choice.defaultProtocolFeeForDynamicFeePool");
        require(dynamicDefault <= type(uint24).max, "defaultProtocolFeeForDynamicFeePool overflows uint24");
        // The book has no uint24 reader, so the narrowing happens once, here, immediately
        // under the bound that makes it safe - rather than twice at the two call sites, where
        // the check would be a scroll away. The constructor bounds it again anyway.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 dynamicDefaultFee = uint24(dynamicDefault);
        console.log("protocol fee split ratio (1e6 = 100%):", splitRatio);
        console.log("default protocol fee, dynamic-fee pools:", dynamicDefault);
        if (splitRatio == 0 && dynamicDefault == 0) {
            console.log("  [note] Choice's protocol fee is PARKED AT ZERO on this network.");
            console.log("         Turning it on later is one timelock call per controller for");
            console.log("         NEW pools, plus one setProtocolFee per pool that already exists.");
        }

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
                type(ChoiceFeeController).creationCode,
                abi.encode(clPoolManager, treasury, IBurnSink(directSink), splitRatio, dynamicDefaultFee)
            ),
            toTimelock
        );
        address binFeeController = _deploy(
            BIN_FEE_CONTROLLER_SALT,
            abi.encodePacked(
                type(ChoiceFeeController).creationCode,
                abi.encode(binPoolManager, treasury, IBurnSink(directSink), splitRatio, dynamicDefaultFee)
            ),
            toTimelock
        );

        // 🔴 Every `_deploy` above returns early when the CREATE3 address already has code, and
        // it does not ask what that code IS. That is correct for a re-run after a dropped
        // receipt and wrong for everything else: `Create3.addressOf(salt)` is not namespaced by
        // `msg.sender`, so any address whitelisted on the factory can place arbitrary code at
        // one of these salts, and this script would then write it into the address book as
        // Choice's fee controller. These are view calls on what is actually there, and they
        // check the CONSTRUCTOR arguments specifically - the fee policy is a constructor
        // argument precisely because nobody can set it afterwards, so it is also the thing that
        // cannot be repaired if it is wrong.
        _verifyController(clFeeController, clPoolManager, splitRatio, dynamicDefaultFee);
        _verifyController(binFeeController, binPoolManager, splitRatio, dynamicDefaultFee);
        require(IDirectSinkView(directSink).AUCTION() == AUCTION_ADDRESS, "direct sink does not burn to the auction");
        require(IOwnable(exchangeSink).owner() == timelock, "exchange sink is not owned by the timelock");

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
    /// protocol fee would put the launchpad's revenue into a global bucket nobody can ever unpick -
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

    /// @dev What a fee controller at one of our salts must be, whether this run deployed it or
    /// adopted it. The owner clause allows either state on purpose: under CREATE3 the
    /// controller is born owned by the factory's one-shot proxy child with the timelock only as
    /// `pendingOwner`, so "owned by the timelock" is only true after the accept that script 08
    /// chases.
    function _verifyController(
        address controller,
        address expectedPoolManager,
        uint256 expectedSplitRatio,
        uint24 expectedDynamicDefault
    ) internal view {
        ChoiceFeeController c = ChoiceFeeController(payable(controller));
        require(c.poolManager() == expectedPoolManager, "fee controller points at the wrong pool manager");
        require(c.treasury() == treasury, "fee controller has the wrong treasury");
        require(c.protocolFeeSplitRatio() == expectedSplitRatio, "fee controller's split ratio is not the book's");
        require(
            c.defaultProtocolFeeForDynamicFeePool() == expectedDynamicDefault,
            "fee controller's dynamic-fee default is not the book's"
        );
        require(
            c.owner() == timelock || c.pendingOwner() == timelock,
            "fee controller is neither owned by nor pending for the timelock"
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
