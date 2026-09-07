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
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
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
    // 1.2.0 is the TESTNET CORE CUTOVER (2026-09-08), and the bump is forced by the LAUNCH ID
    // SPACE rather than by any change to this contract - which is a reason a salt can move that
    // is worth naming, because nothing in the source diff shows it. `_positions` is keyed by
    // `launchId` ALONE, so a second `LaunchpadCore` numbering from 0 re-registers ids the 1.1.0
    // locker already holds (19, 20) and `register` reverts `AlreadyRegistered` INSIDE `settle` -
    // mid-graduation, after every gate has passed. ⇒ ONE LOCKER GENERATION PER CORE GENERATION.
    //
    // Earlier generations, both still live and both still holding positions: 1.1.0 (plan A3, the
    // PULL `collect`+`claim` and a `register` that binds the position to its pool) and 1.0.0,
    // which predates `2cf25cc`, PUSHES on `collect` and whose `register` takes FOUR arguments
    // with no `PoolKey` - see `_requireLockerSpeaksOurAbi` for why that is checked, not assumed.
    bytes32 internal constant LOCKER_SALT = keccak256("CHOICE-V2/PositionLocker/1.2.0");
    // 1.3.0 is the same cutover, and it had no choice: the settler holds BOTH `CORE` and `LOCKER`
    // as immutables, so a new core forces a new settler and so does a new locker. This salt can
    // never lag either of them.
    //
    // What the previous generations carried: 1.2.0 was plan A0 - the LP fee is the WHOLE 1.00%
    // tier (10000, not the 6722 that composited to 1% alongside a protocol fee) and `settle`
    // calls `ChoiceFeeController.zeroLaunchPoolProtocolFee`, so a graduate never pays Choice's
    // protocol fee for even one block. 1.1.0 is DEAD - same code, wrong locker.
    bytes32 internal constant SETTLER_SALT = keccak256("CHOICE-V2/InfinitySettler/1.3.0");
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
        // 🔑 B6 BY CONSTRUCTION. This argument becomes `PositionLocker.launchpadTreasury`, the
        // address the non-creator share of every graduated pool's LP fees is credited to - which
        // under D30 IS the launchpad's burn sink, not the pad's own FeeTreasury. It used to read
        // `launchpad.treasury` and therefore had to be corrected by a timelock
        // `setLaunchpadTreasury` after every deploy; that step was forgotten once already and the
        // fees went somewhere that does not burn, silently, while every crank reported success.
        // Reading the sink directly makes a fresh locker born correct. The post-deploy assertion
        // below still prints the timelock payload if the two ever drift.
        address lockerTreasury = readAddress("choice.buybackBurnSink");

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
                type(PositionLocker).creationCode, abi.encode(positionManager, lockerTreasury, timelock, settler)
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
        _requireLockerSpeaksOurAbi(locker);
        require(address(InfinitySettler(settler).hooks()) == guardHook, "settler is not wired to the guard hook");

        writeAddress("choice.positionLocker", locker);
        writeAddress("choice.launchPoolGuardHook", guardHook);
        writeAddress("choice.infinitySettler", settler);

        console.log("");
        console.log("What still has to happen. Nothing below is optional: a graduation touches");
        console.log("every one of these and reverts if any is missing.");
        console.log("");

        _requireLockerSettler(locker, settler);
        _requireLockerTreasury(locker);
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

    /// @dev B6. `launchpadTreasury` is the launchpad's revenue feed (D30): `collect` credits the
    /// non-creator share of a graduated position's LP fees to it, and the sink is what turns that
    /// into a burn. A fresh locker is now BORN pointing at the sink (see `run`), so this is an
    /// assertion rather than a step - but it stays, because a SINK REDEPLOY still moves this
    /// field on every locker generation that already exists, and a locker pointing at a
    /// superseded sink is completely silent: `collect` works, `claim` works, the cranker reports
    /// success, and the money simply lands somewhere that never burns.
    function _requireLockerTreasury(address locker) internal {
        address want = readAddress("choice.buybackBurnSink");
        address current = PositionLocker(payable(locker)).launchpadTreasury();
        if (current == want) {
            console.log("  [ok]   positionLocker.launchpadTreasury");
            return;
        }
        outstanding++;
        console.log("  [TODO] positionLocker pays the launchpad share to", current);
        console.log("           the current burn sink is", want);
        _printTimelockPayloads(locker, abi.encodeCall(PositionLocker.setLaunchpadTreasury, (want)));
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

    /// @dev A0/D30. `settle` calls `ChoiceFeeController.zeroLaunchPoolProtocolFee` so a launchpad
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
        // 🔴 A staticcall, not an interface call. Mid-migration the manager still points at
        // the PREVIOUS controller, which has no `launchPoolGuardHook` at all - and a plain
        // call to a missing selector reverts, which would take this whole script down AFTER
        // the settler is already on chain. A controller that cannot answer is exactly the
        // "outstanding" case, so it has to be reported rather than thrown.
        (bool answered, bytes memory data) = controller.staticcall(abi.encodeWithSignature("launchPoolGuardHook()"));
        if (answered && data.length == 32 && abi.decode(data, (address)) == guardHook) {
            console.log("  [ok]   clFeeController.launchPoolGuardHook");
            return;
        }
        outstanding++;
        if (!answered) {
            console.log("  [TODO] the live fee controller has no launch-pool gate - it predates A0.");
            console.log("           Point the pool manager at the 1.1.0 controller first (script 02).");
        } else {
            console.log("  [TODO] the fee controller's launch-pool gate is not set to this hook");
        }
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

    /// @dev 🔴 The settler and the locker must agree on `register`, and a mismatch is SILENT.
    ///
    /// `InfinitySettler.LOCKER` is immutable and the locker's `settler` is a setter, so the two
    /// look independently upgradeable - and they are not. `2cf25cc` changed `register` from
    /// four arguments to five (it now binds the position to its `PoolKey`), which changed the
    /// SELECTOR. A settler built from `main` calling a locker deployed before that commit hits
    /// no function at all, falls through to a contract with no `fallback`, and reverts with
    /// EMPTY returndata - inside `settle`, inside `triggerGraduation`, with every gate and
    /// every canary having passed. It cost a full graduation to find, on testnet, on 2026-09-06.
    ///
    /// Checked against the locker THIS RUN will wire the settler to, not the one in the address
    /// book: `_deploy` reuses whatever already sits at `LOCKER_SALT`, so a stale salt is exactly
    /// the case that has to fail here.
    ///
    /// 🔑 The check is a NAMED error. `register` is `onlyCore`-shaped: called from anywhere
    /// else it reverts `NotSettler()`. So `NotSettler` coming back IS proof the selector
    /// exists, and empty returndata IS proof it does not. A `code.length` check cannot tell
    /// those apart, and neither can reading the address book.
    function _requireLockerSpeaksOurAbi(address locker) internal view {
        PoolKey memory probe;
        (bool ok, bytes memory ret) =
            locker.staticcall(abi.encodeCall(PositionLocker.register, (0, 0, address(0), 0, probe)));
        require(!ok, "locker.register did not revert from a non-settler - is this a PositionLocker?");
        require(
            ret.length >= 4 && bytes4(ret) == PositionLocker.NotSettler.selector,
            string.concat(
                "locker at ",
                vm.toString(locker),
                " does not implement this repo's register(uint256,uint256,address,uint16,PoolKey)",
                " - it predates contracts 2cf25cc. Bump LOCKER_SALT and deploy the pull version (plan A3)."
            )
        );
        console.log("[check] the locker at LOCKER_SALT speaks this repo's register()");
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
