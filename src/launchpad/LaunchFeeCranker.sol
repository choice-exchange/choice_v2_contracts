// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {BuybackBurnSink} from "../fees/BuybackBurnSink.sol";
import {IBurnableERC20} from "../interfaces/IBurnableERC20.sol";
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
/// treasury, and the sink acts on its own balance. There is no sweep and no upgrade path - and
/// ⚠️ a token deliberately sent here is stuck for ever, which is the honest price of not having
/// a way to move money out.
///
/// 🔑 **It has an owner as of 2.0.0, and A6 deliberately gave it none. Here is why that was
/// re-taken.** The original argument is real and has not stopped being real: *a cranker that can
/// be repointed is a cranker whose destination is mutable*, and the whole reason this contract
/// adds no trust is that every destination was fixed by somebody else before it was deployed.
/// An owner that can call `setSink` can, in principle, point the burn somewhere that does not
/// burn.
///
/// What changed is that the immutability was measured, and it did not buy what it was supposed
/// to:
///
/// - **It never actually pinned the destination.** `SINK` was immutable, but the sink's
///   `treasury`, `burnBps`, `buybackPool`, `lockers` and `quoteRoute` are all owner-settable, and
///   `PositionLocker.launchpadTreasury` - the field that decides whether a crank's money reaches
///   the sink at all - is owner-settable too and **has pointed at three different addresses**.
///   The same timelock owns all of them. So the burn destination was always mutable by the
///   timelock; the immutable here made it mutable *in more transactions*, not in fewer hands.
/// - **It cost real money to keep, twice.** Sink 1.2.0 -> 1.3.0 forced cranker 1.0.0 -> 1.1.0
///   for no reason but this field. And because `LOCKER` is immutable too, one instance reaches
///   exactly one locker generation - so plan A9 had to deploy a *second cranker* rather than
///   change a setting, and until it did, **SPROUT's own launch 15 had nothing scheduled to move
///   its fees** while the keeper reported a healthy pass every fifteen minutes. Nothing was
///   broken and nothing said anything. That is the failure mode immutability produced.
/// - **The comparison case is in the same repo.** `BuybackBurnSink.setLockers` is the identical
///   problem decided the other way, and it is why ONE sink serves both locker generations.
///
/// ⛔ **So the trade is deliberate and it is bounded.** The owner is the **timelock**, so every
/// repoint is Safe -> propose -> wait out the full delay -> execute, in public, with an event. It
/// buys nothing that the timelock could not already do by redeploying this contract and repointing
/// the keeper; it removes the redeploy, the second cranker, and the fifteen minutes of healthy
/// passes over a launch nobody was collecting. 🔴 It does NOT make the setters safe to give to
/// anything else: an EOA owner here really would be a mutable burn destination in one hand, which
/// is exactly what A6 refused. The owner must be the timelock and script 10 asserts it.
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
/// 🔑 Bound to ONE locker at a time. Settable as of 2.0.0 (see above), but still ONE - this
/// contract does not branch on which generation it faces, and deliberately so, because a helper
/// that sniffs that is the "N copies of what is current" problem in a new place.
///
/// It is written against the PULL locker (1.1.0): collect credits, claim pays. The PUSH locker
/// (1.0.0) does not have `claim` at all, so a cranker pointed at one finds step 2 reverting with
/// empty returndata into the `try` and step 1 having already delivered the money - which is
/// correct behaviour, by accident of the wrapping rather than by design, and is exercised by
/// `test_aSecondInstanceAgainstAPushLockerStillBurns`.
///
/// 🔴 **A generation is still a `setLocker` call, never a branch, and the two are not
/// interchangeable at the same instant**: while this cranker points at one locker it cannot
/// collect the other's launches. Serving both simultaneously is still two instances. What the
/// setter removes is the case where serving the *newer* one meant redeploying.
contract LaunchFeeCranker is Ownable2Step {
    /// @notice The locker holding the launch positions this cranker collects from.
    /// @dev ⚠️ SCREAMING_CASE, and as of 2.0.0 it is NOT immutable. The name is kept because
    /// `LOCKER()` and `SINK()` are what script 10 asserts and what the keeper reads, and the two
    /// live 1.1.0 instances answer to those names - renaming would mean one tool could no longer
    /// check both generations. Read the setters, not the casing.
    ILaunchPositionLocker public LOCKER;

    /// @notice Where the locked positions live. Read off the locker, so it cannot disagree.
    /// @dev Re-derived by `setLocker`, never set directly. A locker generation that moved to a
    /// new position manager would otherwise leave this pointing at the old one and every
    /// `getPoolAndPositionInfo` would answer about somebody else's token id.
    ICLPositionManager public POSITION_MANAGER;

    /// @notice The sink the fees are driven into.
    /// @dev Typed as the concrete contract on purpose. This contract calls four of its functions
    /// and one of them, `convert(Currency,uint256)`, is new in sink 1.2.0 - so the compiler, not
    /// a comment, is what keeps the two in lockstep at BUILD time. 🔴 That says nothing about the
    /// address `setSink` is given, which is why the setter probes it.
    BuybackBurnSink public SINK;

    /// @notice `SINK.QUOTE()`, cached. Immutable on the sink, so it can only change when the sink does.
    /// @dev Re-derived by `setSink`. It decides which leg `_drive` takes, so a stale copy would
    /// route a launch token into `buyback` or the quote into `convert` - silently, since both are
    /// wrapped in `try`.
    Currency public QUOTE;

    /// @notice `SINK.BURN_TOKEN()`, cached. Immutable on the sink, so it can only change when the sink does.
    /// @dev Re-derived by `setSink`, and the old and new values are both in `SinkUpdated` -
    /// changing which token gets destroyed is the loudest thing a sink swap can do quietly.
    address public BURN_TOKEN;

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
    /// @dev The address given to `setSink` does not answer `QUOTE()` and `BURN_TOKEN()`.
    /// A NAMED error, because the alternative is the empty revert of a missing selector: this
    /// repo has already spent one wedged graduation learning that an absent function reverts
    /// with nothing to read (plan A3).
    error NotASink(address given);
    /// @dev The address given to `setLocker` does not answer `POSITION_MANAGER()` and
    /// `launchpadTreasury()`. Same reasoning as `NotASink`. ⚠️ Both generations of locker answer
    /// both, which is the point - this check accepts a 1.0.0 push locker and rejects a contract
    /// that is not a locker at all.
    error NotALocker(address given);

    /// @notice The sink was repointed. Carries every derived value either side of the change,
    /// so a reader of the log never has to go and ask what `QUOTE` or `BURN_TOKEN` became.
    event SinkUpdated(
        address indexed oldSink,
        address indexed newSink,
        Currency oldQuote,
        Currency newQuote,
        address oldBurnToken,
        address newBurnToken
    );

    /// @notice The locker was repointed, with the position manager it re-derived.
    event LockerUpdated(
        address indexed oldLocker, address indexed newLocker, address oldPositionManager, address newPositionManager
    );

    event Cranked(
        uint256 indexed launchId,
        uint256 collected0,
        uint256 collected1,
        uint256 claimed0,
        uint256 claimed1,
        bool drove0,
        bool drove1
    );

    /// @param _owner 🔴 The TIMELOCK. See the header: the setters below are only defensible
    /// behind a delay, and an EOA owner here is a mutable burn destination in one hand.
    constructor(ILaunchPositionLocker _locker, BuybackBurnSink _sink, address _owner) Ownable(_owner) {
        // Ownable(0) reverts on its own with OwnableInvalidOwner, which is a better error than
        // ours would be, so only the two this contract knows about are checked here.
        if (address(_locker) == address(0) || address(_sink) == address(0)) revert ZeroAddress();
        _setLocker(_locker);
        _setSink(_sink);
    }

    // -------------------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------------------

    /// @notice Point this cranker at a different burn sink. Timelock only.
    ///
    /// @dev This is the setter that ends *"a sink redeploy is ALWAYS a cranker redeploy"*, which
    /// this deployment paid for once already when sink 1.2.0 -> 1.3.0 forced cranker 1.0.0 ->
    /// 1.1.0 for no other reason. See the header for why A6's immutability was re-taken.
    ///
    /// 🔴 **A sink swap is still not free, and this setter is not the whole of it.** The sink's
    /// own `lockers` set must contain `LOCKER` or every crank collects, claims, and then finds no
    /// route - `feedIsWired()` and `sinkKnowsOurLocker()` are the two questions to ask
    /// afterwards, and script 10 asserts both. Neither is *required* here on purpose: forcing an
    /// order would make a legitimate move of both ends impossible in a single timelock batch.
    function setSink(BuybackBurnSink newSink) external onlyOwner {
        if (address(newSink) == address(0)) revert ZeroAddress();
        _setSink(newSink);
    }

    /// @notice Point this cranker at a different position locker. Timelock only.
    ///
    /// @dev This is the setter that ends *"one instance reaches exactly one locker generation"*.
    /// Plan A9 had to deploy a second cranker because of it, and for as long as only one existed,
    /// **SPROUT's own launch 15 had nothing scheduled to move its fees** while the keeper
    /// reported a healthy pass every fifteen minutes.
    ///
    /// ⚠️ It moves this instance from one generation to the other; it does not serve both. The
    /// launches of the locker being left behind stop being cranked by *this* contract the moment
    /// this lands, so a second instance is still the answer when both need serving at once.
    function setLocker(ILaunchPositionLocker newLocker) external onlyOwner {
        if (address(newLocker) == address(0)) revert ZeroAddress();
        _setLocker(newLocker);
    }

    /// @dev Probe, derive, then assign. The probe is the whole value of the setter being a
    /// function rather than a raw storage write: a wrong address here would otherwise be found
    /// by `_drive` swallowing an empty revert into a `try` and reporting `false` for ever.
    function _setSink(BuybackBurnSink newSink) private {
        // 🔴 An address with NO CODE first, and separately, because `try` does not reliably turn
        // it into a catchable failure: a high-level call to an EOA can return empty and revert on
        // the decode OUTSIDE the catch, which surfaces as a bare revert with no data - the exact
        // unreadable failure the named errors below exist to prevent. A typo'd address is the
        // likeliest wrong argument this function will ever get.
        if (address(newSink).code.length == 0) revert NotASink(address(newSink));

        Currency newQuote;
        address newBurnToken;
        try newSink.QUOTE() returns (Currency q) {
            newQuote = q;
        } catch {
            revert NotASink(address(newSink));
        }
        try newSink.BURN_TOKEN() returns (IBurnableERC20 b) {
            newBurnToken = address(b);
        } catch {
            revert NotASink(address(newSink));
        }
        if (newBurnToken == address(0)) revert NotASink(address(newSink));

        emit SinkUpdated(address(SINK), address(newSink), QUOTE, newQuote, BURN_TOKEN, newBurnToken);

        SINK = newSink;
        // Derived, never passed: two arguments that must agree are two arguments that can be
        // given inconsistently, and both of these are immutable at their source.
        QUOTE = newQuote;
        BURN_TOKEN = newBurnToken;
    }

    /// @dev Same shape as `_setSink`. `launchpadTreasury()` is probed as well as
    /// `POSITION_MANAGER()` because `crank` calls it every time and `feedIsWired()` is built on
    /// it, so a locker that answered one and not the other would pass a check and fail in use.
    function _setLocker(ILaunchPositionLocker newLocker) private {
        // Same reasoning as `_setSink`: an EOA is checked by code size, not by `try`.
        if (address(newLocker).code.length == 0) revert NotALocker(address(newLocker));

        ICLPositionManager newPositionManager;
        try newLocker.POSITION_MANAGER() returns (ICLPositionManager pm) {
            newPositionManager = pm;
        } catch {
            revert NotALocker(address(newLocker));
        }
        try newLocker.launchpadTreasury() returns (address) {}
        catch {
            revert NotALocker(address(newLocker));
        }
        if (address(newPositionManager) == address(0)) revert NotALocker(address(newLocker));

        emit LockerUpdated(address(LOCKER), address(newLocker), address(POSITION_MANAGER), address(newPositionManager));

        LOCKER = newLocker;
        POSITION_MANAGER = newPositionManager;
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

    /// @notice Whether the sink can resolve this cranker's locker's launches at all.
    /// @dev The other half of the wiring, and the half `feedIsWired` cannot see. Since plan A5 the
    /// sink finds a graduate's pool by asking a locker in its OWN `lockers` set, so a cranker
    /// whose locker is not in that set collects and claims correctly and then has every `convert`
    /// refused. Both setters deliberately decline to enforce this - ordering a two-ended move
    /// would be impossible if they did - so this is the question to ask after one, and script 10
    /// asserts it at deploy.
    function sinkKnowsOurLocker() external view returns (bool) {
        return SINK.isLocker(address(LOCKER));
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
