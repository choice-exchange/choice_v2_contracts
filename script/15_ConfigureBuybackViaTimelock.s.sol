// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

import {IBuybackBurnSink} from "../src/interfaces/IBuybackBurnSink.sol";
import {DeploySinkAndCrankerViaTimelock, ITimelockBatch} from "./13_DeploySinkAndCrankerViaTimelock.s.sol";

/**
 * Turn the buyback ON: the sink's whole configuration as ONE timelock batch.
 *
 * Script 13 deploys the sink inert. Until this batch executes, every buyback and every conversion
 * parks: no tranche cap (reason 8), no buyback launch (reason 2), and `maxImpactBps` 0, so no
 * swap can be priced. Revenue keeps accruing safely in the meantime. This batch is the switch,
 * and it is scheduled when the burn should start, not when the sink is deployed.
 *
 * 🔴 **One batch, and the order inside it, are the 2026-10-01 audit's F3.** Script 09 used to
 * print these as four separate timelock operations. The timelock's executor role is open, so
 * once they were all ready, anyone could execute `setGuards` and `setBuybackPool` and then
 * sandwich the sink in the SAME transaction, before `setMaxBuybackAmount` or `setOperator`
 * landed. One `scheduleBatch` executes atomically. Inside it, the cap and the operator come
 * first and `setGuards` comes last, so even a partial read of the batch never describes a
 * live sink without its bounds.
 *
 *   1. sink.setMaxBuybackAmount(MAX_BUYBACK)
 *   2. sink.setOperator(launchpad.buybackOperator, FALLBACK_DELAY)
 *   3. sink.setBuybackLaunch(launchpad.burnTokenLaunchId)
 *   4. sink.setGuards(MIN_BUYBACK, MAX_IMPACT_BPS, MIN_INTERVAL)   <- the switch
 *
 * A step whose value is already in place is left out, so a re-run after a partial change
 * schedules only what differs. The values are script 09's constants, so its report and this
 * batch cannot disagree.
 *
 * 🔑 **A retune needs its own salt.** A timelock operation id is a hash of the calls and the
 * salt, and an executed id can never be scheduled again. So the second time the SAME change is
 * made (cap 10 -> 5 -> 10 -> 5), the batch hashes to an id that is already done. Set
 * `TURN_ON_SALT_TAG` to anything new for each retune, the date is enough
 * (`TURN_ON_SALT_TAG=2026-10-20`). Leave it unset for the first turn-on, whose id is the one
 * the 2026-10-08 review printed. The script refuses an id that has already executed rather
 * than printing a schedule the timelock would reject.
 *
 * ⚠️ Schedule this only once script 13's batch has EXECUTED. The script refuses before the sink
 * has code, but the calls themselves are fixed, so a hand-built copy scheduled earlier could be
 * executed (by anyone, the executor role is open) against an empty address. Every call would
 * succeed doing nothing, and the id would be spent.
 *
 * Like 13, it broadcasts nothing. It runs the batch through the real Safe and the real timelock
 * in this script's fork, asserts the result, and prints both calldatas and the gas each one
 * measured.
 *
 * ⚠️ Before EXECUTING on mainnet: roll a keeper that has the buyback loop, with
 * `BUYBACK_ENABLED=true` and the operator's key. The public path is held for `FALLBACK_DELAY`
 * after the operator is appointed and after each of its fills, 30 days, so a missing keeper
 * delays buybacks, and never costs money.
 *
 *   NETWORK=injective_mainnet forge script \
 *     script/15_ConfigureBuybackViaTimelock.s.sol:ConfigureBuybackViaTimelock -vv --rpc-url $RPC_URL
 *
 * `REHEARSAL_TAG=<tag>` configures script 13's rehearsal sink for the same tag instead (refused
 * on mainnet). A rehearsal may also take `REHEARSAL_BURN_LAUNCH_ID` and `REHEARSAL_OPERATOR`,
 * alongside 13's `REHEARSAL_BURN_TOKEN`, so that it can run against a burn token shaped like
 * mainnet's without touching the book.
 */
