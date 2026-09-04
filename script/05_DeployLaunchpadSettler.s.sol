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
import {PositionLocker} from "../src/launchpad/PositionLocker.sol";
import {BaseScript} from "./BaseScript.sol";

/**
 * M4 step 1: the launchpad graduation path onto Choice v2.
 *
 * Deploys `PositionLocker` and `InfinitySettler`, wires them, and hands both to the timelock.
 * Nothing here touches the launchpad - `setSeederFactory` is the PAD ADMIN's call and is
 * printed at the end for whoever holds that key.
 *
 * Ownership, deliberately asymmetric:
 *  - the settler is born owned by the timelock. Its config has working defaults, so there is
 *    no deployer step to do first and therefore no pending-owner window to get wrong.
 *  - the locker cannot be, because `setSettler` has to run after the settler exists and the
 *    settler needs the locker's address to be constructed. So it is deployed owned by the
 *    deployer, wired, and then handed on. `Ownable2Step` means the timelock MUST
 *    `acceptOwnership` - until it does, the deployer still owns the locker.
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
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // The locker holds the seed NFTs. Deployer-owned for now; handed on below.
        address locker = _deploy(
            LOCKER_SALT,
            abi.encodePacked(type(PositionLocker).creationCode, abi.encode(positionManager, padTreasury, deployer))
        );

        address settler = _deploy(
            SETTLER_SALT,
            abi.encodePacked(
                type(InfinitySettler).creationCode,
                abi.encode(padCore, clPoolManager, positionManager, permit2, locker, timelock)
            )
        );

        if (PositionLocker(payable(locker)).settler() != settler) {
            PositionLocker(payable(locker)).setSettler(settler);
            console.log("  locker.setSettler ->", settler);
        }

        // Sets pendingOwner only. The timelock has to accept, from the Safe:
        //   ./script/tools/safe-exec.sh <timelock> schedule/execute -> locker.acceptOwnership()
        if (PositionLocker(payable(locker)).owner() == deployer) {
            Ownable(locker).transferOwnership(timelock);
            console.log("  locker ownership offered to the timelock; it must acceptOwnership()");
        }

        vm.stopBroadcast();

        writeAddress("choice.positionLocker", locker);
        writeAddress("choice.infinitySettler", settler);

        console.log("");
        console.log("Remaining, and neither is ours to send:");
        console.log("  1. timelock (via the Safe): PositionLocker.acceptOwnership() at", locker);
        console.log("  2. LAUNCHPAD ADMIN on", padCore);
        console.log("     setSeederFactory(%s)", settler);
        console.log("     Only launches created AFTER that call graduate onto v2 - the pad");
        console.log("     snapshots the settler per launch, so in-flight ones keep the CW path.");
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
