// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {DirectTransferBurnSink} from "../src/fees/DirectTransferBurnSink.sol";
import {ExchangeSubaccountBurnSink} from "../src/fees/ExchangeSubaccountBurnSink.sol";
import {IBurnSink} from "../src/interfaces/IBurnSink.sol";
import {BaseScript} from "./BaseScript.sol";

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
    bytes32 internal constant CL_FEE_CONTROLLER_SALT = keccak256("CHOICE-V2/CLProtocolFeeController/1.0.0");
    bytes32 internal constant BIN_FEE_CONTROLLER_SALT = keccak256("CHOICE-V2/BinProtocolFeeController/1.0.0");

    Create3Factory internal factory;
    address internal timelock;
    address internal treasury;

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
        // this only sets pendingOwner: the timelock MUST call acceptOwnership (script 04) or
        // the controller is stranded with a dead owner. That is the D2 brick, one level down.
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
        // Done here, while the DEPLOYER still owns the pool managers. After script 03 hands
        // them to the PoolManagerOwner contracts this becomes a timelock operation, so doing
        // it now saves a governance round trip on first deploy and changes nothing later.
        _setController(clPoolManager, clFeeController);
        _setController(binPoolManager, binFeeController);

        vm.stopBroadcast();

        writeAddress("choice.directTransferBurnSink", directSink);
        writeAddress("choice.exchangeSubaccountBurnSink", exchangeSink);
        writeAddress("choice.clFeeController", clFeeController);
        writeAddress("choice.binFeeController", binFeeController);
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

    function _setController(address poolManager, address controller) internal {
        address current = address(IProtocolFees(poolManager).protocolFeeController());
        if (current == controller) {
            console.log("  protocolFeeController already set on", poolManager);
            return;
        }
        IProtocolFees(poolManager).setProtocolFeeController(IProtocolFeeController(controller));
        console.log("  setProtocolFeeController on", poolManager, "->", controller);
    }
}