contract ConfigureBuybackViaTimelock is DeploySinkAndCrankerViaTimelock {
    bytes32 internal constant TURN_ON_SALT = keccak256("CHOICE-V2/BuybackTurnOn/sink-1.8.0");

    function run() public override {
        require(block.chainid == readUint("chainId"), "the address book is for another chain - check NETWORK");

        string memory tag = vm.envOr("REHEARSAL_TAG", string(""));
        bool rehearsal = bytes(tag).length != 0;
        require(!rehearsal || block.chainid != MAINNET_CHAIN_ID, "REHEARSAL_TAG is refused on mainnet");
        rehearsing = rehearsal;

        Create3Factory factory = Create3Factory(readAddress("governance.create3Factory"));
        address timelock = readAddress("governance.timelock");
        address sink = factory.computeAddress(rehearsal ? _rehearsalSalt(tag, "BuybackBurnSink") : SINK_SALT);
        require(sink.code.length != 0, "the sink is not deployed - script 13's batch comes first");
        IBuybackBurnSink s = IBuybackBurnSink(sink);

        address operator = rehearsal
            ? vm.envOr("REHEARSAL_OPERATOR", readAddressOrZero("launchpad.buybackOperator"))
            : readAddressOrZero("launchpad.buybackOperator");
        require(
            operator != address(0),
            "launchpad.buybackOperator is not in the book - the turn-on appoints the key that runs the TWAP"
        );
        uint256 launchId = rehearsal
            ? vm.envOr("REHEARSAL_BURN_LAUNCH_ID", readUint("launchpad.burnTokenLaunchId"))
            : readUint("launchpad.burnTokenLaunchId");
        (, address locker) = s.launchPool(launchId);
        require(locker != address(0), "no installed locker knows the burn token's launch - script 13 sets them");

        console.log(rehearsal ? "REHEARSAL turn-on, tag:" : "BuybackBurnSink turn-on", tag);
        console.log("BuybackBurnSink ->", sink);
        console.log("operator        ->", operator);
        console.log("burn launch     ->", launchId);

        if (s.maxBuybackAmount() != MAX_BUYBACK) {
            _push(sink, abi.encodeCall(IBuybackBurnSink.setMaxBuybackAmount, (MAX_BUYBACK)), "sink.setMaxBuybackAmount");
        }
        if (s.operator() != operator || s.publicFallbackDelay() != FALLBACK_DELAY) {
            _push(sink, abi.encodeCall(IBuybackBurnSink.setOperator, (operator, FALLBACK_DELAY)), "sink.setOperator");
        }
        if (s.buybackLaunchId() != launchId || s.buybackAnchor() == 0) {
            _push(sink, abi.encodeCall(IBuybackBurnSink.setBuybackLaunch, (launchId)), "sink.setBuybackLaunch");
        }
        if (
            s.maxImpactBps() != MAX_IMPACT_BPS || s.minBuybackAmount() != MIN_BUYBACK
                || s.minBuybackInterval() != MIN_INTERVAL
        ) {
            _push(
                sink,
                abi.encodeCall(IBuybackBurnSink.setGuards, (MIN_BUYBACK, MAX_IMPACT_BPS, MIN_INTERVAL)),
                "sink.setGuards  <- the switch, last"
            );
        }

        if (targets.length == 0) {
            console.log("");
            console.log("Nothing to schedule: the sink already carries every value this batch would set.");
            return;
        }

        bytes32 salt = _turnOnSalt(rehearsal, tag, vm.envOr("TURN_ON_SALT_TAG", string("")));
        _refuseSpentId(ITimelockBatch(timelock), salt);
        _simulateAndPrint(timelock, salt, true);
        _checkConfigured(s, operator, launchId);
    }

    /// @dev The first turn-on keeps `TURN_ON_SALT` itself. A retune appends its tag.
    function _turnOnSalt(bool rehearsal, string memory tag, string memory retuneTag) internal pure returns (bytes32) {
        bytes32 base = rehearsal ? _rehearsalSalt(tag, "turn-on") : TURN_ON_SALT;
        return bytes(retuneTag).length == 0 ? base : keccak256(abi.encodePacked(base, "/", retuneTag));
    }

    function _refuseSpentId(ITimelockBatch tl, bytes32 salt) internal view {
        bytes32 id = tl.hashOperationBatch(targets, new uint256[](targets.length), payloads, bytes32(0), salt);
        if (tl.isOperationDone(id)) {
            console.log("Operation id already executed:");
            console.logBytes32(id);
            revert("this exact batch already ran under this salt - set TURN_ON_SALT_TAG to something new");
        }
    }

    function _printNextSteps(bool) internal view override {
        console.log("3. Re-run 09 WITHOUT --broadcast: it should report the sink configured.");
        console.log("");
        console.log("Before step 2 on mainnet: the keeper with the buyback loop is rolled, BUYBACK_ENABLED=true,");
        console.log("signing with the operator key. The public path stays held for 30 days after its last fill.");
    }

    /// @dev What the batch must leave behind, asserted against the state it left in this fork.
    function _checkConfigured(IBuybackBurnSink s, address operator, uint256 launchId) internal view {
        require(s.maxBuybackAmount() == MAX_BUYBACK, "the tranche cap did not land");
        require(s.operator() == operator && s.publicFallbackDelay() == FALLBACK_DELAY, "the operator did not land");
        require(s.buybackLaunchId() == launchId && s.buybackAnchor() != 0, "the buyback launch did not land");
        require(
            s.maxImpactBps() == MAX_IMPACT_BPS && s.minBuybackAmount() == MIN_BUYBACK
                && s.minBuybackInterval() == MIN_INTERVAL,
            "the guards did not land"
        );
        console.log("");
        console.log("  [ok]   tranche cap, operator, buyback launch and guards, exactly as 09 reports them");
        console.log("  [ok]   buyback anchor (the burn token's locked position):", s.buybackAnchor());
    }
}
