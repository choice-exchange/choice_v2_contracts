// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {BuybackBurnSink} from "../fees/BuybackBurnSink.sol";
import {ILaunchPositionLocker} from "../interfaces/ILaunchPositionLocker.sol";

/// @title LaunchFeeCranker
/// @notice One permissionless call that takes a graduated launch's accrued LP fees all the way
/// to destroyed SPROUT.
///
/// ## The problem this exists for
///
/// **Trading a graduated pool does not burn anything by itself.** The LP fee accrues inside the
/// locked full-range position automatically, and then it sits there. Turning it into burnt
/// SPROUT is three separate permissionless calls:
///
/// 1. `PositionLocker.collect(launchId)` - pull the fees out of the position and credit the
///    creator / launchpad split;
/// 2. `PositionLocker.claim(currency, launchpadTreasury)` - pay the launchpad's credit out, once
///    per currency, because a full-range position earns in BOTH;
/// 3. the sink's own leg for each of those currencies - `burn`, `buyback` or `convert`.
///
/// Every one of them is permissionless by design, so that no keeper is load-bearing and nobody
/// can be denied their fees. But "anybody can" is not "somebody does", and the plan that built
/// all three named nobody to make them. Under D30 the LP fee is a graduate's ONLY revenue, so
/// the burn rate this system advertises depends entirely on someone remembering.
///
/// This contract is that someone's one function call.
///
/// ## What it does NOT change
///
/// **No new trust.** Every destination was already fixed by somebody else: `collect` splits by
/// the launch's own immutable `creatorBps`, `claim` always pays the recipient it is told to and
/// this contract only ever names `launchpadTreasury`, and the sink's own guards decide what a
/// tranche does when it gets there. A caller of `crank` chooses WHEN and pays the gas. That is
/// the same bargain the three calls already offered.
///
/// **It holds nothing.** No token ever lands here: `collect` pays the locker, `claim` pays the
/// treasury, and the sink acts on its own balance. There is therefore no owner, no sweep and no
/// upgrade path - and ⚠️ a token deliberately sent here is stuck for ever, which is the honest
/// price of having no privileged address at all.
///
/// ## Why every leg is wrapped
///
/// 🔴 A helper that reverts when there is nothing to do is useless to the keeper it exists for.
/// `collect` reverts `NothingToCollect` on a launch whose fees were taken a minute ago, and
/// `claim` reverts `NothingToClaim` for a currency the position has not earned yet - which is
/// the NORMAL state of a pool that has only been traded one way. Both are caught, so cranking a
/// quiet launch is a no-op that costs gas rather than a failed transaction, and `crankMany`
/// can walk a list without one idle launch killing the batch.
///
/// The sink legs are wrapped too, though the sink is built never to revert: `burn` and
/// `buyback` park rather than fail, but `convert` is allowed to revert (that is how a bad launch
/// hint is refused), and a launch paired against something other than the sink's `QUOTE` reaches
/// exactly that revert. It must not take the collect with it.
///
/// ## Which locker
///
/// 🔑 Bound to ONE locker, as an immutable, because the settler binds its locker the same way and
/// an ABI that can change under a contract is what wedged a graduation on 2026-09-06.
///
/// It is written against the PULL locker (1.1.0): collect credits, claim pays. The PUSH locker
/// (1.0.0) does not have `claim` at all, so a cranker deployed against one would find step 2
/// reverting with empty returndata into the `try` and step 1 having already delivered the money -
/// which is correct behaviour, by accident of the wrapping rather than by design. A second
/// instance is therefore one deploy if the older locker's launches are ever worth cranking; this
/// contract does not branch on which it is talking to, and deliberately so, because a helper that
/// sniffs which generation it faces is the same "five copies of what is current" problem in a
/// new place.
contract LaunchFeeCranker {
    /// @notice The locker holding the launch positions this cranker collects from.
    ILaunchPositionLocker public immutable LOCKER;

    /// @notice Where the locked positions live. Read off the locker, so it cannot disagree.
    ICLPositionManager public immutable POSITION_MANAGER;

    /// @notice The sink the fees are driven into.
    /// @dev Typed as the concrete contract on purpose. This contract calls four of its functions
    /// and one of them, `convert(Currency,uint256)`, is new in sink 1.2.0 - so the compiler, not
    /// a comment, is what keeps the two in lockstep. ⚠️ The consequence is that a sink redeploy
    /// is ALSO a cranker redeploy, because this reference is immutable. Say so in the script.
    BuybackBurnSink public immutable SINK;

    /// @notice `SINK.QUOTE()`, cached. Immutable there, so the copy cannot go stale.
    Currency public immutable QUOTE;

    /// @notice `SINK.BURN_TOKEN()`, cached. Immutable there, so the copy cannot go stale.
    address public immutable BURN_TOKEN;

    /// @notice What one crank did. Returned rather than only emitted so a keeper can decide
    /// whether the next one is worth its gas from an `eth_call`.
    struct Crank {
        uint256 tokenId;
        Currency currency0;
        Currency currency1;
        uint256 collected0;
        uint256 collected1;
        uint256 claimed0;
        uint256 claimed1;
        bool drove0;
        bool drove1;
    }

    error ZeroAddress();
    error NotRegistered(uint256 launchId);

    event Cranked(
        uint256 indexed launchId,
        uint256 collected0,
        uint256 collected1,
        uint256 claimed0,
        uint256 claimed1,
        bool drove0,
        bool drove1
    );

    constructor(ILaunchPositionLocker _locker, BuybackBurnSink _sink) {
        if (address(_locker) == address(0) || address(_sink) == address(0)) revert ZeroAddress();
        LOCKER = _locker;
        SINK = _sink;
        // Read rather than passed: two arguments that must agree are two arguments that can be
        // given inconsistently, and every one of these is immutable at its source.
        POSITION_MANAGER = _locker.POSITION_MANAGER();
        QUOTE = _sink.QUOTE();
        BURN_TOKEN = address(_sink.BURN_TOKEN());
    }

    /// @notice Collect a launch's accrued LP fees, pay the launchpad's share to the sink, and
    /// make the sink act on both currencies. Permissionless.
    ///
    /// @dev Reverts only on `launchId` naming nothing - a caller error, and one a keeper wants
    /// to hear about, since every OTHER reason a crank does nothing is a normal quiet launch and
    /// is reported in the return value instead. `crankMany` catches even this one.
    function crank(uint256 launchId) external returns (Crank memory result) {
        uint256 tokenId = LOCKER.getPosition(launchId).tokenId;
        if (tokenId == 0) revert NotRegistered(launchId);

        // The launch's real pool key, and with it the two currencies its fees arrive in. Read
        // from the position manager rather than assumed, exactly as the sink does - a graduate's
        // currencies are sorted by address, so which leg is the launch token differs per launch.
        (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        result.tokenId = tokenId;
        result.currency0 = key.currency0;
        result.currency1 = key.currency1;

        // 1. Out of the position. Reverts `NothingToCollect` on a launch with nothing accrued,
        //    which is the common case for anything cranked twice in a row.
        try LOCKER.collect(launchId) returns (uint256 amount0, uint256 amount1) {
            result.collected0 = amount0;
            result.collected1 = amount1;
        } catch {}

        // 2. Out of the locker's credit ledger. Read the recipient rather than assuming it is the
        //    sink: `launchpadTreasury` is owner-settable and has pointed at three addresses, and
        //    this contract must pay whatever it currently names or it would be redirecting money.
        //    If that is not the sink, step 3 simply finds nothing new - which is the truth.
        address recipient = LOCKER.launchpadTreasury();
        result.claimed0 = _claim(key.currency0, recipient);
        result.claimed1 = _claim(key.currency1, recipient);

        // 3. Into the burn. Order matters: converting a launch token ENDS in a buyback that
        //    spends the sink's whole quote balance, including whatever step 2 just claimed - so
        //    driving the launch-token leg first turns both currencies into one swap. The other
        //    order works and burns exactly as much, one rate-limit window later.
        bool zeroIsPassthrough = _isPassthrough(key.currency0);
        if (zeroIsPassthrough) {
            result.drove1 = _drive(key.currency1, launchId);
            result.drove0 = _drive(key.currency0, launchId);
        } else {
            result.drove0 = _drive(key.currency0, launchId);
            result.drove1 = _drive(key.currency1, launchId);
        }

        emit Cranked(
            launchId,
            result.collected0,
            result.collected1,
            result.claimed0,
            result.claimed1,
            result.drove0,
            result.drove1
        );
    }

    /// @notice Crank several launches in one transaction, skipping the ones that fail.
    /// @dev The shape a keeper actually wants: it holds a list of graduated launches, most of
    /// which have earned nothing since last time, and one unregistered or reverting id must not
    /// cost it the rest. `crank` is re-entered through an external self-call because Solidity
    /// cannot `try` a function in its own frame.
    /// @return ok Per input, whether that launch's crank ran to completion.
    function crankMany(uint256[] calldata launchIds) external returns (bool[] memory ok) {
        ok = new bool[](launchIds.length);
        for (uint256 i; i < launchIds.length; ++i) {
            try this.crank(launchIds[i]) returns (Crank memory) {
                ok[i] = true;
            } catch {}
        }
    }

    /// @notice Whether the locker currently pays the launchpad's share to the sink this cranker
    /// drives.
    /// @dev The B6 wiring, as a question anybody can ask. It was FALSE on both lockers for the
    /// whole life of the first two sinks - `launchpadTreasury` pointed at the pad treasury and at
    /// a superseded sink - so the burn leg was fed by nothing while every document said the loop
    /// was closed. A crank against an unwired locker still collects and still pays, it just pays
    /// somewhere that does not burn; this is how a deploy script and a dashboard tell.
    function feedIsWired() external view returns (bool) {
        return LOCKER.launchpadTreasury() == address(SINK);
    }

    /// @notice What `crank` would find without collecting: the launch's position and its pool.
    /// @dev A pure lookup, so a keeper can build its list of graduated launches once.
    /// @return tokenId Zero when the launch is not registered with this cranker's locker.
    function launchPool(uint256 launchId) external view returns (uint256 tokenId, PoolKey memory key) {
        tokenId = LOCKER.getPosition(launchId).tokenId;
        if (tokenId == 0) return (0, key);
        (key,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
    }

    /// @dev Pay one currency's credit out to `recipient`, tolerating the empty case.
    /// @return amount What was paid; zero when there was nothing, or when the locker has no
    /// `claim` at all (the 1.0.0 push locker, whose `collect` already delivered it).
    function _claim(Currency currency, address recipient) private returns (uint256 amount) {
        try LOCKER.claim(currency, recipient) returns (uint256 paid) {
            amount = paid;
        } catch {}
    }

    /// @dev A currency the sink already has a first-class leg for, so it needs no launch hint.
    function _isPassthrough(Currency currency) private view returns (bool) {
        return Currency.unwrap(currency) == BURN_TOKEN || currency == QUOTE;
    }

    /// @dev Make the sink act on one currency, choosing the leg the sink itself would choose.
    /// Wrapped because `convert` is allowed to revert - a launch paired against an asset that is
    /// not `QUOTE` reaches exactly that - and one refused leg must not unwind the collect.
    /// @return ok Whether the sink's call returned. It says nothing about whether the tranche
    /// traded: the sink parks rather than reverting, so a parked tranche returns `true`. The
    /// sink's own `Parked` event is what says which.
    function _drive(Currency currency, uint256 launchId) private returns (bool ok) {
        if (Currency.unwrap(currency) == BURN_TOKEN) {
            // The burn token needs no swap; `burn` splits the balance and destroys its share.
            // The amount argument is ignored by the sink, which acts on its balance.
            try SINK.burn(currency, 0) {
                ok = true;
            } catch {}
        } else if (currency == QUOTE) {
            try SINK.buyback() {
                ok = true;
            } catch {}
        } else {
            try SINK.convert(currency, launchId) {
                ok = true;
            } catch {}
        }
    }
}
