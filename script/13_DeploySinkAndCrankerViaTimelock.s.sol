// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {BuybackBurnSink} from "../src/fees/BuybackBurnSink.sol";
import {LaunchFeeCranker} from "../src/launchpad/LaunchFeeCranker.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {DeployBuybackBurnSink} from "./09_DeployBuybackBurnSink.s.sol";
import {DeployLaunchFeeCranker} from "./10_DeployLaunchFeeCranker.s.sol";

/// @notice The slice of OpenZeppelin 5's `TimelockController` a batch needs.
interface ITimelockBatch {
    function getMinDelay() external view returns (uint256);
    function getTimestamp(bytes32 id) external view returns (uint256);
    function isOperation(bytes32 id) external view returns (bool);
    function isOperationPending(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;
}

/// @notice Safe's pre-approved-hash path. Used ONLY inside this script's local simulation, so the
/// real `execTransaction` - threshold check, L2 event and all - runs without anybody's key.
interface ISafeApproveHash {
    function approveHash(bytes32 hashToApprove) external;
}

/**
 * The launchpad's burn sink AND its fee cranker, deployed BY THE TIMELOCK in ONE batch.
 *
 * Once the CREATE3 factory is locked down (E5) it is owned by the timelock and whitelists no one,
 * so scripts 09 and 10 can no longer broadcast `factory.deploy` from a deploy key. This builds the
 * single `scheduleBatch` / `executeBatch` pair that replaces them:
 *
 *   1. factory.setWhitelistUser(timelock, true)
 *   2. factory.deploy(09's SINK_SALT,    09's payload)
 *   3. sink.setLockers(09's locker list)
 *   4. factory.deploy(10's CRANKER_SALT, 10's payload)
 *   5. factory.setWhitelistUser(timelock, false)
 *
 * 🔑 ONE batch, not a mode in each of 09 and 10. Two batches are two Safe rounds and two delays,
 * with a sink in between that nothing cranks. One batch is one transaction: the sink lands WITH its
 * wiring, the timelock is whitelisted for exactly the life of that transaction, and no EOA is ever
 * whitelisted again.
 *
 * 🔴 THE ORDER IS LOAD-BEARING. The cranker's constructor READS `QUOTE()` and `BURN_TOKEN()` off
 * the sink and refuses an address with no code, so step 4 works only because step 2 ran earlier in
 * the same transaction. The sink's constructor reads nothing but the position manager.
 *
 * The salts and both payloads come from 09 and 10 themselves - this contract inherits both - so
 * the batch deploys byte for byte what they would have broadcast.
 *
 * ## It broadcasts nothing
 *
 * It runs the batch through the REAL contracts in this script's local fork: the Safe executes
 * `scheduleBatch` (on pre-approved hashes, so no key is involved), the delay is warped, anyone
 * executes. Then it asserts 09's and 10's wiring checks against the result, and prints both
 * calldatas and the gas each one MEASURED - Injective debits the whole gas LIMIT and
 * `eth_estimateGas` under-reports, so the limit is set from these. `--broadcast` sends nothing.
 *
 * ⚠️ It needs `launchpad.burnToken`, so it cannot run until the burn token exists: the sink's
 * payload carries it, while the sink's ADDRESS is fixed by the salt alone. Whatever accrues at the
 * reserved address in the meantime is the sink's the moment it lands.
 *
 * ## Rehearsal
 *
 * `REHEARSAL_TAG=<anything>` swaps in throwaway salts derived from the tag, and is refused on
 * mainnet. Where the factory is still EOA-owned (testnet), the timelock cannot whitelist itself:
 * the owner whitelists the timelock first, the batch leaves out steps 1 and 5, and the owner
 * removes the timelock again afterwards. Which case applies is read from `owner()`.
 *
 *   NETWORK=injective_mainnet forge script \
 *     script/13_DeploySinkAndCrankerViaTimelock.s.sol:DeploySinkAndCrankerViaTimelock -vv \
 *     --rpc-url $RPC_URL
 *
 * Afterwards, re-run 09 and 10 WITHOUT --broadcast: both find code at their addresses, check the
 * wiring and write the book. This script never writes the book, because until the batch executes
 * nothing it would record exists.
 */
contract DeploySinkAndCrankerViaTimelock is DeployBuybackBurnSink, DeployLaunchFeeCranker {
    /// An operation id is `hash(targets, values, payloads, predecessor, salt)`. A fixed salt makes
    /// the batch recognisable, and a re-run over an unchanged book prints the same id.
    bytes32 internal constant BATCH_SALT = keccak256("CHOICE-V2/SinkAndCrankerBatch/sink-1.5.0+cranker-2.1.0");

    uint256 internal constant MAINNET_CHAIN_ID = 1776;
    /// Injective's per-transaction gas cap. Two contract creations have to fit under it twice:
    /// once as calldata in the Safe's transaction, once executed in the timelock's.
    uint256 internal constant TX_GAS_CAP = 75_000_000;

    address[] internal targets;
    bytes[] internal payloads;
    string[] internal labels;

    function run() public override(DeployBuybackBurnSink, DeployLaunchFeeCranker) {
        require(block.chainid == readUint("chainId"), "the address book is for another chain - check NETWORK");

        string memory tag = vm.envOr("REHEARSAL_TAG", string(""));
        bool rehearsal = bytes(tag).length != 0;
        require(!rehearsal || block.chainid != MAINNET_CHAIN_ID, "REHEARSAL_TAG is refused on mainnet");
        bytes32 sinkSalt = rehearsal ? _rehearsalSalt(tag, "BuybackBurnSink") : SINK_SALT;
        bytes32 crankerSalt = rehearsal ? _rehearsalSalt(tag, "LaunchFeeCranker") : CRANKER_SALT;

        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        address timelock = readAddress("governance.timelock");
        requireCode("timelock", timelock);

        address sink = factory.computeAddress(sinkSalt);
        address cranker = factory.computeAddress(crankerSalt);
        console.log(
            rehearsal ? "REHEARSAL, throwaway salts from tag:" : "BuybackBurnSink 1.5.0 + LaunchFeeCranker 2.1.0", tag
        );
        console.log("BuybackBurnSink  ->", sink);
        console.log("LaunchFeeCranker ->", cranker);

        if (!rehearsal) {
            // D9: the pad's revenue already accrues at the reserved address, so the salt and the
            // book have to agree before anything is built on either.
            address reserved = readAddressOrZero("choice.buybackBurnSink");
            require(
                reserved == address(0) || reserved == sink,
                "choice.buybackBurnSink is not the address SINK_SALT computes"
            );
        }
        if (sink.code.length != 0 && cranker.code.length != 0) {
            console.log("");
            console.log(
                "Both are deployed. Re-run 09 and 10 without --broadcast: they check the wiring and write the book."
            );
            return;
        }

        // Whether the batch brackets itself with its own whitelisting depends on who owns the factory.
        address factoryOwner = factory.owner();
        bool whitelistedBefore = factory.isUserWhitelisted(timelock);
        bool bracket = factoryOwner == timelock && !whitelistedBefore;
        if (factoryOwner != timelock && !whitelistedBefore) {
            console.log("");
            console.log("The factory is owned by", factoryOwner);
            if (block.chainid == MAINNET_CHAIN_ID) {
                // On mainnet the answer is never to whitelist something from an EOA: it is to
                // finish the lockdown, after which the batch whitelists the timelock itself.
                console.log("- not the timelock. E5 is not finished: the factory must be owned by the timelock");
                console.log("before this batch can run. See governance.factoryLockdownNote in the address book.");
            } else {
                console.log("- not the timelock - so the timelock cannot whitelist itself. From that owner, first:");
                console.log(string.concat("  factory.setWhitelistUser(", vm.toString(timelock), ", true)"));
                console.log("and remove it again once the batch has executed.");
            }
            revert("the timelock cannot deploy through this factory yet");
        }

        _build(factory, timelock, sinkSalt, crankerSalt, sink, cranker, bracket);
        _simulateAndPrint(timelock, rehearsal ? _rehearsalSalt(tag, "batch") : BATCH_SALT, bracket);
        _check(address(factory), timelock, sink, cranker, factoryOwner, whitelistedBefore, rehearsal);
    }

    function _build(
        Create3Factory factory,
        address timelock,
        bytes32 sinkSalt,
        bytes32 crankerSalt,
        address sink,
        address cranker,
        bool bracket
    ) internal {
        if (bracket) {
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.setWhitelistUser, (timelock, true)),
                "factory.setWhitelistUser(timelock, true)"
            );
        }

