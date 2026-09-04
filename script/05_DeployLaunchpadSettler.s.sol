// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
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
    bytes32 internal constant SETTLER_SALT = keccak256("CHOICE-V2/InfinitySettler/1.0.0");
    bytes32 internal constant GUARD_HOOK_SALT = keccak256("CHOICE-V2/LaunchPoolGuardHook/1.0.0");

    Create3Factory internal factory;

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

        // Every link is set at construction, so this is an assertion rather than a step.
        require(PositionLocker(payable(locker)).settler() == settler, "locker is not wired to the settler");
        require(LaunchPoolGuardHook(guardHook).isInitializer(settler), "the guard hook does not allow the settler");
        require(address(InfinitySettler(settler).LOCKER()) == locker, "settler is not wired to the locker");
        require(address(InfinitySettler(settler).hooks()) == guardHook, "settler is not wired to the guard hook");

        writeAddress("choice.positionLocker", locker);
        writeAddress("choice.launchPoolGuardHook", guardHook);
        writeAddress("choice.infinitySettler", settler);

        console.log("");
        console.log("One step remains, and the key is not ours:");
        console.log("  LAUNCHPAD ADMIN on", padCore);
        console.log("     setSeederFactory(%s)", settler);
        console.log("     Only launches created AFTER that call graduate onto v2 - the pad");
        console.log("     snapshots the settler per launch, so in-flight ones keep the CW path.");
        console.log("");
        console.log("  Ownership needs nothing: all three are timelock-owned from construction.");
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
