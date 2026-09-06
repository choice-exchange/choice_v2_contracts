// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {ILaunchpadCore} from "../src/interfaces/ILaunchpadCore.sol";
import {InfinitySettler} from "../src/launchpad/InfinitySettler.sol";
import {LaunchPoolGuardHook} from "../src/launchpad/LaunchPoolGuardHook.sol";
import {PositionLocker} from "../src/launchpad/PositionLocker.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * M4 step 1: the launchpad graduation path onto Choice v2.
 *
 * Deploys `PositionLocker`, `LaunchPoolGuardHook` and `InfinitySettler`. Nothing here touches
 * the launchpad - `setSeederFactory` is the PAD ADMIN's call and is printed at the end for
 * whoever holds that key.
 *
 * All three are born owned by the TIMELOCK, with no post-deploy wiring and no pending-owner
 * window. That works because the locker and the hook each need to know the settler while the
 * settler needs to know both of them, and CREATE3 breaks the circle: its address depends only
 * on the salt, so `computeAddress(SETTLER_SALT)` is exact before the settler exists.
 *
 * forge script script/05_DeployLaunchpadSettler.s.sol:DeployLaunchpadSettler -vv \
 *     --rpc-url $RPC_URL --broadcast
 *
 * No --slow: Injective never serves a receipt, so --slow strands the run after its first tx.
 * No --resume, ever. Re-run instead; every step below is idempotent.
 */
