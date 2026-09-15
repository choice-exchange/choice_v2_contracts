// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";

import {ChoiceFeeController} from "../src/fees/ChoiceFeeController.sol";
import {InfinitySettler} from "../src/launchpad/InfinitySettler.sol";
import {LaunchPoolFeeHook} from "../src/launchpad/LaunchPoolFeeHook.sol";
import {BaseScript} from "./BaseScript.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ITimelockBatch, ISafeApproveHash} from "./13_DeploySinkAndCrankerViaTimelock.s.sol";

/**
 * `LaunchPoolFeeHook` 1.0.0, and the switch that points graduations at it.
 *
 * The switch is three calls, and they only work together:
 *
 *   1. deploy the hook at `HOOK_SALT`, born owned by the timelock, allowlisting the live settler
 *      and paying `choice.buybackBurnSink` (a reserved address may have no code yet: `harvest`
 *      then simply delivers there);
 *   2. settler.setPoolConfig(0, <its current spacing>, hook);
 *   3. clFeeController.setLaunchPoolGuardHook(hook).
 *
 * 🔴 Steps 2 and 3 must land in ONE timelock operation. `setPoolConfig` alone makes every
 * graduation revert `NotALaunchPool` in the settler's protocol-fee zeroing; the repoint alone does
 * the same to every graduation into a guard-hook pool. Both refuse a hook with no code, so 1 runs
 * first. The settler reads its config at graduation, so EVERY graduation after the operation -
 * launches already created included - gets the hook, and every one before it keeps the guard hook
 * and its 1% LP fee for good.
 *
 * Where the CREATE3 factory is owned by the timelock (mainnet since E5) all of it is ONE batch,
 * bracketed by whitelisting the timelock on the factory and removing it again - script 13's
 * shape. Where the factory is still EOA-owned (testnet), the deploy key deploys the hook directly
 * under --broadcast, and the batch is steps 2 and 3.
 *
 * ## It never broadcasts the batch
 *
 * The batch runs here through the REAL contracts in this script's local fork: the Safe schedules
 * it on pre-approved hashes (no key involved), the delay is warped, anyone executes. Then the
 * result is checked - both gates name the hook, the settler keys LP fee 0 and the hook's bitmap,
 * the factory's owner and whitelist are as they were - and the Safe's calldata is printed with
 * the gas each transaction measured.
 *
 * The book is written only when the hook ALREADY had code when the run started: a dry run, or a
 * broadcast whose receipt never came, must not leave the book naming an address with no code.
 * So on testnet: run once with --broadcast to deploy, then again without it to record and batch.
 *
 *   NETWORK=injective_testnet script/tools/with-key.sh choice-v2-deployer forge script \
 *     script/14_DeployLaunchPoolFeeHook.s.sol:DeployLaunchPoolFeeHook -vv --rpc-url $RPC_URL [--broadcast]
 *   NETWORK=injective_mainnet forge script \
 *     script/14_DeployLaunchPoolFeeHook.s.sol:DeployLaunchPoolFeeHook -vv --rpc-url $RPC_URL
 *
 * No --slow, no --resume: re-run instead. Every step is idempotent.
 */
