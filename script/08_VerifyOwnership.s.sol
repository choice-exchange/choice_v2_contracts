// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {BaseScript} from "./BaseScript.sol";
import {ISafe} from "./interfaces/ISafe.sol";

/// @dev Read-only slices of contracts this script must never depend on the version of. The
/// launch-pool gate is read by raw staticcall instead, because a controller deployed before
/// plan A0 does not have that function and a missing selector reverts.
interface IPositionLockerView {
    function settler() external view returns (address);
}

interface ILaunchPoolGuardHookView {
    function isInitializer(address) external view returns (bool);
}

/// @dev The role ids are read FROM THE DEPLOYED CONTRACT rather than recomputed here. A local
/// `keccak256("PROPOSER_ROLE")` would agree with a contract that is not an OpenZeppelin
/// `TimelockController` at all; asking the timelock for its own constants means anything else
/// reverts instead of quietly passing.
interface ITimelockView {
    function PROPOSER_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function CANCELLER_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getMinDelay() external view returns (uint256);
}

interface IPausableRoleView {
    function hasPausableRole(address account) external view returns (bool);
}

interface ICreate3FactoryView {
    function isUserWhitelisted(address user) external view returns (bool);
}

/**
 * The last step of every deploy, and the only one that fails loudly if the deploy is not
 * actually finished.
 *
 * `02_DeployFeeControllers` deploys the fee controllers through CREATE3, so each constructor
 * sees the factory's one-shot proxy child as `msg.sender` and `Ownable(msg.sender)` makes that
 * child the owner. The backrun payload calls `transferOwnership(timelock)` - but
 * `ProtocolFeeController` is `Ownable2Step`, so that only sets `pendingOwner`. Until the
 * timelock calls `acceptOwnership`, the controller is owned by a proxy child that can never be
 * called again: a live contract holding protocol revenue with nobody able to change the
 * treasury, the split or the sink. That is D2's brick one level down.
 *
 * This script is read-only. It broadcasts nothing and holds no key: it reads the address book,
 * checks every contract that should be behind the timelock, and prints the Safe -> timelock
 * calldata for anything still outstanding. It exits non-zero if any of them is.
 *
 *   NETWORK=injective_testnet forge script script/08_VerifyOwnership.s.sol:VerifyOwnership \
 *       -vv --rpc-url $RPC_URL
 *
 * A key absent from the book is SKIPPED rather than failed, so the script is runnable part way
 * through a deploy. A key that is present must be correct.
 *
 * 🔴 WHAT THIS ADDED IN THE 2026-09-08 AUDIT PASS (findings G-2, G-3, G-4, G-8, G-10), because
 * ownership alone was never the whole question:
 *
 *   1. The timelock's DELAY and ROLES are read off the chain and compared to the book. Under
 *      CREATE3 the timelock's address is a pure function of the salt and this script's own
 *      predecessor adopted whatever had code there, so "a timelock exists at the right address"
 *      was never evidence that it is OUR timelock. Now the Safe must hold PROPOSER and
 *      CANCELLER, the executor role must be open, and no deploy key may hold anything.
 *   2. The SAFE's owners and threshold are compared to the book. Same reason: script 01 skips a
 *      Safe that already has code.
 *   3. The mainnet delay floor is ONE HOUR and the live delay must EQUAL the book. The floor
 *      used to be 24h while the book said 3600, so this script failed on a correct deploy and
 *      the fix under pressure would have been to edit the constant. The delay is a decision
 *      recorded in the book and pinned by a test; this checks the chain agrees with it.
 *   4. STANDING-HYGIENE items - the per-owner canceller grants, the pause role, and the CREATE3
 *      factory's whitelist and ownership - are notes until `governance.deployComplete` is true
 *      in the book, and failures after it. They are required by the END of a deploy, not
 *      immediately, so failing on them mid-deploy would block the very phases that have to run
 *      first. Flipping that flag is a reviewed line in a diff.
 */