contract DeployLaunchpadSettler is BaseScript {
    bytes32 internal constant LOCKER_SALT = keccak256("CHOICE-V2/PositionLocker/1.0.0");
    // 1.1.0 is plan A0: the LP fee carries the WHOLE 1.00% tier (10000, not 6722) and `settle`
    // calls `ChoiceFeeController.zeroLaunchPoolProtocolFee` so a graduate never pays Choice's
    // protocol fee for even one block. The locker and the guard hook are UNCHANGED and keep
    // their 1.0.0 addresses - which is why a re-deploy needs `setSettler` and `setInitializer`
    // from the timelock, printed at the end of this script.
    bytes32 internal constant SETTLER_SALT = keccak256("CHOICE-V2/InfinitySettler/1.1.0");
    bytes32 internal constant GUARD_HOOK_SALT = keccak256("CHOICE-V2/LaunchPoolGuardHook/1.0.0");

    Create3Factory internal factory;
    uint256 internal outstanding;

    function run() public {
        factory = Create3Factory(readAddress("governance.create3Factory"));
        address timelock = readAddress("governance.timelock");
        address permit2 = readAddress("external.permit2");
        address clPoolManager = readAddress("infinity.clPoolManager");
        address positionManager = readAddress("infinity.clPositionManager");
        address padCore = readAddress("launchpad.core");
        address padTreasury = readAddress("launchpad.treasury");

        requireCode("timelock", timelock);
        requireCode("clPoolManager", clPoolManager);
        requireCode("clPositionManager", positionManager);
        requireCode("launchpad core", padCore);

        _preflightCoreLayout(padCore);

        uint256 pk = deployerKey();

        // CREATE3 addresses depend only on the salt, so the settler's address is known here,
        // before it exists. That is what lets the locker and the hook be constructed already
        // pointing at it - and therefore already owned by the timelock.
        address settler = factory.computeAddress(SETTLER_SALT);
        console.log("[predicted] settler:", settler);

        vm.startBroadcast(pk);

        address locker = _deploy(
            LOCKER_SALT,
            abi.encodePacked(
                type(PositionLocker).creationCode, abi.encode(positionManager, padTreasury, timelock, settler)
            )
        );

        // Without this hook a launch's pool can be created by anyone, at any price, for the
        // cost of gas - see LaunchPoolGuardHook for the attack and why refusing to seed is a
        // wedge rather than a defence.
        address guardHook = _deploy(
            GUARD_HOOK_SALT, abi.encodePacked(type(LaunchPoolGuardHook).creationCode, abi.encode(timelock, settler))
        );

        address deployedSettler = _deploy(
            SETTLER_SALT,
            abi.encodePacked(
                type(InfinitySettler).creationCode,
                abi.encode(padCore, clPoolManager, positionManager, permit2, locker, guardHook, timelock)
            )
        );
        require(deployedSettler == settler, "settler address prediction is wrong");

        vm.stopBroadcast();

        // The settler's own links are set at construction, so those two are assertions rather
        // than steps. The other direction is NOT, on a re-deploy: the locker and the hook were
        // constructed pointing at the PREVIOUS settler and each needs one owner call to follow.
        require(address(InfinitySettler(settler).LOCKER()) == locker, "settler is not wired to the locker");
        require(address(InfinitySettler(settler).hooks()) == guardHook, "settler is not wired to the guard hook");

        writeAddress("choice.positionLocker", locker);
        writeAddress("choice.launchPoolGuardHook", guardHook);
        writeAddress("choice.infinitySettler", settler);

        console.log("");
        console.log("What still has to happen. Nothing below is optional: a graduation touches");
        console.log("every one of these and reverts if any is missing.");
        console.log("");

        _requireLockerSettler(locker, settler);
        _requireHookAllowsSettler(guardHook, settler);
        _requireLaunchPoolGate(guardHook);

        console.log("");
        console.log("  LAUNCHPAD ADMIN on", padCore);
        console.log("     setSeederFactory(%s)", settler);
        console.log("     Only launches created AFTER that call graduate onto v2 - the pad");
        console.log("     snapshots the settler per launch, so in-flight ones keep the CW path.");
        console.log("");

        if (outstanding == 0) {
            console.log("  Everything on the Choice side is wired. Ownership needs nothing:");
            console.log("  all three are timelock-owned from construction.");
        } else {
            console.log(string.concat("  ", vm.toString(outstanding), " timelock step(s) OUTSTANDING - see above."));
            console.log("  Re-run this script after they land; it is idempotent and will confirm them.");
        }
    }

    /// @dev `PositionLocker.settler` is the only address allowed to `register`, and it is
    /// owner-settable precisely so a settler can be replaced. Positions the previous settler
    /// registered are untouched.
    function _requireLockerSettler(address locker, address settler) internal {
        address current = PositionLocker(payable(locker)).settler();
        if (current == settler) {
            console.log("  [ok]   positionLocker.settler");
            return;
        }
        outstanding++;
        console.log("  [TODO] positionLocker still registers for", current);
        _printTimelockPayloads(locker, abi.encodeCall(PositionLocker.setSettler, (settler)));
    }

    /// @dev Without this the settler cannot create the pool at all: the guard permissions
    /// `beforeInitialize` to an allowlist, and a rejected initialize reverts the graduation.
    /// The PREVIOUS settler is deliberately left on the allowlist - it is ours, it holds the
    /// same guarantees, and leaving it there keeps a rollback one pad call rather than three.
    function _requireHookAllowsSettler(address guardHook, address settler) internal {
        if (LaunchPoolGuardHook(guardHook).isInitializer(settler)) {
            console.log("  [ok]   launchPoolGuardHook.isInitializer");
            return;
        }
        outstanding++;
        console.log("  [TODO] the guard hook does not allow this settler");
        _printTimelockPayloads(guardHook, abi.encodeCall(LaunchPoolGuardHook.setInitializer, (settler, true)));
    }

    /// @dev A0/D30. `settle` calls `ChoiceFeeController.zeroLaunchPoolProtocolFee` so a sprout
    /// graduate never pays into Choice's global `protocolFeesAccrued` bucket, and that function
    /// is gated on the pool key carrying this hook. The controller ships with the gate unset
    /// (it is deployed in script 02, before this hook exists) and refuses to run while it is,
    /// so until the timelock sets it EVERY graduation reverts.
    ///
    /// 🔴 Read the controller off the POOL MANAGER, not the address book: only the manager's
    /// current `protocolFeeController` can set a protocol fee, so that is the contract the
    /// settler will actually call.
    function _requireLaunchPoolGate(address guardHook) internal {
        address clPoolManager = readAddress("infinity.clPoolManager");
        address controller = address(IProtocolFees(clPoolManager).protocolFeeController());
        if (controller == address(0)) {
            console.log("  [ok]   the pool manager has no fee controller, so graduates are born at zero");
            return;
        }
        if (address(ChoiceFeeController(payable(controller)).launchPoolGuardHook()) == guardHook) {
            console.log("  [ok]   clFeeController.launchPoolGuardHook");
            return;
        }
        outstanding++;
        console.log("  [TODO] the fee controller's launch-pool gate is not set to this hook");
        console.log("           controller", controller);
        _printTimelockPayloads(
            controller, abi.encodeCall(ChoiceFeeController.setLaunchPoolGuardHook, (IHooks(guardHook)))
        );
    }

    /// @dev Both halves, because matching `execute`'s arguments to the `schedule` they came
    /// from is the whole trick with a `TimelockController`.
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

    /// @dev The settler decodes `creator` and `creatorFeeShareBps` straight out of the core's
    /// storage, because the deployed core exposes no getter for either. Prove the layout on
    /// THIS core before deploying something that depends on it: decode two fields whose value
    /// the core will also tell us through its own getters, and refuse to deploy if they
    /// disagree. A pad redeploy that reordered `Launch` stops here instead of on a live
    /// graduation.
    function _preflightCoreLayout(address padCore) internal view {
        uint256 launchCount = ILaunchpadCore(padCore).launchCount();
        require(launchCount > 0, "launchpad core has no launches to check the layout against");

        uint256 launchId = launchCount - 1;
        bytes32 base = keccak256(abi.encode(launchId, uint256(12)));
        bytes32[] memory words = ILaunchpadCore(padCore).extsload(base, 2);

        uint8 decodedState = uint8(uint256(words[0]));
        uint8 reportedState = uint8(ILaunchpadCore(padCore).getLaunchState(launchId));
        require(decodedState == reportedState, "core layout: state word does not match getLaunchState");

        address decodedToken = address(uint160(uint256(words[1])));
        address reportedToken = ILaunchpadCore(padCore).getLaunchToken(launchId);
        require(decodedToken == reportedToken, "core layout: token word does not match getLaunchToken");

        console.log("[preflight] core storage layout agrees with its getters on launch", launchId);
    }

    /// @dev CREATE3 addresses depend only on the salt, so "already there" is a code check.
    function _deploy(bytes32 salt, bytes memory creationCode) internal returns (address at) {
        at = factory.computeAddress(salt);
        if (at.code.length > 0) {
            console.log("  already deployed, skipping:", at);
            return at;
        }
        address deployed = factory.deploy(salt, creationCode, keccak256(creationCode), 0, "", 0);
        require(deployed == at, "create3 address mismatch");
        console.log("  deployed:", deployed);
    }
}
