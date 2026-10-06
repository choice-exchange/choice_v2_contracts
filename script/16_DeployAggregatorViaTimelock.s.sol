// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {CLQuoter} from "infinity-periphery/src/pool-cl/lens/CLQuoter.sol";

import {ChoiceAggregator} from "../src/router/ChoiceAggregator.sol";
import {DeploySinkAndCrankerViaTimelock} from "./13_DeploySinkAndCrankerViaTimelock.s.sol";

/**
 * `ChoiceAggregator`, and a `CLQuoter` over Pumex's CL pool manager, deployed BY THE TIMELOCK in
 * ONE batch:
 *
 *   1. factory.setWhitelistUser(timelock, true)
 *   2. factory.deploy(AGGREGATOR_SALT,   ChoiceAggregator(timelock, permit2, wINJ, [vault, pumexVault]))
 *   3. factory.deploy(PUMEX_QUOTER_SALT, CLQuoter(pumexClPoolManager))
 *   4. factory.setWhitelistUser(timelock, false)
 *
 * The aggregator is born OWNED BY THE TIMELOCK (`Ownable(_owner)`, no pending-owner window) with
 * every vault this network has allowlisted, so it routes the moment it lands: no second batch.
 * On a network without Pumex (`external.pumexVault` absent, as on testnet) it allowlists Choice's
 * vault alone and step 3 is left out.
 *
 * 🔑 The quoter is upstream's `CLQuoter`, unchanged. Pumex ships none, and `/route` prices a Pumex
 * pool by running OUR quoter's code against Pumex's manager - today by overriding the code of an
 * `eth_call`, which works but sends ~7 KB of bytecode (14 KB of hex) with every quote and depends on the RPC
 * honouring a state override. This puts the same code at a fixed address. Its constructor reads
 * `vault()` off the manager, so it needs nothing from Pumex but the manager's address.
 *
 * It is a quoter: it holds nothing, owns nothing and can move nothing. It sits at a CHOICE-V2 salt
 * only because the CREATE3 factory is how this deployment places code, and so that its address is
 * known before it exists.
 *
 * ## It broadcasts nothing
 *
 * Exactly as script 13: it runs the batch through the real Safe and timelock in this script's
 * fork, asserts the result, and prints both calldatas and the gas each one measured. After the
 * batch executes, run it again: it finds both contracts, checks them, and writes
 * `choice.aggregator` and `choice.pumexClQuoter` into the book. Until then the book names
 * neither, which is what keeps the backend's aggregator routes switched off.
 *
 *   NETWORK=injective_mainnet forge script \
 *     script/16_DeployAggregatorViaTimelock.s.sol:DeployAggregatorViaTimelock -vv \
 *     --rpc-url $RPC_URL
 */
