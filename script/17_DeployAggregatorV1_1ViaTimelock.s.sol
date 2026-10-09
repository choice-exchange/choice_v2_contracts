// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";

import {ChoiceAggregator} from "../src/router/ChoiceAggregator.sol";
import {DeploySinkAndCrankerViaTimelock} from "./13_DeploySinkAndCrankerViaTimelock.s.sol";

/**
 * `ChoiceAggregator` **1.1.0** - the `Adapter` step, the output fee and `executeWithPermit` -
 * deployed BY THE TIMELOCK in ONE batch, exactly as script 16 deployed 1.0.0:
 *
 *   1. factory.setWhitelistUser(timelock, true)
 *   2. factory.deploy(AGGREGATOR_SALT, ChoiceAggregator(timelock, permit2, wINJ, [vault, pumexVault]))
 *   3. factory.setWhitelistUser(timelock, false)
 *
 * Born timelock-owned with the same vaults 1.0.0 allowlists (Choice's, and Pumex's where the book
 * names it), so it routes the moment it lands. A new salt, because a CREATE3 salt IS an address:
 * 1.0.0 stays where it is, timelock-owned, holding nothing between transactions, and its Permit2
 * allowances can be spent only by the wallets that granted them.
 *
 * ## It broadcasts nothing
 *
 * It runs the batch through the real Safe and timelock in this script's fork, asserts the result,
 * and prints both calldatas with the gas each measured. After the batch executes, run it again: it
 * finds the contract, checks it byte for byte against this build, moves the book's
 * `choice.aggregator` to 1.1.0 and keeps 1.0.0 as `choice.aggregatorLegacy`. Until that re-run the
 * book still names 1.0.0, so nothing switches before the api and frontends are rolled onto it.
 *
 * 🔴 1.1.0 is a new Permit2 SPENDER: a wallet's allowance for 1.0.0 does not carry over. The
 * frontends cover that with `executeWithPermit` (a signature in the swap transaction).
 *
 *   NETWORK=injective_mainnet forge script \
 *     script/17_DeployAggregatorV1_1ViaTimelock.s.sol:DeployAggregatorV1_1ViaTimelock -vv \
 *     --rpc-url $RPC_URL
 */