        if (sink.code.length == 0) {
            address burnToken = readAddress("launchpad.burnToken");
            address quote = readAddress("external.wINJ");
            address vault = readAddress("infinity.vault");
            address positionManager = readAddress("infinity.clPositionManager");
            requireCode("burnToken", burnToken);
            requireCode("wINJ", quote);
            requireCode("vault", vault);
            requireCode("clPositionManager", positionManager);
            bytes memory p =
                _sinkPayload(burnToken, quote, vault, positionManager, readAddress("choice.treasury"), timelock);
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.deploy, (sinkSalt, p, keccak256(p), 0, bytes(""), 0)),
                "factory.deploy(BuybackBurnSink)"
            );
        }

        address[] memory wanted = _wantedLockers();
        if (!_lockersMatch(sink, wanted)) {
            _push(sink, abi.encodeCall(BuybackBurnSink.setLockers, (wanted)), "sink.setLockers(<the book's lockers>)");
        }

        if (cranker.code.length == 0) {
            bytes memory p = _crankerPayload(readAddress(LIVE_LOCKER_KEY), sink, timelock);
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.deploy, (crankerSalt, p, keccak256(p), 0, bytes(""), 0)),
                "factory.deploy(LaunchFeeCranker)"
            );
        }

        if (bracket) {
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.setWhitelistUser, (timelock, false)),
                "factory.setWhitelistUser(timelock, false)"
            );
        }
    }

    /// @dev Runs the batch the way it will run for real, measures both transactions, and prints
    /// what the operator needs. The state it leaves behind is local to this script.
    function _simulateAndPrint(address timelock, bytes32 batchSalt, bool bracket) internal {
        ITimelockBatch tl = ITimelockBatch(timelock);
        address[] memory t = targets;
        bytes[] memory d = payloads;
        uint256[] memory v = new uint256[](t.length);
        uint256 delay = tl.getMinDelay();

        bytes32 id = tl.hashOperationBatch(t, v, d, bytes32(0), batchSalt);
        bytes memory scheduleData =
            abi.encodeCall(ITimelockBatch.scheduleBatch, (t, v, d, bytes32(0), batchSalt, delay));
        bytes memory executeData = abi.encodeCall(ITimelockBatch.executeBatch, (t, v, d, bytes32(0), batchSalt));

        bool alreadyScheduled = tl.isOperation(id);
        uint256 readyAt = tl.getTimestamp(id);
        uint256 scheduleGas;
        if (!alreadyScheduled) {
            scheduleGas = _simulateSafeExec(readAddress("governance.safe"), timelock, scheduleData);
            require(tl.isOperationPending(id), "the Safe's scheduleBatch did not leave the operation pending");
        }
        uint256 due = tl.getTimestamp(id);
        if (due > block.timestamp) vm.warp(due);
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
        console.log("  calldata bytes, scheduleBatch/executeBatch:", scheduleData.length, executeData.length);
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
        console.log("3. Re-run 09 and 10 WITHOUT --broadcast: they find code, check the wiring, write the book.");
        if (!bracket) console.log("4. The factory's owner removes the timelock from the whitelist again.");
        console.log("");
        console.log("Deliberately NOT in this batch: setGuards (the mainnet values are a plan-B4 decision; 09");
        console.log("prints TEST values), setBuybackPool (needs the burn token's graduation pool), and the");
        console.log("keeper's CRANK_CRANKER set. Until the guards are set the sink PARKS everything - safely.");
    }

    /// @dev The real `execTransaction`, on the lowest `threshold` owners' pre-approved hashes.
    /// A v=1 signature is 65 bytes like an ECDSA one, so the calldata - and so the gas - is the
    /// size the signed transaction will be. Safe here is the L2 singleton, which logs the whole
    /// `data` again in `SafeMultiSigTransaction`; that is why this is measured through the Safe
    /// and not as a bare `scheduleBatch`.
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

    /// @dev 09's and 10's own assertions, made against the state the batch leaves behind.
    function _check(
        address factory,
        address timelock,
        address sink,
        address cranker,
        address factoryOwner,
        bool whitelistedBefore,
        bool rehearsal
    ) internal view {
        BuybackBurnSink s = BuybackBurnSink(payable(sink));
        require(address(s.BURN_TOKEN()) == readAddress("launchpad.burnToken"), "sink burns the wrong token");
        require(Currency.unwrap(s.QUOTE()) == readAddress("external.wINJ"), "sink quotes the wrong currency");
        require(s.owner() == timelock, "sink is not timelock-owned");
        require(s.MIN_BURN_BPS() == MIN_BURN_BPS && s.burnBps() == BURN_BPS, "sink carries the wrong burn bps");
        require(_lockersMatch(sink, _wantedLockers()), "the sink's lockers do not match the book");

        address locker = readAddress(LIVE_LOCKER_KEY);
        LaunchFeeCranker c = LaunchFeeCranker(cranker);
        require(address(c.SINK()) == sink, "cranker drives a different sink");
        require(address(c.LOCKER()) == locker, "cranker collects from a different locker than the book names");
        require(c.owner() == timelock, "cranker is not timelock-owned");
        require(s.isLocker(locker), "the sink does not list the cranker's locker");

        Create3Factory f = Create3Factory(factory);
        require(f.owner() == factoryOwner, "the batch moved the factory's owner");
        require(f.isUserWhitelisted(timelock) == whitelistedBefore, "the batch left the timelock's whitelist changed");

        console.log("");
        console.log("  [ok]   sink: burn token, quote, owner, bps and lockers as 09 requires");
        console.log("  [ok]   cranker: sink, locker and owner as 10 requires");
        console.log("  [ok]   factory: owner and the timelock's whitelist exactly as before the batch");
        if (c.feedIsWired()) {
            console.log("  [ok]   the locker's launchpadTreasury is the sink - a crank burns");
        } else if (rehearsal) {
            console.log(
                "  [--]   the locker's launchpadTreasury is not this sink - expected, a rehearsal sink is nobody's treasury"
            );
        } else {
            console.log("  [TODO] the locker's launchpadTreasury is NOT the sink (plan B6) - a crank will not burn");
        }
    }

    function _push(address target, bytes memory data, string memory label) internal {
        targets.push(target);
        payloads.push(data);
        labels.push(label);
    }

    function _lockersMatch(address sink, address[] memory wanted) internal view returns (bool) {
        if (sink.code.length == 0) return false;
        address[] memory installed = BuybackBurnSink(payable(sink)).lockers();
        if (installed.length != wanted.length) return false;
        for (uint256 i; i < wanted.length; ++i) {
            if (installed[i] != wanted[i]) return false;
        }
        return true;
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

    function _rehearsalSalt(string memory tag, string memory what) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("CHOICE-V2-REHEARSAL/", tag, "/", what));
    }

    function _printTimelockPayloads(address target, bytes memory payload)
        internal
        view
        override(DeployBuybackBurnSink, DeployLaunchFeeCranker)
    {
        DeployBuybackBurnSink._printTimelockPayloads(target, payload);
    }
}