contract DeployAggregatorViaTimelock is DeploySinkAndCrankerViaTimelock {
    bytes32 internal constant AGGREGATOR_SALT = keccak256("CHOICE-V2/ChoiceAggregator/1.0.0");
    bytes32 internal constant PUMEX_QUOTER_SALT = keccak256("CHOICE-V2/PumexCLQuoter/1.0.0");
    bytes32 internal constant AGGREGATOR_BATCH_SALT =
        keccak256("CHOICE-V2/AggregatorBatch/aggregator-1.0.0+pumex-cl-quoter-1.0.0");

    struct Wiring {
        address timelock;
        address permit2;
        address winj;
        address vault;
        address pumexVault;
        address pumexManager;
        address aggregator;
        address quoter;
    }

    function run() public override {
        require(block.chainid == readUint("chainId"), "the address book is for another chain - check NETWORK");

        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        Wiring memory w = _wiring(factory);

        console.log("ChoiceAggregator 1.0.0 ->", w.aggregator);
        if (w.quoter != address(0)) console.log("Pumex CLQuoter   1.0.0 ->", w.quoter);
        else console.log("No Pumex on this network: the aggregator allowlists Choice's vault alone.");

        bool aggregatorLanded = w.aggregator.code.length != 0;
        bool quoterLanded = w.quoter == address(0) || w.quoter.code.length != 0;
        if (aggregatorLanded && quoterLanded) {
            _checkDeployed(w);
            writeAddress("choice.aggregator", w.aggregator);
            if (w.quoter != address(0)) writeAddress("choice.pumexClQuoter", w.quoter);
            console.log("");
            console.log("Both are deployed and wired. Sync the book (make sync) to switch /route's aggregator on.");
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

        _buildAggregatorBatch(factory, w, !aggregatorLanded, !quoterLanded, bracket);
        _simulateAndPrint(w.timelock, AGGREGATOR_BATCH_SALT, bracket);
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
        w.pumexManager = readAddressOrZero("external.pumexClPoolManager");
        require(
            (w.pumexVault == address(0)) == (w.pumexManager == address(0)),
            "external.pumexVault and external.pumexClPoolManager are a pair - set both or neither"
        );
        if (w.pumexManager != address(0)) {
            requireCode("pumexVault", w.pumexVault);
            requireCode("pumexClPoolManager", w.pumexManager);
            require(w.pumexVault != w.vault, "external.pumexVault is Choice's own vault");
            // The quoter takes its vault from the manager, and the aggregator allowlists the vault
            // from the book. They must be the same vault, or the quoter prices pools the
            // aggregator cannot reach.
            require(
                address(ICLPoolManager(w.pumexManager).vault()) == w.pumexVault,
                "Pumex's pool manager settles on a different vault than external.pumexVault"
            );
            w.quoter = factory.computeAddress(PUMEX_QUOTER_SALT);
        }
        w.aggregator = factory.computeAddress(AGGREGATOR_SALT);
    }

    function _buildAggregatorBatch(
        Create3Factory factory,
        Wiring memory w,
        bool deployAggregator,
        bool deployQuoter,
        bool bracket
    ) internal {
        if (bracket) {
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.setWhitelistUser, (w.timelock, true)),
                "factory.setWhitelistUser(timelock, true)"
            );
        }
        if (deployAggregator) {
            bytes memory p = _aggregatorPayload(w);
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.deploy, (AGGREGATOR_SALT, p, keccak256(p), 0, bytes(""), 0)),
                "factory.deploy(ChoiceAggregator)"
            );
        }
        if (deployQuoter) {
            bytes memory p = abi.encodePacked(type(CLQuoter).creationCode, abi.encode(w.pumexManager));
            _push(
                address(factory),
                abi.encodeCall(Create3Factory.deploy, (PUMEX_QUOTER_SALT, p, keccak256(p), 0, bytes(""), 0)),
                "factory.deploy(CLQuoter(pumexClPoolManager))"
            );
        }
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

    /// @dev What both contracts must be, whether this fork just deployed them or the chain did.
    function _checkDeployed(Wiring memory w) internal view {
        ChoiceAggregator a = ChoiceAggregator(payable(w.aggregator));
        require(a.owner() == w.timelock, "aggregator is not timelock-owned");
        require(a.pendingOwner() == address(0), "aggregator has a pending owner");
        require(address(a.PERMIT2()) == w.permit2, "aggregator has the wrong permit2");
        require(address(a.WINJ()) == w.winj, "aggregator has the wrong wINJ");
        require(a.allowedVault(w.vault), "aggregator does not allow Choice's vault");
        console.log("");
        console.log("  [ok]   aggregator: timelock-owned, permit2, wINJ, Choice's vault allowed");

        if (w.quoter == address(0)) return;
        require(a.allowedVault(w.pumexVault), "aggregator does not allow Pumex's vault");
        CLQuoter q = CLQuoter(w.quoter);
        require(address(q.poolManager()) == w.pumexManager, "quoter reads a different pool manager");
        require(address(q.vault()) == w.pumexVault, "quoter locks a different vault");
        console.log("  [ok]   aggregator: Pumex's vault allowed");
        console.log("  [ok]   quoter: Pumex's CL pool manager, on Pumex's vault");
    }

    function _printNextSteps(bool bracket) internal view override {
        console.log("3. Re-run this script WITHOUT --broadcast: it finds both, checks them, writes the book.");
        if (!bracket) console.log("4. The factory's owner removes the timelock from the whitelist again.");
        console.log("");
        console.log("Nothing routes through the aggregator until choice.aggregator is in the book and synced:");
        console.log("the backend's /route reads it from there and stays on the UniversalRouter without it.");
    }
}