contract DeployLaunchPoolFeeHook is BaseScript {
    bytes32 internal constant HOOK_SALT = keccak256("CHOICE-V2/LaunchPoolFeeHook/1.0.0");
    /// An operation id is `hash(targets, values, payloads, predecessor, salt)`; a fixed salt makes
    /// the batch recognisable, and a re-run over unchanged state prints the same id.
    bytes32 internal constant BATCH_SALT = keccak256("CHOICE-V2/LaunchPoolFeeHookBatch/1.0.0");

    uint256 internal constant MAINNET_CHAIN_ID = 1776;
    /// Injective's per-transaction gas cap. The hook's creation code rides in the Safe's
    /// transaction as calldata and again in the timelock's, so both have to fit.
    uint256 internal constant TX_GAS_CAP = 75_000_000;

    address[] internal targets;
    bytes[] internal payloads;
    string[] internal labels;

    struct Book {
        Create3Factory factory;
        address timelock;
        address core;
        address clPoolManager;
        address settler;
        address controller;
        address treasury;
    }

    function run() public {
        require(block.chainid == readUint("chainId"), "the address book is for another chain - check NETWORK");
        Book memory b = _readBook();

        address hook = b.factory.computeAddress(HOOK_SALT);
        bool hadCode = hook.code.length != 0;
        console.log("LaunchPoolFeeHook 1.0.0 ->", hook, hadCode ? "(has code)" : "(no code yet)");

        bytes memory creation = abi.encodePacked(
            type(LaunchPoolFeeHook).creationCode, abi.encode(b.core, b.clPoolManager, b.timelock, b.settler, b.treasury)
        );

        address factoryOwner = b.factory.owner();
        bool whitelistedBefore = b.factory.isUserWhitelisted(b.timelock);
        bool lockedDown = factoryOwner == b.timelock;
        if (!hadCode && !lockedDown) {
            // An EOA-owned factory: the deploy key deploys the hook itself. Mainnet's is the
            // timelock's since E5, so reaching here there means E5 was undone - refuse.
            require(block.chainid != MAINNET_CHAIN_ID, "mainnet's CREATE3 factory must be owned by the timelock (E5)");
            requireWhitelistedDeployer(address(b.factory));
            vm.startBroadcast(deployerKey());
            address deployed = b.factory.deploy(HOOK_SALT, creation, keccak256(creation), 0, "", 0);
            vm.stopBroadcast();
            require(deployed == hook, "create3 address mismatch");
            console.log("  deployed (confirm with eth_getCode, then re-run without --broadcast):", deployed);
        }

        bool bracket;
        if (hook.code.length == 0) {
            // A locked-down factory: the deploy joins the batch, bracketed by the timelock's own
            // whitelisting unless something already whitelisted it.
            bracket = !whitelistedBefore;
            if (bracket) {
                _push(
                    address(b.factory),
                    abi.encodeCall(Create3Factory.setWhitelistUser, (b.timelock, true)),
                    "factory.setWhitelistUser(timelock, true)"
                );
            }
            _push(
                address(b.factory),
                abi.encodeCall(Create3Factory.deploy, (HOOK_SALT, creation, keccak256(creation), 0, bytes(""), 0)),
                "factory.deploy(LaunchPoolFeeHook)"
            );
        } else {
            _requireIsOurHook(hook, b);
        }

        InfinitySettler settler = InfinitySettler(b.settler);
        if (address(settler.hooks()) != hook || settler.lpFee() != 0) {
            _push(
                b.settler,
                abi.encodeCall(InfinitySettler.setPoolConfig, (0, settler.tickSpacing(), IHooks(hook))),
                "settler.setPoolConfig(0, spacing, hook)"
            );
        }
        if (address(ChoiceFeeController(payable(b.controller)).launchPoolGuardHook()) != hook) {
            _push(
                b.controller,
                abi.encodeCall(ChoiceFeeController.setLaunchPoolGuardHook, (IHooks(hook))),
                "clFeeController.setLaunchPoolGuardHook(hook)"
            );
        }
        if (bracket) {
            _push(
                address(b.factory),
                abi.encodeCall(Create3Factory.setWhitelistUser, (b.timelock, false)),
                "factory.setWhitelistUser(timelock, false)"
            );
        }

        if (targets.length == 0) {
            console.log("");
            console.log("Already switched: the settler and the fee controller both name the hook. Nothing to batch.");
        } else {
            _simulateAndPrint(b.timelock);
        }
        _check(hook, b, factoryOwner, whitelistedBefore);

        if (hadCode) {
            writeAddress("choice.launchPoolFeeHook", hook);
        } else {
            console.log("");
            console.log("The book is NOT written: the hook had no code when this run started.");
        }
    }

    function _readBook() internal view returns (Book memory b) {
        b.factory = Create3Factory(readAddress("governance.create3Factory"));
        b.timelock = readAddress("governance.timelock");
        b.core = readAddress("launchpad.core");
        b.clPoolManager = readAddress("infinity.clPoolManager");
        b.settler = readAddress("choice.infinitySettler");
        b.controller = readAddress("choice.clFeeController");
        b.treasury = readAddress("choice.buybackBurnSink");
        requireCode("timelock", b.timelock);
        requireCode("launchpad core", b.core);
        requireCode("clPoolManager", b.clPoolManager);
        requireCode("settler", b.settler);
        requireCode("clFeeController", b.controller);

        // The hook serves the core the settler serves, and both gates it needs are the
        // timelock's to move. Checked before anything is built on them.
        InfinitySettler settler = InfinitySettler(b.settler);
        require(address(settler.CORE()) == b.core, "the settler serves another core than launchpad.core");
        require(settler.owner() == b.timelock, "the settler is not owned by the timelock");
        require(
            ChoiceFeeController(payable(b.controller)).owner() == b.timelock, "the fee controller is not the timelock's"
        );
        require(
            address(IProtocolFees(b.clPoolManager).protocolFeeController()) == b.controller,
            "the pool manager's protocol fee controller is not choice.clFeeController"
        );
    }

    /// @dev A contract already at the salt is ours only if it answers exactly as the payload
    /// above would have built it. CREATE3 means anybody the factory whitelisted could have put
    /// ANY code there.
    function _requireIsOurHook(address hook, Book memory b) internal view {
        LaunchPoolFeeHook h = LaunchPoolFeeHook(hook);
        require(address(h.CORE()) == b.core, "the hook at the salt serves another core");
        require(address(h.POOL_MANAGER()) == b.clPoolManager, "the hook at the salt serves another pool manager");
        require(h.owner() == b.timelock, "the hook at the salt is not owned by the timelock");
        require(h.pendingOwner() == address(0), "the hook at the salt has an ownership transfer pending");
        require(h.isInitializer(b.settler), "the hook at the salt does not allow the settler");
        require(h.treasury() == b.treasury, "the hook at the salt pays another treasury");
        require(h.FEE_PIPS() == 10_000, "the hook at the salt charges another fee");
        require(h.getHooksRegistrationBitmap() == h.BITMAP(), "the hook at the salt registers another bitmap");
    }

    /// @dev What a graduation after the batch will actually meet.
    function _check(address hook, Book memory b, address factoryOwner, bool whitelistedBefore) internal view {
        _requireIsOurHook(hook, b);
        InfinitySettler settler = InfinitySettler(b.settler);
        require(address(settler.hooks()) == hook, "the settler does not key graduation pools to the hook");
        require(settler.lpFee() == 0, "the settler still keys an LP fee: pools would charge twice");
        require(
            uint16(uint256(settler.poolParameters())) == LaunchPoolFeeHook(hook).BITMAP(),
            "the settler's key carries another bitmap than the hook registers"
        );
        require(
            address(ChoiceFeeController(payable(b.controller)).launchPoolGuardHook()) == hook,
            "the fee controller's launch-pool gate is not the hook: graduations would revert NotALaunchPool"
        );
        require(b.factory.owner() == factoryOwner, "the batch moved the factory's owner");
        require(
            b.factory.isUserWhitelisted(b.timelock) == whitelistedBefore,
            "the batch left the timelock's whitelist changed"
        );

        console.log("");
        console.log("  [ok]   hook: core, pool manager, owner, settler allowlisted, treasury, fee, bitmap");
        console.log("  [ok]   settler: LP fee 0, keyed to the hook and its bitmap");
        console.log("  [ok]   fee controller: the launch-pool gate is the hook");
        console.log("  [ok]   factory: owner and the timelock's whitelist exactly as before");
    }

    /// @dev Script 13's simulation: the batch runs the way it will for real, both transactions are
    /// measured, and what the operator needs is printed. The state it leaves is local.
    function _simulateAndPrint(address timelock) internal {
        ITimelockBatch tl = ITimelockBatch(timelock);
        address[] memory t = targets;
        bytes[] memory d = payloads;
        uint256[] memory v = new uint256[](t.length);
        uint256 delay = tl.getMinDelay();

        bytes32 id = tl.hashOperationBatch(t, v, d, bytes32(0), BATCH_SALT);
        bytes memory scheduleData =
            abi.encodeCall(ITimelockBatch.scheduleBatch, (t, v, d, bytes32(0), BATCH_SALT, delay));
        bytes memory executeData = abi.encodeCall(ITimelockBatch.executeBatch, (t, v, d, bytes32(0), BATCH_SALT));

        bool alreadyScheduled = tl.isOperation(id);
        uint256 scheduleGas;
        if (!alreadyScheduled) {
            scheduleGas = _simulateSafeExec(readAddress("governance.safe"), timelock, scheduleData);
            require(tl.isOperationPending(id), "the Safe's scheduleBatch did not leave the operation pending");
        }
        uint256 readyAt = tl.getTimestamp(id);
        if (readyAt > block.timestamp) vm.warp(readyAt);
        uint256 executeGas = _measuredCall(timelock, executeData);
        require(tl.isOperationDone(id), "executeBatch did not complete the operation");

        console.log("");
        console.log("ONE timelock operation, id:");
        console.logBytes32(id);
        for (uint256 i; i < t.length; ++i) {
            console.log(string.concat("  ", vm.toString(i + 1), ". ", labels[i]), t[i]);
        }
        console.log("");
        console.log("Gas MEASURED here, intrinsic calldata included. Injective debits the whole LIMIT:");
        if (!alreadyScheduled) console.log("  Safe execTransaction(scheduleBatch) :", scheduleGas);
        console.log("  timelock.executeBatch               :", executeGas);
        require(scheduleGas < TX_GAS_CAP && executeGas < TX_GAS_CAP, "a transaction is over Injective's per-tx gas cap");

        console.log("");
        if (alreadyScheduled) {
            console.log("1. ALREADY SCHEDULED. Ready at unix time", readyAt);
        } else {
            console.log(
                string.concat("1. Safe -> timelock ", vm.toString(timelock), ", then wait ", vm.toString(delay), "s:")
            );
            console.log(string.concat("SCHEDULE_BATCH_CALLDATA=", vm.toString(scheduleData)));
        }
        console.log(string.concat("2. anyone -> timelock ", vm.toString(timelock), ":"));
        console.log(string.concat("EXECUTE_BATCH_CALLDATA=", vm.toString(executeData)));
        console.log("3. Re-run this script WITHOUT --broadcast: it finds the hook, checks the wiring, writes the book.");
        console.log("");
        console.log(
            "Until step 2 executes, every graduation still lands on the guard hook and its 1% LP fee, for good."
        );
    }

    /// @dev The real `execTransaction`, on the lowest `threshold` owners' pre-approved hashes -
    /// see script 13, whose measurement this is.
    function _simulateSafeExec(address safe, address to, bytes memory data) internal returns (uint256 used) {
        ISafe s = ISafe(safe);
        bytes32 safeTxHash = s.getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), s.nonce());
        address[] memory signers = _lowestOwners(s.getOwners(), s.getThreshold());

        bytes memory signatures;
        for (uint256 i; i < signers.length; ++i) {
            vm.prank(signers[i]);
            ISafeApproveHash(safe).approveHash(safeTxHash);
            signatures = abi.encodePacked(signatures, bytes32(uint256(uint160(signers[i]))), bytes32(0), uint8(1));
        }

        bytes memory execData = abi.encodeCall(
            ISafe.execTransaction, (to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = safe.call(execData);
        used = before - gasleft() + _intrinsicGas(execData);
        require(ok && abi.decode(ret, (bool)), "the Safe's execTransaction(scheduleBatch) failed in simulation");
    }

    function _measuredCall(address to, bytes memory data) internal returns (uint256 used) {
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = to.call(data);
        used = before - gasleft() + _intrinsicGas(data);
        if (!ok) {
            console.log("executeBatch reverted in simulation with:");
            console.logBytes(ret);
            revert("executeBatch reverted in simulation");
        }
    }

    function _push(address target, bytes memory data, string memory label) internal {
        targets.push(target);
        payloads.push(data);
        labels.push(label);
    }

    /// @dev Ascending, as Safe's `checkNSignatures` requires, then cut to `threshold`.
    function _lowestOwners(address[] memory owners, uint256 threshold) internal pure returns (address[] memory) {
        for (uint256 i = 1; i < owners.length; ++i) {
            address k = owners[i];
            uint256 j = i;
            while (j > 0 && owners[j - 1] > k) {
                owners[j] = owners[j - 1];
                --j;
            }
            owners[j] = k;
        }
        require(threshold <= owners.length, "Safe threshold above its owner count");
        assembly ("memory-safe") {
            mstore(owners, threshold)
        }
        return owners;
    }

    function _intrinsicGas(bytes memory data) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }
}