contract VerifyOwnership is BaseScript {
    /// @dev `acceptOwnership()`.
    bytes4 internal constant ACCEPT_OWNERSHIP = 0x79ba5097;

    uint256 internal constant MAINNET_CHAIN_ID = 1776;

    /// @dev The timelock delay is the ONLY barrier between a compromised Safe and every
    /// contract here: the executor set is `[address(0)]`, the open role, so once an operation
    /// has sat out its delay anybody can execute it.
    ///
    /// 🔴 ONE HOUR, decided 2026-09-08, and this is a FLOOR rather than the value - the value
    /// lives in `governance.timelockMinDelay` and is checked against the chain below. An hour
    /// was chosen over 24h because the delay is also the UNPAUSE latency (`unpausePoolManager`
    /// is `onlyOwner` and the owner is this timelock) and a new DEX carrying partner flow
    /// cannot be down for a day. What it costs is the window in which a hostile or mistaken
    /// proposal can be spotted and cancelled - which is why the per-owner CANCELLER grants
    /// below stopped being optional in the same decision, and why `timelockTargetDelay`
    /// records the raise to 24h that follows once the DEX is settled.
    uint256 internal constant MAINNET_MIN_TIMELOCK_DELAY = 1 hours;

    /// @dev Safe 1.4.1 is what the address book's `safeSingletonL2` is, on both nets, verified
    /// by `VERSION()` on chain. A different version is not necessarily wrong, so it warns.
    string internal constant EXPECTED_SAFE_VERSION = "1.4.1";

    address internal timelock;
    uint256 internal delay;
    uint256 internal chainId;
    bool internal deployComplete;

    uint256 internal checked;
    uint256 internal skipped;
    uint256 internal outstanding;
    uint256 internal wrong;

    function run() public {
        timelock = readAddress("governance.timelock");
        requireCode("timelock", timelock);
        delay = readUint("governance.timelockMinDelay");
        chainId = readUint("chainId");
        deployComplete = readBoolOrFalse("governance.deployComplete");

        console.log("timelock:", timelock);
        console.log("chain:   ", chainId);
        console.log(
            deployComplete
                ? "phase:    DEPLOY COMPLETE - standing hygiene is enforced"
                : "phase:    mid-deploy - standing hygiene is reported, not enforced"
        );
        console.log("");

        console.log("Behind the timelock directly");
        // ⛔ `choice.directTransferBurnSink` is absent on purpose: it carries no `Ownable` at
        // all, by design - it holds nothing and forwards to a constructor-fixed address. The
        // two sinks that DO have an owner are both here.
        //
        // 🔑 `infinity.clPositionDescriptor` is here as of the 09-08 audit (G-10). It is
        // `Ownable` - `setBaseTokenURI` and `setTokenURIContract` decide what every position
        // NFT renders as - it is correctly timelock-owned on testnet, and nothing would have
        // noticed if mainnet's was not.
        string[13] memory timelockOwned = [
            "choice.clFeeController",
            "choice.binFeeController",
            "choice.infinitySettler",
            "choice.positionLocker",
            "choice.launchPoolGuardHook",
            "choice.choiceRouter",
            "choice.exchangeSubaccountBurnSink",
            "choice.buybackBurnSink",
            "infinity.vault",
            "infinity.universalRouter",
            "infinity.clPoolManagerOwner",
            "infinity.binPoolManagerOwner",
            "infinity.clPositionDescriptor"
        ];
        for (uint256 i; i < timelockOwned.length; ++i) {
            _requireOwnedBy(timelockOwned[i], timelock, "the timelock");
        }

        // Safe -> Timelock -> PoolManagerOwner -> PoolManager (script 03). The owner contracts
        // carry `PausableRole`, which is why the pool managers sit behind them rather than
        // behind the timelock directly - an emergency pause should not need the full delay.
        console.log("");
        console.log("Behind their PoolManagerOwner contracts");
        _requireOwnedByBookEntry("infinity.clPoolManager", "infinity.clPoolManagerOwner");
        _requireOwnedByBookEntry("infinity.binPoolManager", "infinity.binPoolManagerOwner");

        console.log("");
        _checkGovernance();

        console.log("");
        _checkLaunchPoolWiring();

        console.log("");
        _checkPauser();

        console.log("");
        _checkCreate3Factory();

        _report();
    }

    // -------------------------------------------------------------------------------------
    // Governance: the Safe, the timelock's roles, the delay
    // -------------------------------------------------------------------------------------

    /// @dev The three questions ownership checks never asked: is the Safe the one the book
    /// describes, does the timelock hand out exactly the roles script 01 intended, and does the
    /// chain's delay match the decision recorded in the book.
    ///
    /// 🔴 Why it matters that this is checked rather than assumed. `Create3.addressOf(salt)` is
    /// NOT namespaced by `msg.sender`, so any address whitelisted on the factory can place
    /// arbitrary code at the timelock's salt; script 01's idempotency check is
    /// `if (timelock.code.length > 0) skip`, and it would then write that address into the book
    /// and every later script would obey it. A timelock whose proposer is somebody else passes
    /// every ownership check in this file and fails the first line of this one.
    function _checkGovernance() internal {
        console.log("Governance shape");

        address safe = readAddressOrZero("governance.safe");
        ITimelockView tl = ITimelockView(timelock);

        // --- the delay ---------------------------------------------------------------------
        checked++;
        uint256 live = tl.getMinDelay();
        if (live != delay) {
            wrong++;
            console.log("  [WRONG] timelock.getMinDelay() disagrees with the book");
            console.log(string.concat("            chain ", vm.toString(live), "s, book ", vm.toString(delay), "s"));
            console.log("            The book is the decision and a test pins it. Either the raise was");
            console.log("            executed and the book was not updated, or this is not our timelock.");
        } else if (chainId == MAINNET_CHAIN_ID && delay < MAINNET_MIN_TIMELOCK_DELAY) {
            wrong++;
            console.log(string.concat("  [WRONG] ", vm.toString(delay), "s is below the mainnet floor of 1h"));
            console.log("            The executor role is open, so the delay is the only barrier there is.");
        } else {
            console.log(string.concat("  [ok]    timelock delay ", vm.toString(delay), "s, chain agrees"));
            uint256 target = readUintOrZero("governance.timelockTargetDelay");
            if (target > delay) {
                console.log(
                    string.concat(
                        "  [note]  a raise to ",
                        vm.toString(target),
                        "s is planned - timelock.updateDelay is onlySelf, so it is scheduled"
                    )
                );
                console.log("            through the timelock, and the book and its test move in the same PR.");
            }
        }

        // --- the Safe ----------------------------------------------------------------------
        if (safe == address(0) || safe.code.length == 0) {
            skipped++;
            console.log("  [skip]  governance.safe is not in the book yet");
        } else {
            _checkSafe(safe);
        }

        // --- the timelock's roles ----------------------------------------------------------
        bytes32 proposer = tl.PROPOSER_ROLE();
        bytes32 executor = tl.EXECUTOR_ROLE();
        bytes32 canceller = tl.CANCELLER_ROLE();
        bytes32 admin = tl.DEFAULT_ADMIN_ROLE();

        if (safe != address(0)) {
            _role(tl, proposer, safe, true, "the Safe holds PROPOSER_ROLE");
            _role(tl, canceller, safe, true, "the Safe holds CANCELLER_ROLE");
        }
        // `executors = [address(0)]` is OpenZeppelin's open role: once an operation has sat out
        // its delay anybody may execute it, so a matured action cannot be stranded by absent
        // signers. That is deliberate and is checked as such.
        _role(tl, executor, address(0), true, "EXECUTOR_ROLE is open");

        // Nothing outside the Safe may propose, cancel or administer. `admin = address(0)` in
        // the constructor means the timelock granted DEFAULT_ADMIN only to itself, so a deploy
        // key holding any of these would mean this is not the timelock script 01 deployed.
        address[2] memory deployKeys =
            [readAddressOrZero("governance.deployerEOA"), readAddressOrZero("governance.create3DeployerEOA")];
        string[2] memory deployKeyNames = ["deployerEOA", "create3DeployerEOA"];
        for (uint256 i; i < deployKeys.length; ++i) {
            if (deployKeys[i] == address(0)) continue;
            _role(tl, proposer, deployKeys[i], false, string.concat(deployKeyNames[i], " holds no PROPOSER_ROLE"));
            _role(tl, canceller, deployKeys[i], false, string.concat(deployKeyNames[i], " holds no CANCELLER_ROLE"));
            _role(tl, admin, deployKeys[i], false, string.concat(deployKeyNames[i], " holds no DEFAULT_ADMIN_ROLE"));
        }
        if (safe != address(0)) {
            _role(tl, admin, safe, false, "the Safe holds no DEFAULT_ADMIN_ROLE");
        }

        // --- the per-owner cancellers (G-3) -------------------------------------------------
        // 🔴 The Safe is the only proposer AND the only canceller, so a proposal from a
        // compromised or mistaken Safe can be cancelled only by that same Safe: the delay is a
        // countdown rather than a veto window. Granting CANCELLER_ROLE to each individual owner
        // means any ONE honest signer can stop a bad operation inside the delay, which is what
        // makes a one-hour delay worth having at all. It is one scheduled batch, and it grants
        // no power to move anything - a canceller can only stop.
        address[] memory owners = readAddressArrayOrEmpty("governance.safeSigners");
        if (owners.length == 0) {
            skipped++;
            console.log("  [skip]  governance.safeSigners is empty - cannot check per-owner cancellers");
        } else {
            uint256 missing;
            for (uint256 i; i < owners.length; ++i) {
                if (!tl.hasRole(canceller, owners[i])) missing++;
            }
            if (missing == 0) {
                checked++;
                console.log("  [ok]    every Safe owner holds CANCELLER_ROLE");
            } else {
                address[] memory targets = new address[](missing);
                bytes[] memory payloads = new bytes[](missing);
                uint256 n;
                for (uint256 i; i < owners.length; ++i) {
                    if (tl.hasRole(canceller, owners[i])) continue;
                    targets[n] = timelock;
                    payloads[n] = abi.encodeWithSignature("grantRole(bytes32,address)", canceller, owners[i]);
                    n++;
                }
                _standing(
                    string.concat(vm.toString(missing), " Safe owner(s) do NOT hold CANCELLER_ROLE"),
                    "any single honest signer should be able to cancel inside the delay"
                );
                _printTimelockBatchPayloads(targets, payloads);
            }
        }
    }

    function _checkSafe(address safe) internal {
        checked++;
        uint256 bookThreshold = readUint("governance.safeThreshold");
        address[] memory bookOwners = readAddressArrayOrEmpty("governance.safeSigners");

        uint256 liveThreshold = ISafe(safe).getThreshold();
        address[] memory liveOwners = ISafe(safe).getOwners();

        bool ok = liveThreshold == bookThreshold && liveOwners.length == bookOwners.length;
        if (ok) {
            for (uint256 i; i < bookOwners.length; ++i) {
                if (!ISafe(safe).isOwner(bookOwners[i])) {
                    ok = false;
                    break;
                }
            }
        }

        if (ok) {
            console.log(
                string.concat(
                    "  [ok]    Safe is ",
                    vm.toString(liveThreshold),
                    "-of-",
                    vm.toString(liveOwners.length),
                    ", owners match the book"
                )
            );
        } else {
            wrong++;
            console.log("  [WRONG] the Safe on chain is not the one the book describes");
            console.log(
                string.concat(
                    "            chain ",
                    vm.toString(liveThreshold),
                    "-of-",
                    vm.toString(liveOwners.length),
                    ", book ",
                    vm.toString(bookThreshold),
                    "-of-",
                    vm.toString(bookOwners.length)
                )
            );
            for (uint256 i; i < liveOwners.length; ++i) {
                console.log(string.concat("            chain owner ", vm.toString(liveOwners[i])));
            }
            for (uint256 i; i < bookOwners.length; ++i) {
                console.log(string.concat("            book  owner ", vm.toString(bookOwners[i])));
            }
        }

        // Informational: the deployment targets Safe 1.4.1 on both nets. A different singleton
        // is a thing to notice, not necessarily a thing that is wrong.
        try ISafe(safe).VERSION() returns (string memory version) {
            if (keccak256(bytes(version)) != keccak256(bytes(EXPECTED_SAFE_VERSION))) {
                console.log(string.concat("  [warn]  Safe VERSION is ", version, ", expected ", EXPECTED_SAFE_VERSION));
            }
        } catch {
            console.log("  [warn]  the Safe did not answer VERSION() - is this a Safe?");
        }
    }

    function _role(ITimelockView tl, bytes32 role, address account, bool expected, string memory what) internal {
        checked++;
        if (tl.hasRole(role, account) == expected) {
            console.log(string.concat("  [ok]    ", what));
            return;
        }
        wrong++;
        console.log(string.concat("  [WRONG] NOT TRUE: ", what));
        console.log(string.concat("            account ", vm.toString(account)));
    }

    // -------------------------------------------------------------------------------------
    // The pause role
    // -------------------------------------------------------------------------------------

    /// @dev `pausePoolManager` is role-or-owner and `unpausePoolManager` is `onlyOwner`, so the
    /// pause role is the only way to stop swaps without waiting out the timelock delay - and
    /// the delay is then the floor on recovery. At launch nobody holds it: `grantPausableRole`
    /// is `onlyOwner`, the owner is the timelock, so it is a scheduled operation somebody has
    /// to remember. Fill `governance.pauser` when the holder is decided; until then this skips.
    ///
    /// ⚠️ A pause blocks `swap` and `donate` ONLY. `modifyLiquidity` is not paused, so users can
    /// always withdraw while paused - which is what makes granting this cheap.
    function _checkPauser() internal {
        console.log("Pause role");
        address pauser = readAddressOrZero("governance.pauser");
        if (pauser == address(0)) {
            skipped++;
            console.log("  [skip]  governance.pauser is not decided yet - nobody can pause without the timelock");
            return;
        }

        string[2] memory ownerKeys = ["infinity.clPoolManagerOwner", "infinity.binPoolManagerOwner"];
        for (uint256 i; i < ownerKeys.length; ++i) {
            address ownerContract = readAddressOrZero(ownerKeys[i]);
            if (ownerContract == address(0) || ownerContract.code.length == 0) {
                skipped++;
                console.log(string.concat("  [skip]  ", ownerKeys[i], " is not in the book yet"));
                continue;
            }
            if (IPausableRoleView(ownerContract).hasPausableRole(pauser)) {
                checked++;
                console.log(string.concat("  [ok]    ", ownerKeys[i], " -> pauser can pause"));
                continue;
            }
            _standing(
                string.concat("the pauser holds no role on ", ownerKeys[i]),
                "an emergency pause would need a Safe signature and the full timelock delay"
            );
            _printTimelockPayloads(ownerContract, abi.encodeWithSignature("grantPausableRole(address)", pauser));
        }
    }

    // -------------------------------------------------------------------------------------
    // The CREATE3 factory
    // -------------------------------------------------------------------------------------

    /// @dev `Create3Factory` derives its address from the SALT ALONE - it is not namespaced by
    /// `msg.sender` - and the salts here are public strings baked into these scripts. So any
    /// whitelisted address can deploy any bytecode at any salt not yet used, and the locker and
    /// the guard hook are both constructed pointing at the settler's PREDICTED address. That
    /// makes the factory's owner, AND every address it has whitelisted, a trust root the size
    /// of the timelock for as long as unused salts remain.
    ///
    /// 🔴 The whitelist half is the one that reads as harmless and is not. `deployerEOA` is by
    /// design a hot key, and it stays whitelisted after the deploy unless somebody removes it:
    /// whoever holds it can place code at the NEXT version's salt - `ChoiceRouter/1.1.0`,
    /// `CLProtocolFeeController/1.3.0` - and every script in this repo adopts an address that
    /// already has code ("already deployed, skipping"). De-whitelist it between phases, and
    /// hand the factory itself to the timelock when the last salt is spent.
    function _checkCreate3Factory() internal {
        console.log("CREATE3 factory");
        address factory = readAddressOrZero("governance.create3Factory");
        if (factory == address(0) || factory.code.length == 0) {
            skipped++;
            console.log("  [skip]  governance.create3Factory is not in the book yet");
            return;
        }

        // --- ownership ---------------------------------------------------------------------
        (bool hasOwner, address owner_) = _owner(factory);
        if (!hasOwner) {
            console.log("  [WARN]  the factory has no owner() - cannot check its whitelist authority");
        } else if (owner_ == timelock) {
            checked++;
            console.log("  [ok]    owned by the timelock");
        } else {
            (bool hasPending, address pending) = _pendingOwner(factory);
            if (hasPending && pending == timelock) {
                _standing("the factory is only PENDING for the timelock", "Ownable2Step needs the accept to land");
                _printTimelockPayloads(factory, abi.encodeWithSelector(ACCEPT_OWNERSHIP));
            } else if (owner_.code.length != 0) {
                console.log(
                    string.concat("  [warn]  owned by a contract that is not the timelock: ", vm.toString(owner_))
                );
            } else {
                _standing(
                    string.concat("owned by an EOA: ", vm.toString(owner_)),
                    "salts are not namespaced by sender, so this key can still mint any predicted address"
                );
                console.log(
                    string.concat(
                        "            1. from ", vm.toString(owner_), " -> factory.transferOwnership(timelock):"
                    )
                );
                console.log(
                    string.concat(
                        "               ", vm.toString(abi.encodeWithSignature("transferOwnership(address)", timelock))
                    )
                );
                console.log("            2. then the timelock accepts:");
                _printTimelockPayloads(factory, abi.encodeWithSelector(ACCEPT_OWNERSHIP));
            }
        }

        // --- the whitelist -----------------------------------------------------------------
        // De-whitelist BEFORE handing the factory over: while the owner is still an EOA it is
        // one direct call, and afterwards it is a timelock operation per key.
        address[2] memory keys =
            [readAddressOrZero("governance.deployerEOA"), readAddressOrZero("governance.create3DeployerEOA")];
        string[2] memory names = ["deployerEOA", "create3DeployerEOA"];
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == address(0)) continue;
            bool listed;
            try ICreate3FactoryView(factory).isUserWhitelisted(keys[i]) returns (bool v) {
                listed = v;
            } catch {
                console.log("  [warn]  the factory did not answer isUserWhitelisted()");
                return;
            }
            if (!listed) {
                checked++;
                console.log(string.concat("  [ok]    ", names[i], " is not whitelisted"));
                continue;
            }
            _standing(
                string.concat(names[i], " is still whitelisted on the factory"),
                "it can place code at any unclaimed salt, which every script here would adopt"
            );
            bytes memory payload = abi.encodeWithSignature("setWhitelistUser(address,bool)", keys[i], false);
            if (hasOwner && owner_ == timelock) {
                _printTimelockPayloads(factory, payload);
            } else if (hasOwner) {
                console.log(string.concat("            from ", vm.toString(owner_), " -> factory:"));
                console.log(string.concat("               ", vm.toString(payload)));
            }
        }
    }

    // -------------------------------------------------------------------------------------
    // Launch-pool wiring
    // -------------------------------------------------------------------------------------

    /// @dev Ownership is not the only thing a deploy can leave half-done. These four links are
    /// what a graduation actually walks, and every one of them is a call SOMEBODY has to make
    /// after the contracts are on chain:
    ///
    ///   1. the CL pool manager points at Choice's fee controller,
    ///   2. that controller's launch-pool gate is the guard hook (plan A0 / D30) - without it
    ///      `zeroLaunchPoolProtocolFee` refuses and every graduation reverts,
    ///   3. the locker registers for this settler,
    ///   4. the guard hook lets this settler create pools.
    ///
    /// 🔴 2 is the one that is easy to miss, because it did not exist before A0 and the
    /// controller is deployed two scripts before the hook it has to point at. Failing closed
    /// is the right behaviour there - a graduate that quietly paid Choice's protocol fee would
    /// mix the launchpad's revenue into a global bucket nobody can unpick afterwards - but "fails
    /// closed" is only safe if the missing step is impossible to miss.
    ///
    /// A missing address book entry is SKIPPED, like everything else here, so this is runnable
    /// on a deployment that has no launchpad.
    function _checkLaunchPoolWiring() internal {
        console.log("Launch-pool wiring (a graduation touches all of it)");

        address clPoolManager = readAddressOrZero("infinity.clPoolManager");
        address clFeeController = readAddressOrZero("choice.clFeeController");
        address guardHook = readAddressOrZero("choice.launchPoolGuardHook");
        address settler = readAddressOrZero("choice.infinitySettler");
        address locker = readAddressOrZero("choice.positionLocker");

        if (clPoolManager != address(0) && clFeeController != address(0)) {
            address live = address(IProtocolFees(clPoolManager).protocolFeeController());
            _wiring(
                live == clFeeController,
                "clPoolManager.protocolFeeController",
                live,
                clFeeController,
                "infinity.clPoolManagerOwner -> setProtocolFeeController"
            );
        } else {
            skipped++;
            console.log("  [skip] clPoolManager or clFeeController is not in the book yet");
        }

        if (clFeeController != address(0) && guardHook != address(0)) {
            // 🔴 A staticcall, because a controller deployed before A0 has no such function
            // and a plain call to a missing selector reverts - which would take down a script
            // whose whole job is to REPORT that the deploy is unfinished.
            (bool answered, bytes memory data) =
                clFeeController.staticcall(abi.encodeWithSignature("launchPoolGuardHook()"));
            address gate = (answered && data.length == 32) ? abi.decode(data, (address)) : address(0);
            _wiring(
                answered && gate == guardHook,
                answered ? "clFeeController.launchPoolGuardHook" : "clFeeController has no launch-pool gate (pre-A0)",
                gate,
                guardHook,
                "choice.clFeeController -> setLaunchPoolGuardHook"
            );
        } else {
            skipped++;
            console.log("  [skip] clFeeController or launchPoolGuardHook is not in the book yet");
        }

        if (locker != address(0) && settler != address(0)) {
            address current = IPositionLockerView(locker).settler();
            _wiring(
                current == settler, "positionLocker.settler", current, settler, "choice.positionLocker -> setSettler"
            );
        } else {
            skipped++;
            console.log("  [skip] positionLocker or infinitySettler is not in the book yet");
        }

        if (guardHook != address(0) && settler != address(0)) {
            bool allowed = ILaunchPoolGuardHookView(guardHook).isInitializer(settler);
            _wiring(
                allowed,
                "launchPoolGuardHook.isInitializer(settler)",
                allowed ? settler : address(0),
                settler,
                "choice.launchPoolGuardHook -> setInitializer(settler, true)"
            );
        } else {
            skipped++;
            console.log("  [skip] launchPoolGuardHook or infinitySettler is not in the book yet");
        }
    }

    function _wiring(bool ok, string memory what, address current, address expected, string memory fix) internal {
        checked++;
        if (ok) {
            console.log(string.concat("  [ok]    ", what));
            return;
        }
        wrong++;
        console.log(string.concat("  [WRONG] ", what));
        console.log(string.concat("            is ", vm.toString(current), ", should be ", vm.toString(expected)));
        console.log(string.concat("            fix: Safe -> timelock -> ", fix));
    }

    // -------------------------------------------------------------------------------------

    /// @dev A standing-hygiene item: required by the END of a deploy rather than immediately.
    /// Before `governance.deployComplete` it is reported and does not fail the run, because the
    /// phases that still have to run need the very thing it is asking to remove (a whitelisted
    /// deploy key, most obviously). After it, it fails like anything else outstanding.
    function _standing(string memory what, string memory why) internal {
        if (deployComplete) {
            outstanding++;
            console.log(string.concat("  [TODO]  ", what));
        } else {
            console.log(string.concat("  [note]  ", what));
        }
        console.log(string.concat("            ", why));
    }

    /// @dev Owned outright, or pending acceptance by the expected owner - which is a step
    /// somebody still has to take, not a pass.
    function _requireOwnedBy(string memory key, address expected, string memory expectedName) internal {
        address at = readAddressOrZero(key);
        if (at == address(0) || at.code.length == 0) {
            skipped++;
            console.log(string.concat("  [skip] ", key, " is not in the book yet"));
            return;
        }
        checked++;

        (bool hasOwner, address current) = _owner(at);
        if (!hasOwner) {
            wrong++;
            console.log(string.concat("  [WRONG] ", key, " has no owner() - is this the right address?"));
            return;
        }
        if (current == expected) {
            console.log(string.concat("  [ok]    ", key));
            return;
        }

        (bool hasPending, address pending) = _pendingOwner(at);
        if (hasPending && pending == expected) {
            outstanding++;
            console.log(string.concat("  [TODO]  ", key, " is still only PENDING for ", expectedName));
            console.log(string.concat("            at ", vm.toString(at), ", owned by ", vm.toString(current)));
            _printTimelockPayloads(at, abi.encodeWithSelector(ACCEPT_OWNERSHIP));
            return;
        }

        wrong++;
        console.log(string.concat("  [WRONG] ", key, " is not owned by ", expectedName));
        console.log(string.concat("            owner ", vm.toString(current), ", expected ", vm.toString(expected)));
    }

    function _requireOwnedByBookEntry(string memory key, string memory ownerKey) internal {
        address expected = readAddressOrZero(ownerKey);
        if (expected == address(0)) {
            skipped++;
            console.log(string.concat("  [skip] ", ownerKey, " is not in the book yet"));
            return;
        }
        _requireOwnedBy(key, expected, ownerKey);
    }

    /// @dev The Safe cannot call these targets itself - the privileged caller is the TIMELOCK,
    /// so it has to go through schedule/execute. Both payloads are printed because getting the
    /// second one's arguments to match the first is the whole trick with a TimelockController.
    function _printTimelockPayloads(address target, bytes memory payload) internal view {
        console.log(
            string.concat(
                "            1. Safe -> timelock.schedule: ",
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
                "            2. after ",
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

    /// @dev The batch form, for the per-owner canceller grants: one operation, one delay, all
    /// three owners - rather than three operations that can be executed apart from each other.
    function _printTimelockBatchPayloads(address[] memory targets, bytes[] memory payloads) internal view {
        uint256[] memory values = new uint256[](targets.length);
        console.log(
            string.concat(
                "            1. Safe -> timelock.scheduleBatch: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
                        targets,
                        values,
                        payloads,
                        bytes32(0),
                        bytes32(0),
                        delay
                    )
                )
            )
        );
        console.log(
            string.concat(
                "            2. after ",
                vm.toString(delay),
                "s, anyone -> timelock.executeBatch: ",
                vm.toString(
                    abi.encodeWithSignature(
                        "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
                        targets,
                        values,
                        payloads,
                        bytes32(0),
                        bytes32(0)
                    )
                )
            )
        );
    }

    function _report() internal view {
        console.log("");
        console.log(string.concat("checked ", vm.toString(checked), ", skipped ", vm.toString(skipped)));
        if (outstanding > 0) {
            console.log(string.concat(vm.toString(outstanding), " OUTSTANDING governance step(s) - see above"));
        }
        if (wrong > 0) {
            console.log(string.concat(vm.toString(wrong), " check(s) FAILED - see above"));
        }
        require(outstanding == 0, "deploy is unfinished: a governance step is still outstanding");
        require(wrong == 0, "governance is wrong somewhere - see the log above");
        console.log("Ownership and governance are where they should be.");
    }

    // -------------------------------------------------------------------------------------

    /// @dev Staticcalls rather than interface calls, because the set spans OpenZeppelin's
    /// `Ownable2Step`, infinity-core's own one-step `Ownable`, and contracts with no owner at
    /// all - and an absent `pendingOwner()` has to read as "one-step", not as a failure.
    function _owner(address target) internal view returns (bool has, address owner_) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }

    function _pendingOwner(address target) internal view returns (bool has, address pending) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("pendingOwner()"));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }
}