contract DeployAggregatorV1_1ViaTimelock is DeploySinkAndCrankerViaTimelock {
    bytes32 internal constant AGGREGATOR_SALT = keccak256("CHOICE-V2/ChoiceAggregator/1.1.0");
    bytes32 internal constant AGGREGATOR_BATCH_SALT = keccak256("CHOICE-V2/AggregatorBatch/aggregator-1.1.0");

    struct Wiring {
        address timelock;
        address permit2;
        address winj;
        address vault;
        address pumexVault;
        address aggregator;
        address legacy;
    }

    function run() public override {
        require(block.chainid == readUint("chainId"), "the address book is for another chain - check NETWORK");

        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        Wiring memory w = _wiring(factory);

        console.log("ChoiceAggregator 1.1.0 ->", w.aggregator);
        if (w.legacy != address(0)) console.log("ChoiceAggregator 1.0.0 (stays, unpointed) ->", w.legacy);

        if (w.aggregator.code.length != 0) {
            // Code first: an older build at this salt may not even answer VERSION().
            _checkCode(w);
            _checkDeployed(w);
            if (w.legacy != address(0)) writeAddress("choice.aggregatorLegacy", w.legacy);
            writeAddress("choice.aggregator", w.aggregator);
            console.log("");
            console.log("Deployed and wired; the book now names 1.1.0. Sync it (make sync), then roll the api");
            console.log("and the frontend together: the api reads the book at boot, the frontend at build.");
            return;
        }

        address factoryOwner = factory.owner();
        bool whitelistedBefore = factory.isUserWhitelisted(w.timelock);
        bool bracket = factoryOwner == w.timelock && !whitelistedBefore;
        if (factoryOwner != w.timelock && !whitelistedBefore) {
            console.log("");
            console.log("The factory is owned by", factoryOwner);
            if (block.chainid == MAINNET_CHAIN_ID) {
                console.log("- not the timelock. See governance.factoryLockdownNote in the address book.");
            } else {
                console.log("- not the timelock - so the timelock cannot whitelist itself. From that owner, first:");
                console.log(string.concat("  factory.setWhitelistUser(", vm.toString(w.timelock), ", true)"));
                console.log("and remove it again once the batch has executed.");
            }
            revert("the timelock cannot deploy through this factory yet");
        }

        _buildBatch(factory, w, bracket);
        _simulateAndPrint(w.timelock, AGGREGATOR_BATCH_SALT, bracket);
        _checkCode(w);
        _checkDeployed(w);

        require(factory.owner() == factoryOwner, "the batch moved the factory's owner");
        require(
            factory.isUserWhitelisted(w.timelock) == whitelistedBefore,
            "the batch left the timelock's whitelist changed"
        );
        console.log("  [ok]   factory: owner and the timelock's whitelist exactly as before the batch");
    }

    /// @dev Everything the batch is built from, read and checked before anything is built.
    function _wiring(Create3Factory factory) internal view returns (Wiring memory w) {
        w.timelock = readAddress("governance.timelock");
        w.permit2 = readAddress("external.permit2");
        w.winj = readAddress("external.wINJ");
        w.vault = readAddress("infinity.vault");
        requireCode("timelock", w.timelock);
        requireCode("permit2", w.permit2);
        requireCode("vault", w.vault);
        // wINJ is a bank-backed MTS token on Injective: a forked EVM sees code at it, but cannot
        // call it. The aggregator only stores the address, so code is all there is to check.
        requireCode("wINJ", w.winj);

        w.pumexVault = readAddressOrZero("external.pumexVault");
        if (w.pumexVault != address(0)) {
            requireCode("pumexVault", w.pumexVault);
            require(w.pumexVault != w.vault, "external.pumexVault is Choice's own vault");
        }
        w.aggregator = factory.computeAddress(AGGREGATOR_SALT);

        // What the book names today is 1.0.0 until this script's re-run moves it. A re-run after
        // that finds 1.1.0 there; the legacy entry it already wrote is then left as it is.
        address named = readAddressOrZero("choice.aggregator");
        w.legacy = named == w.aggregator ? readAddressOrZero("choice.aggregatorLegacy") : named;
    }

    function _buildBatch(Create3Factory factory, Wiring memory w, bool bracket) internal {
        if (bracket) {
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.setWhitelistUser, (w.timelock, true)),
                "factory.setWhitelistUser(timelock, true)"
            );
        }
        bytes memory p = _aggregatorPayload(w);
        _push(
            address(factory),
            abi.encodeCall(Create3Factory.deploy, (AGGREGATOR_SALT, p, keccak256(p), 0, bytes(""), 0)),
            "factory.deploy(ChoiceAggregator 1.1.0)"
        );
        if (bracket) {
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.setWhitelistUser, (w.timelock, false)),
                "factory.setWhitelistUser(timelock, false)"
            );
        }
    }

    function _aggregatorPayload(Wiring memory w) internal pure returns (bytes memory) {
        IVault[] memory vaults = new IVault[](w.pumexVault == address(0) ? 1 : 2);
        vaults[0] = IVault(w.vault);
        if (w.pumexVault != address(0)) vaults[1] = IVault(w.pumexVault);
        return abi.encodePacked(
            type(ChoiceAggregator).creationCode,
            abi.encode(w.timelock, IAllowanceTransfer(w.permit2), IWETH9(w.winj), vaults)
        );
    }

    /// @dev What the contract must be, whether this fork just deployed it or the chain did.
    function _checkDeployed(Wiring memory w) internal view {
        ChoiceAggregator a = ChoiceAggregator(payable(w.aggregator));
        require(keccak256(bytes(a.VERSION())) == keccak256("1.1.0"), "the contract at the 1.1.0 salt is not 1.1.0");
        require(a.owner() == w.timelock, "aggregator is not timelock-owned");
        require(a.pendingOwner() == address(0), "aggregator has a pending owner");
        require(address(a.PERMIT2()) == w.permit2, "aggregator has the wrong permit2");
        require(address(a.WINJ()) == w.winj, "aggregator has the wrong wINJ");
        require(a.allowedVault(w.vault), "aggregator does not allow Choice's vault");
        if (w.pumexVault != address(0)) {
            require(a.allowedVault(w.pumexVault), "aggregator does not allow Pumex's vault");
        }
        require(a.MAX_FEE_BPS() == 100, "the fee ceiling is not 1%");
        console.log("");
        console.log(
            "  [ok]   aggregator 1.1.0: timelock-owned, permit2, wINJ, the book's vaults allowed, fee ceiling 1%"
        );
    }

    /// @dev The code at the CREATE3 address must be what THIS source builds, byte for byte. The
    /// wiring checks above cannot tell an old build from a new one, and the timelock's executor
    /// role is OPEN: a batch scheduled from an older build can be executed by anyone once its
    /// delay passes, and its salt is then spent on the old code. So a reference copy is built here,
    /// in this script's local fork only (nothing is broadcast), and the runtime hashes compared.
    function _checkCode(Wiring memory w) internal {
        bytes memory creation = _aggregatorPayload(w);
        address built;
        assembly ("memory-safe") {
            built := create(0, add(creation, 0x20), mload(creation))
        }
        require(built != address(0), "could not build a reference copy");
        require(
            built.codehash == w.aggregator.codehash,
            "the aggregator on chain is NOT this build - a batch from an older source was executed; do not write the book, bump AGGREGATOR_SALT"
        );
        console.log("  [ok]   code: the deployed runtime is this build's, byte for byte");
    }

    function _printNextSteps(bool bracket) internal view override {
        console.log("3. Re-run this script WITHOUT --broadcast: it finds 1.1.0, checks it, and moves the book to it.");
        console.log("   If this source changes before step 2, the Safe must timelock.cancel(id) and schedule anew:");
        console.log("   the executor role is open, and an executed stale batch spends the salt on old code.");
        if (!bracket) console.log("4. The factory's owner removes the timelock from the whitelist again.");
        console.log("");
        console.log("Nothing routes through 1.1.0 until choice.aggregator names it and the api and frontend");
        console.log("are rolled onto that book. 1.0.0 keeps working for anything still pointed at it.");
    }
}
