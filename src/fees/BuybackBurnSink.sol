// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {IBurnSink} from "../interfaces/IBurnSink.sol";
import {IBurnableERC20} from "../interfaces/IBurnableERC20.sol";
import {ILaunchPositionLocker} from "../interfaces/ILaunchPositionLocker.sol";

/// @title BuybackBurnSink
/// @notice Burn sink C: turn protocol revenue into the launchpad token and destroy it.
///
/// Sinks A and B (`DirectTransferBurnSink`, `ExchangeSubaccountBurnSink`) feed Injective's burn
/// auction, which burns INJ. This one buys the LAUNCHPAD's own token on Choice's own pools and
/// burns that instead, so the pad's revenue accrues to the pad's token holders. All three
/// implement the same `IBurnSink`, so which one a deployment uses is one `setBurnSink` call.
///
/// **The point of this contract is that the burn is code rather than a promise.** The model it
/// copies - Pons on Robinhood Chain - enforces its creator/protocol split on chain and then
/// hands the protocol's share to an off-chain bot that buys and burns roughly every fifteen
/// minutes. Their 80/20 burn/ops split is a team policy their own docs say "isn't locked in
/// permanently yet", and a custodial wallet holds the fees in between. Here the buyback happens
/// inside the same transaction as the harvest, and `burnBps` can never fall below the
/// `MIN_BURN_BPS` fixed in this contract's constructor. That floor is the promise: the share
/// can be raised and lowered above it, but nothing - owner included - can take it under.
///
/// ## `burn` must never revert
///
/// `ChoiceFeeController.harvest` transfers to this contract and then calls `burn`, so a revert
/// here bricks harvesting for that currency - and a launch token with no pool would be a
/// trivially weaponisable way to do it. **Every gate in this contract therefore PARKS rather
/// than reverting**: funds it cannot act on yet simply stay here and are picked up by a later
/// call. Nothing is stranded, because the balance - not the `amount` argument - is what each
/// path acts on.
///
/// That guarantee is STRUCTURAL rather than a property of each gate in turn. The whole vault
/// lock runs inside `try/catch`, so anything that reverts underneath it - a pool the manager
/// has paused, a price bound the pool rejects, a hook that fails, something not thought of
/// here - parks the tranche instead of propagating. Enumerating the failure modes and gating
/// them one at a time was the earlier design, and it is the wrong shape: the list has to stay
/// complete forever, and it was not. Four escapes were reachable, `maxImpactBps = 0` - the
/// value a sink carries until `setGuards` is first called - among them.
///
/// The SETTLE runs inside its own `try/catch` for the same reason and was the last frame that
/// could still propagate: the swap being wrapped said nothing about `BURN_TOKEN.burn` or the
/// transfer to `treasury`, both of which reach the bank precompile and neither of which this
/// contract controls. See `_settleBurnToken` for why that wrapper is one atomic self-call and
/// not a `try` around each leg.
///
/// The named guards below still exist, because failing inside `setGuards` / `setBuybackPool`
/// says what is wrong while somebody is looking at it, where a park is silent.
///
/// That is also why the price guard is a `sqrtPriceLimitX96` on the swap rather than a
/// `minAmountOut` check afterwards. A limit makes the pool fill only as far as the bound and
/// stop, leaving the rest of the input here for next time; a minimum-out check would have to
/// revert, and reverting is the one thing this contract cannot do.
///
/// ## The normalise leg - why a third currency is not a dead end
///
/// A graduated launch pool is full range, so the LP fee it earns arrives in BOTH currencies: the
/// launchpad's share of a MEME/wINJ pool is part wINJ and part MEME. `burn` used to branch
/// `BURN_TOKEN` -> settle, `QUOTE` -> buy back, everything else -> park, and a launch token is
/// neither - so roughly half of a graduate's revenue parked for ever. Tokenomics D30/D31 made
/// that structural rather than incidental: with graduates paying no protocol fee, the LP fee is
/// the ONLY post-graduation revenue there is.
///
/// So a third currency is now CONVERTED: one exact-input swap, launch token -> `QUOTE`, against
/// that launch's own graduation pool, inside the same kind of lock the buyback opens and under
/// the same `maxImpactBps`. The proceeds fall straight into `_tryBuyback`, so one call converts,
/// buys and burns. Every gate on the way parks exactly as before.
///
/// **The sink ASKS FOR that pool rather than reconstructing one** (plan A5). A caller passes the
/// launch id alongside the currency, and the sink reads the graduate's own locked position out of
/// `PositionLocker` and takes the `PoolKey` the position manager holds for it. See `lockers`.
///
/// ## The second leg - a launch paired against something other than `QUOTE` (D28/A2)
///
/// One swap only reaches `QUOTE` when the graduate's pool holds `QUOTE`. A launch paired against
/// another quote asset - testnet's launch 19 is SAI-paired - has a pool that trades
/// `{launchToken, SAI}`, and until now the sink refused it by name and both halves of its LP fee
/// sat in the locker for ever. A full-range position earns in BOTH currencies, so that is not
/// half the problem: the SAI half is not a launch token at all, and no launch id could resolve
/// it.
///
/// So a conversion may now be TWO legs: the launch's own graduation pool to the pair asset, then
/// a REGISTERED pool from that asset to `QUOTE`. Both happen inside one vault lock, so nothing
/// lingers in between, and the second leg is registered per QUOTE ASSET rather than per launch -
/// a handful of entries, ever.
///
/// 🔑 **Why the second leg is named by the owner, when A5's whole lesson was to stop naming
/// things.** A5 derives a graduation pool safely because `LaunchPoolGuardHook` makes such a key
/// UN-CREATEABLE by anyone but an allowlisted settler: derive the key, and the only pool that can
/// exist at it is one a settler opened. An ordinary SAI/wINJ pool has no hook. Anybody may open a
/// hookless pool at any key, at any price - so a DERIVED second leg would name a pool an attacker
/// can create and price, and `maxImpactBps` could not save it, because the bound is measured
/// against that pool's own spot. Letting the permissionless caller pass a key is the same hole
/// with fewer steps. Deriving here is not merely unavailable; it is worse than useless.
///
/// And what a registered route IS, is `buybackPool` - the owner-named venue this contract has
/// always had, for the same reason (liquidity moves; the sink should follow without a redeploy).
/// It is NOT `conversionTier` coming back: that was a COPY of the settler's mutable config,
/// describing a class of pools, and it went stale the moment a launch graduated on another tier.
/// Nothing else in this system decides which pool trades SAI against wINJ.
///
/// ⚠️ **One composite impact bound, not one per leg.** `maxImpactBps` bounds the whole
/// conversion, so a two-leg route gets half the allowance per leg. Giving each leg the full
/// setting would silently let a two-leg conversion move prices twice as far at the same number,
/// and an operator setting one guard is entitled to have it mean one thing. `MIN_IMPACT_BPS` rose
/// from 2 to 4 for the same reason.
///
/// ## D32 - the hold allowlist
///
/// Converting is the default, because the burn rate is what the floor above promises. But the
/// timelock may designate an individual launch token to ACCUMULATE instead: `setHold` parks it
/// on sight, and `sweep` can then move it to the treasury. That is the old "no route" accident
/// promoted to intent, and it is also the only way a launch token leaves this contract without
/// being burnt - see `sweep`.
///
/// Holding trades burn rate for a bet that the token appreciates. Selective is the point;
/// holding by default would roughly halve the graduated burn.
///
/// ## What the owner can and cannot do
///
/// Thin, in the shape of `PositionLocker`'s: the pool to trade through, which position lockers
/// a conversion may read a graduate's pool out of, the thresholds, the treasury, and which launch
/// tokens are held rather than converted. The owner **cannot** lower `burnBps` past the floor, and
/// **cannot** sweep the quote asset or the burn token, which is what stops "recover a stuck token"
/// from becoming a way to take pending burn revenue.
///
/// 🔑 A5 made that list SHORTER by one entry that mattered. `setConversionTier` used to let the
/// owner name a `(poolManager, hooks, fee, parameters)` triple, and a hook the owner controls is a
/// pool the owner prices - so the tier was the widest lever here even with its zero-hook check.
/// The locker set that replaces it is narrower: a locker can only answer with a pool a SETTLER
/// registered a position into, and the currency check does the rest.
///
/// 🔴 That sweep guard now covers LAUNCH TOKENS too, because they became burn revenue the moment
/// they became convertible. `sweep` refuses any currency that is not on the hold allowlist, so
/// taking one out is `setHold` and then `sweep` - two calls, both of which emit, rather than one
/// that looks like housekeeping.
contract BuybackBurnSink is IBurnSink, Ownable2Step, ReentrancyGuardTransient, ILockCallback {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Smallest `maxImpactBps` that describes a real price bound.
    /// @dev `_priceLimit` halves the setting, so 0 and 1 both truncate to a limit equal to the
    /// pool's current sqrt price - which `CLPool.swap` rejects with `InvalidSqrtPriceLimit`.
    /// The `try/catch` makes that park rather than revert, but a guard that can never let a
    /// swap through is a misconfiguration, not a policy, so it is refused where it is set.
    ///
    /// 🔴 **4, not 2, since conversions became two-legged.** `maxImpactBps` is a bound on the
    /// WHOLE conversion, so a two-leg route splits it in half before `_priceLimit` halves it
    /// again - and a setting of 2 or 3 would give the second leg a limit equal to its pool's
    /// own price, which no swap can cross. Doubling the floor keeps "the smallest number that
    /// is still a bound" true for the longest route this contract can build.
    uint16 public constant MIN_IMPACT_BPS = 4;

    /// @notice Ceiling on how many position lockers `setLockers` will hold.
    /// @dev `_verifiedPool` walks them inside `convert`, so the list is a gas cost on the hot
    /// path and an unbounded one would be a way for the owner to make conversions unaffordable.
    /// Two is the most any deployment has ever needed - one live locker and one superseded one
    /// still holding older launches.
    uint256 public constant MAX_LOCKERS = 8;

    /// @notice The token bought and burnt. Immutable: a sink that could be repointed at another
    /// token is a sink whose burn is a promise again.
    IBurnableERC20 public immutable BURN_TOKEN;

    /// @notice The currency revenue arrives in and the buyback spends. wINJ in practice - the
    /// pad's curve fee always exits as wINJ, which is what makes one quote leg sufficient.
    Currency public immutable QUOTE;

    /// @notice The vault holding the buyback pool. One deployment, so it is immutable and the
    /// lock callback needs no allowlist.
    IVault public immutable VAULT;

    /// @notice The position manager every locked graduate position lives in, and the contract
    /// this sink asks for a launch's real `PoolKey`.
    /// @dev Immutable, and `setLockers` refuses a locker built against a different one - so the
    /// chain from a launch id to a pool key is fixed at construction and the owner cannot bend
    /// it by installing a locker that points somewhere else.
    ICLPositionManager public immutable POSITION_MANAGER;

    /// @notice Floor under `burnBps`, fixed at construction. THE differentiator; see the notice.
    uint16 public immutable MIN_BURN_BPS;

    /// @notice Share of bought tokens destroyed; the remainder funds infrastructure. Free to
    /// move, but never below `MIN_BURN_BPS`.
    /// @dev A floor, deliberately, and not a one-way ratchet. `SPROUT_TOKENOMICS.md` §11 argues
    /// that revenue is reflexive and that the burn share is what should flex when it falls, so
    /// the guarantee worth making is the floor rather than monotonicity.
    uint16 public burnBps;

    /// @notice Receives the non-burnt share.
    address public treasury;

    /// @notice The pool the buyback trades through. Settable because a deeper pool on another
    /// fee tier is the expected upgrade path: the launchpad's graduation pool is a full-range
    /// 1% position and is thin near spot, so the sink should be able to follow liquidity
    /// without a redeploy.
    PoolKey public buybackPool;

    /// @notice True when `QUOTE` is the pool's `currency0`, i.e. the buyback swaps 0 -> 1.
    /// Derived in `setBuybackPool` so the hot path does no comparison.
    bool public quoteIsCurrency0;

    /// @notice Minimum quote balance before a buyback runs. Below it, revenue accumulates.
    /// A swap costs the same gas whether it moves a dollar or a thousand.
    uint256 public minBuybackAmount;

    /// @notice Bound on how far one buyback may push the pool, in basis points of SQRT price.
    /// See `_priceLimit` for why sqrt, and for the (conservative) relationship to price.
    uint16 public maxImpactBps;

    /// @notice Minimum seconds between buybacks. This is the D20 answer: `harvest` is
    /// permissionless and the buyback is atomic inside it, so without a rate limit a searcher
    /// picks the moment of every buyback and sandwiches it on demand. Rate-limiting turns that
    /// into a bounded, occasional cost instead of an open invitation, and unlike a private
    /// relay it keeps the trigger permissionless.
    ///
    /// @dev `setGuards` refuses zero. The real setting is 30-60 minutes; zero is not a looser
    /// policy, it is the absence of the one guard that makes `maxImpactBps` hold - and it is
    /// the value a deploy script copied from a test fixture would carry.
    uint32 public minBuybackInterval;

    /// @notice When the last buyback ran.
    uint64 public lastBuybackAt;

    /// @notice The `PositionLocker`s a conversion may read a graduate's pool key out of.
    ///
    /// @dev **This is how the sink learns where to sell a launch token, and it asks rather than
    /// reconstructs.** `PositionLocker` holds every graduate's seed position, registered by the
    /// settler at graduation; `ICLPositionManager.getPoolAndPositionInfo(tokenId)` hands back the
    /// `PoolKey` that position is actually in. That key was fixed at that launch's graduation and
    /// no later configuration change can move it.
    ///
    /// ⛔ **What this replaces, and why.** A4 shipped `conversionTier`: a timelock-set
    /// `(poolManager, hooks, fee, parameters)` triple that the sink combined with the two
    /// currencies to DERIVE a key. It covered every launch in one setting, which is why it beat
    /// both a per-launch registration and a push from `settle` - but it was a copy of mutable
    /// settler config, and it had a failure mode that showed up the same day it shipped: a launch
    /// that graduated under an EARLIER tier stops being derivable, silently, and its revenue
    /// parks until somebody points the tier back. Testnet had exactly that - launch 14's pool is
    /// 6722 and the installed tier was 10000 - and on the same day four other copies of "which
    /// settler is current" were all found stale at once. A copy of that fact drifts; asking the
    /// chain for it cannot.
    ///
    /// 🔑 **The caller passes the launch id and it needs no trust.** `convert` verifies that the
    /// key it gets back trades exactly `{currency, QUOTE}` and refuses it otherwise, so a wrong
    /// or hostile id cannot route a swap anywhere: at worst it names a launch whose pool holds
    /// different currencies, and that is a named revert rather than a trade. The hint is a
    /// LOOKUP KEY, not a permission.
    ///
    /// 🔴 **The locker set is the one thing the owner can aim, so it is the trust anchor.** A
    /// locker answers only with pools a settler registered a position into, which is strictly
    /// narrower than the tier it replaces - that one let the owner name any hook, and a hook the
    /// owner controls is a pool the owner prices. `setLockers` still has to be treated as the
    /// sensitive call it is.
    ///
    /// ⚠️ **A set, not one address, because testnet has two locker generations and mainnet will
    /// eventually have two as well.** Locker 1.0.0 holds launches 13-17 and 1.1.0 holds
    /// everything from 19 on; both answer `getPosition` and `POSITION_MANAGER` identically, so
    /// one sink serves both. Replacing a locker is then `setLockers` rather than a sink redeploy,
    /// and the list only ever grows - adding one can never invalidate a launch already served by
    /// another. A stale list fails LOUDLY (`LaunchDoesNotTrade` on a permissionless call) where a
    /// stale tier parked silently, which is the whole difference.
    address[] internal _lockers;

    /// @notice Whether an address is one of `lockers()`. Set membership, for callers and tests.
    mapping(address locker => bool allowed) public isLocker;

    /// @notice How a quote asset that is not `QUOTE` reaches `QUOTE`. The second leg.
    ///
    /// @dev **This is the D28 edge closed, and it is a REGISTERED route rather than a derived
    /// one. That is deliberate, and it is not A4's mistake repeating.**
    ///
    /// A5's lesson was that a pool key must be PROVEN rather than guessed, and it applies to a
    /// graduation pool because `LaunchPoolGuardHook` makes those keys un-createable by anyone but
    /// an allowlisted settler: derive a key, and the only pool that can exist at it is one a
    /// settler opened. **An ordinary SAI/wINJ pool has no such hook.** Anyone may initialise a
    /// hookless pool at any key, at any price they like - so a DERIVED second leg would name a
    /// pool an attacker can create and price, and `maxImpactBps` would not save it, because the
    /// bound is measured against that pool's own spot. Deriving is not merely unavailable here;
    /// it is strictly worse than useless.
    ///
    /// Letting the CALLER pass the key fails the same way and more directly: `convert` is
    /// permissionless, so a caller-chosen pool is a caller-chosen price, and the sink would sell
    /// its SAI into a pool the caller had made. That is theft with extra steps.
    ///
    /// 🔑 **So the second leg is named by the owner - and the thing it is is `buybackPool`, not
    /// `conversionTier`.** This contract already has exactly one owner-named venue: the pool the
    /// buyback trades through, settable because "a deeper pool on another fee tier is the
    /// expected upgrade path". A quote route is the same object for the same reason. What
    /// `conversionTier` was, and what got it deleted, is a different thing: a COPY of the
    /// settler's mutable config, describing a CLASS of pools, which drifted the moment a launch
    /// graduated on another tier. A route cannot drift that way - no settler, locker or core
    /// redeploy changes which pool trades SAI against wINJ. Only liquidity moving does, which is
    /// the same maintenance `buybackPool` already carries.
    ///
    /// ⚠️ It is still config the owner can aim, and it should be read as governance. The bound
    /// on it is the currency check in `setQuoteRoute`: a route may only ever trade the asset it
    /// is registered for against `QUOTE`, so the owner chooses a VENUE, never a destination.
    mapping(Currency asset => PoolKey key) internal _quoteRoutes;

    /// @notice D32. A launch token designated to accumulate here instead of being converted.
    /// @dev Also the gate on `sweep`: what is not held is burn revenue and cannot be taken out.
    mapping(Currency currency => bool held) public isHeld;

    /// @notice When each currency was last converted. Per currency, so one launch token's
    /// conversion never spends another's window - or the buyback's.
    mapping(Currency currency => uint64 at) public lastConvertAt;

    /// @notice Below this, a currency accumulates instead of converting. Zero - the default -
    /// means no minimum, which is the right value until a token's unit price is known.
    /// @dev Per currency because `minBuybackAmount` is denominated in `QUOTE` and a launch
    /// token's units are not comparable to it, or to each other.
    mapping(Currency currency => uint256 amount) public minConvertAmount;

    /// @dev `keccak256("choice.v2.buybackburnsink.lockOpen") - 1`. Transient, and written as a
    /// literal because inline assembly cannot reference a computed constant;
    /// `test_transientSlotMatchesItsDerivation` asserts the derivation. Gates `lockAcquired` on
    /// a lock THIS contract opened rather than merely on the vault's identity.
    uint256 private constant LOCK_OPEN_SLOT = 0xbb393ca8346e746397cbb72e3dd898fcb21e70d8c1e3b5ee10773bc10d26776e;

    error ZeroAddress();
    error InvalidBps(uint16 bps);
    error BurnBpsBelowFloor(uint16 given, uint16 floor);
    error PoolMissingLeg();
    error PoolNotInitialised();
    error ImpactBpsTooLow(uint16 given, uint16 floor);
    error RateLimitRequired();
    error NotVault();
    error LockNotOpen();
    error NotSelf();
    error CannotSweepBuybackLeg(Currency currency);
    error NotAConvertibleCurrency(Currency currency);
    error SweepRequiresHold(Currency currency);
    error LaunchDoesNotTrade(uint256 launchId, Currency currency);
    error TooManyLockers(uint256 given, uint256 max);
    error DuplicateLocker(address locker);
    error LockerHasAnotherPositionManager(address locker);
    error RouteMissingLeg(Currency asset);

    /// @param quoteSpent quote actually consumed; may be less than offered if the limit bound.
    event BoughtBack(uint256 quoteOffered, uint256 quoteSpent, uint256 tokensReceived);
    /// @param burnt destroyed via `BURN_TOKEN.burn`; `toTreasury` is the ops remainder.
    event Burnt(uint256 burnt, uint256 toTreasury);
    /// @param quoteReceived what the sink now holds to buy back with; it goes on to do so.
    event Converted(Currency indexed currency, uint256 offered, uint256 spent, uint256 quoteReceived);
    /// @param reason 0 = below the minimum, 1 = inside `minBuybackInterval`, 2 = currency has no
    /// route, 3 = the swap itself reverted, 4 = the burn/treasury settle reverted, 5 = held by
    /// policy (D32), 6 = a launch token reached `burn`, which carries no launch id to look its
    /// pool up by - `convert(currency, launchId)` is what moves it. Funds stay here in every
    /// case.
    event Parked(Currency indexed currency, uint256 amount, uint8 reason);
    event BurnBpsUpdated(uint16 oldBps, uint16 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event BuybackPoolUpdated(PoolKey key, bool quoteIsCurrency0);
    event GuardsUpdated(uint256 minBuybackAmount, uint16 maxImpactBps, uint32 minBuybackInterval);
    event LockersUpdated(address[] lockers);
    /// @param key the pool the asset reaches `QUOTE` through; a zero `poolManager` clears it.
    event QuoteRouteUpdated(Currency indexed asset, PoolKey key, bool assetIsCurrency0);
    event HoldUpdated(Currency indexed currency, bool held);
    event MinConvertAmountUpdated(Currency indexed currency, uint256 amount);
    event TokenSwept(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice A resolved conversion path: one or two exact-input swaps ending in `QUOTE`.
    /// @dev Fixed-size rather than an array, because this contract builds at most two legs and a
    /// bounded shape is one less thing a lock callback can be handed too much of.
    struct Route {
        PoolKey first;
        bool firstZeroForOne;
        PoolKey second;
        bool secondZeroForOne;
        /// @dev 0 = no route, 1 = straight to `QUOTE`, 2 = through a registered quote route.
        uint8 legs;
    }

    uint8 private constant PARK_BELOW_MINIMUM = 0;
    uint8 private constant PARK_RATE_LIMITED = 1;
    uint8 private constant PARK_NO_ROUTE = 2;
    uint8 private constant PARK_SWAP_FAILED = 3;
    uint8 private constant PARK_SETTLE_FAILED = 4;
    uint8 private constant PARK_HELD = 5;
    uint8 private constant PARK_NEEDS_HINT = 6;

    constructor(
        IBurnableERC20 _burnToken,
        Currency _quote,
        IVault _vault,
        ICLPositionManager _positionManager,
        address _treasury,
        address _owner,
        uint16 _minBurnBps,
        uint16 _burnBps
    ) Ownable(_owner) {
        if (
            address(_burnToken) == address(0) || Currency.unwrap(_quote) == address(0) || address(_vault) == address(0)
                || address(_positionManager) == address(0) || _treasury == address(0) || _owner == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_minBurnBps > BPS_DENOMINATOR) revert InvalidBps(_minBurnBps);
        if (_burnBps > BPS_DENOMINATOR) revert InvalidBps(_burnBps);
        if (_burnBps < _minBurnBps) revert BurnBpsBelowFloor(_burnBps, _minBurnBps);

        BURN_TOKEN = _burnToken;
        QUOTE = _quote;
        VAULT = _vault;
        POSITION_MANAGER = _positionManager;
        MIN_BURN_BPS = _minBurnBps;
        burnBps = _burnBps;
        treasury = _treasury;
    }

    // -------------------------------------------------------------------------------------
    // IBurnSink
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IBurnSink
    /// @dev The `amount` argument is ignored and the balance is used instead, exactly as
    /// `DirectTransferBurnSink` does: a transfer that arrived without a matching `burn` call
    /// must not be strandable, and a fee-on-transfer currency delivers less than the caller
    /// says it does.
    ///
    /// Permissionless, because the destinations are fixed at construction. A caller chooses
    /// only WHEN the burn happens, and pays the gas.
    function burn(Currency currency, uint256) external nonReentrant {
        if (Currency.unwrap(currency) == address(BURN_TOKEN)) {
            _settleBurnToken();
        } else if (currency == QUOTE) {
            _tryBuyback();
        } else if (isHeld[currency]) {
            // D32 first, so a held token reports the POLICY rather than the condition below it.
            emit Parked(currency, currency.balanceOfSelf(), PARK_HELD);
        } else if (address(_quoteRoutes[currency].poolManager) != address(0)) {
            // 🔑 A REGISTERED QUOTE ASSET needs no hint, because the route IS the lookup.
            //
            // This arm exists because a graduate's fees arrive in BOTH of its pool's currencies:
            // a SAI-paired launch pays the launchpad part launch-token and part SAI, and the SAI
            // half is not a launch token at all - no launch id would resolve it, and before the
            // routes it parked here for ever with reason 6. Now it is one swap to `QUOTE` and on
            // into the buyback, on a permissionless call with nothing passed in.
            Route memory r;
            (r.first, r.firstZeroForOne) = _routeFor(currency);
            r.legs = 1;
            _tryConvert(currency, r);
        } else {
            // A launch token. It PARKS here, and that is a deliberate consequence of A5.
            //
            // `IBurnSink.burn` takes a currency and an amount, and a currency does not say which
            // launch it came from - so this frame cannot look the launch's pool up. A4's answer
            // was to DERIVE a key from a stored tier, which worked until a launch graduated on a
            // different tier; the tier is gone and `convert(currency, launchId)` replaces it.
            //
            // 🔑 Nothing is lost operationally, because under D30 this arm was already the wrong
            // door. No `ChoiceFeeController` points at this sink, so nothing calls `burn`
            // automatically at all; a graduate's launch-token revenue arrives as a bare transfer
            // from `PositionLocker.claim`, which never calls anything. `LaunchFeeCranker` is what
            // turns that into a burn, and it passes the launch id.
            //
            // The park is reported with its own reason so a dashboard can tell "somebody has to
            // pass a launch id" apart from "this currency has no pool anywhere". And it is NEVER
            // forwarded to the treasury: the ops wallet taking 100% of a currency the burn was
            // entitled to `burnBps` of would be a silent policy change.
            emit Parked(currency, currency.balanceOfSelf(), PARK_NEEDS_HINT);
        }
    }

    /// @notice Run a buyback now if the guards allow, without waiting for a harvest.
    /// @dev For keepers, and for draining a balance parked by an earlier guard.
    function buyback() external nonReentrant {
        _tryBuyback();
    }

    /// @notice Convert a parked launch token to `QUOTE` now, and buy back with the proceeds.
    /// @param currency The launch token to sell. Neither leg of the buyback is accepted.
    /// @param launchId The launch it came from, used to look up that launch's own graduation
    /// pool. A HINT: it is verified, not trusted - see below.
    ///
    /// @dev The counterpart to `buyback()` for the normalise leg, and the ONLY way a launch token
    /// moves. Revenue reaches this contract WITHOUT a `burn` call - `PositionLocker.claim` pays
    /// the launchpad's LP-fee share straight here and notifies nobody - so something has to come
    /// and ask. `LaunchFeeCranker` is that something; a keeper or a human calling this directly
    /// is the same thing by hand.
    ///
    /// Permissionless, like everything else in this contract that only chooses WHEN: the pool
    /// comes off the chain, the bound is `maxImpactBps`, and the proceeds can only become `QUOTE`
    /// in this contract and then SPROUT that is burnt.
    ///
    /// 🔑 **Why the launch id needs no trust.** It selects a locked position; the position selects
    /// a `PoolKey`; and that key is then REQUIRED to trade exactly `{currency, QUOTE}`. A caller
    /// who names the wrong launch names a pool holding other currencies and gets
    /// `LaunchDoesNotTrade` - there is no id that routes this swap through a pool of the caller's
    /// choosing, because the caller does not choose the pool, the settler did at graduation.
    ///
    /// ⚠️ A launch that graduated against a quote asset OTHER than `QUOTE` is refused here rather
    /// than parked: its pool trades `{launchToken, thatAsset}` and this sink has no second leg to
    /// get from `thatAsset` to `QUOTE`. That is D28's open edge, not a regression - the derived
    /// tier could not reach those launches either, it just failed quietly instead.
    ///
    /// Unlike `burn`, this one is allowed to revert. It is not on the harvest path, and a named
    /// error says what is wrong while somebody is looking at it.
    function convert(Currency currency, uint256 launchId) external nonReentrant {
        if (Currency.unwrap(currency) == address(BURN_TOKEN) || currency == QUOTE) {
            revert NotAConvertibleCurrency(currency);
        }
        // Argument validation before state: a caller with a bad hint is told so even when the
        // tranche would have parked for an unrelated reason.
        Route memory route = _resolveRoute(currency, launchId);
        if (route.legs == 0) revert LaunchDoesNotTrade(launchId, currency);
        _tryConvert(currency, route);
    }

    // -------------------------------------------------------------------------------------
    // Buyback
    // -------------------------------------------------------------------------------------

    function _tryBuyback() private {
        uint256 amountIn = QUOTE.balanceOfSelf();
        if (amountIn < minBuybackAmount || amountIn == 0) {
            emit Parked(QUOTE, amountIn, PARK_BELOW_MINIMUM);
            return;
        }
        // `lastBuybackAt == 0` means NEVER RUN, not "ran at the epoch". Without the first
        // clause a fresh deployment refuses its own first buyback whenever the chain's
        // timestamp is below `minBuybackInterval` - which production never is, but resting the
        // gate on "unix time is a big number" is an assumption, not a guarantee.
        if (lastBuybackAt != 0 && block.timestamp < uint256(lastBuybackAt) + minBuybackInterval) {
            emit Parked(QUOTE, amountIn, PARK_RATE_LIMITED);
            return;
        }
        // A pool that was never configured has a zero `poolManager`, which would revert inside
        // the lock. Park instead, so an unconfigured sink still cannot brick a harvest.
        if (address(buybackPool.poolManager) == address(0)) {
            emit Parked(QUOTE, amountIn, PARK_NO_ROUTE);
            return;
        }

        uint256 tokensBefore = IERC20(address(BURN_TOKEN)).balanceOf(address(this));

        // The one gate that cannot be enumerated. Everything reachable from inside the lock -
        // the pool manager's `whenNotPaused`, the pool's own price-limit validation, a hook,
        // the vault refusing a nested lock because `harvest` was called from inside somebody
        // else's - reverts the sub-call and lands here instead of unwinding the harvest.
        bool swapped;
        _setLockOpen(true);
        Route memory route;
        route.first = buybackPool;
        route.firstZeroForOne = quoteIsCurrency0;
        route.legs = 1;
        try VAULT.lock(abi.encode(route, amountIn)) returns (bytes memory) {
            swapped = true;
        } catch {
            swapped = false;
        }
        // Unconditional, and NOT inside the `try`. `tstore` reverts with the frame that wrote
        // it, and this one was written in THIS frame - the revert being caught belongs to the
        // sub-call. Clearing it only on the success path would leave `lockAcquired` open to
        // the vault for the rest of the transaction after a failed buyback.
        _setLockOpen(false);

        if (!swapped) {
            emit Parked(QUOTE, amountIn, PARK_SWAP_FAILED);
            return;
        }

        // Only now, so a transient failure - a paused pool manager, a bad tier - does not also
        // spend the rate-limit window and push the next real buyback out by a full interval.
        // Safe to write after the call because `burn` and `buyback` are the only ways in and
        // both are `nonReentrant`.
        lastBuybackAt = uint64(block.timestamp);

        uint256 received = IERC20(address(BURN_TOKEN)).balanceOf(address(this)) - tokensBefore;
        uint256 spent = amountIn - QUOTE.balanceOfSelf();
        emit BoughtBack(amountIn, spent, received);

        _settleBurnToken();
    }

    // -------------------------------------------------------------------------------------
    // Normalise
    // -------------------------------------------------------------------------------------

    /// @dev Sell a launch token for `QUOTE` against its own graduation pool, then buy back.
    ///
    /// Every branch below parks rather than reverting, and that survives A5 even though the only
    /// caller is now allowed to revert: `convert` raises its named errors BEFORE this frame, on
    /// the arguments, and everything from here on is a condition rather than a mistake. A held
    /// token, a tranche under its minimum and a swap the pool refuses are all states a later call
    /// picks up, so none of them should cost the caller their transaction.
    ///
    /// 🔑 The key is the launch's REAL one, read off its locked position - see `_lockers`. It is
    /// passed in rather than looked up here so that `convert` can verify it first.
    ///
    /// 🔑 Infinity skips a pool's hooks when the hook itself is the caller, so a conversion
    /// through a pool with a fee hook on it would not be taxed by that hook - the sink is not the
    /// hook here, but the graduation pool's guard hook registers `beforeInitialize` and nothing
    /// else, so there is no swap-time hook on this path at all.
    function _tryConvert(Currency currency, Route memory route) private {
        uint256 amountIn = currency.balanceOfSelf();

        // D32 first, so a held token reports the POLICY rather than whichever guard it happens
        // to trip. Held is a decision somebody made; the rest are conditions.
        if (isHeld[currency]) {
            emit Parked(currency, amountIn, PARK_HELD);
            return;
        }
        if (amountIn == 0 || amountIn < minConvertAmount[currency]) {
            emit Parked(currency, amountIn, PARK_BELOW_MINIMUM);
            return;
        }
        // The same D20 answer as the buyback, and the same window: a conversion is a
        // price-sensitive trade whose moment a permissionless caller chooses, so it is
        // rate-limited per currency. Per currency rather than globally, or one launch token's
        // conversion would block every other launch token AND the buyback for a full window.
        uint64 last = lastConvertAt[currency];
        if (last != 0 && block.timestamp < uint256(last) + minBuybackInterval) {
            emit Parked(currency, amountIn, PARK_RATE_LIMITED);
            return;
        }

        uint256 quoteBefore = QUOTE.balanceOfSelf();

        // Everything about the pool that is not its identity - whether it holds liquidity,
        // whether the manager is paused, whether the price bound is crossable - is left to this
        // `try/catch` deliberately. `getSlot0` on an address with no code answers with empty
        // returndata, so a pre-flight existence check is itself a way to revert.
        bool swapped;
        _setLockOpen(true);
        try VAULT.lock(abi.encode(route, amountIn)) returns (bytes memory) {
            swapped = true;
        } catch {
            swapped = false;
        }
        // Unconditional and outside the `try`, for the reason `_tryBuyback` gives.
        _setLockOpen(false);

        if (!swapped) {
            emit Parked(currency, amountIn, PARK_SWAP_FAILED);
            return;
        }

        // After the call, so a transient failure does not spend this currency's window.
        lastConvertAt[currency] = uint64(block.timestamp);

        uint256 spent = amountIn - currency.balanceOfSelf();
        uint256 received = QUOTE.balanceOfSelf() - quoteBefore;
        emit Converted(currency, amountIn, spent, received);

        // The conversion exists to feed the buyback, so it runs on rather than waiting for
        // somebody to call `buyback()`. It parks harmlessly if its own guards say no - and a
        // conversion that filled only partially against `maxImpactBps` leaves the rest here,
        // which is what the next window picks up.
        _tryBuyback();
    }

    /// @dev The whole path from `currency` to `QUOTE`, or `legs == 0` if there is none.
    ///
    /// Three answers, tried in this order, and the ORDER is the safety property:
    ///
    /// 1. **The launch's own graduation pool trades `{currency, QUOTE}`** - one leg, exactly as
    ///    before A2. The anchored case: the pool was chosen by the settler at graduation and the
    ///    locker remembers it, so nobody chose it here.
    /// 2. **The launch's pool trades `{currency, X}` and `X` has a registered route to `QUOTE`**
    ///    - two legs. The first is still the anchored graduation pool; only the LAST hop is
    ///    owner-named, and it is named per quote asset rather than per launch.
    /// 3. **`currency` itself has a registered route** - one leg. This is the SAI half of a
    ///    SAI-paired launch's fee, which is not a launch token and which no hint can resolve.
    ///
    /// 🔑 Trying the launch's own pool FIRST means a registered route can never displace the
    /// anchored path for a currency that has one. And it is why a launch's PAIR asset does not
    /// accidentally get sold into the launch's own pool: `currency == SAI` matches the pool at
    /// step 1, but the other side is the launch token, which is not `QUOTE` and has no route -
    /// so step 1 declines, and step 3 sells it through the route the owner registered instead.
    function _resolveRoute(Currency currency, uint256 launchId) internal view returns (Route memory route) {
        (PoolKey memory launchKey, bool zeroForOne, bool found) = _launchPoolFor(currency, launchId);
        if (found) {
            Currency other = zeroForOne ? launchKey.currency1 : launchKey.currency0;
            if (other == QUOTE) {
                route.first = launchKey;
                route.firstZeroForOne = zeroForOne;
                route.legs = 1;
                return route;
            }
            PoolKey memory hop = _quoteRoutes[other];
            if (address(hop.poolManager) != address(0)) {
                route.first = launchKey;
                route.firstZeroForOne = zeroForOne;
                (route.second, route.secondZeroForOne) = _routeFor(other);
                route.legs = 2;
                return route;
            }
        }

        if (address(_quoteRoutes[currency].poolManager) != address(0)) {
            (route.first, route.firstZeroForOne) = _routeFor(currency);
            route.legs = 1;
        }
    }

    /// @dev The registered hop for `asset`, and which way round it sells. Assumes it exists.
    function _routeFor(Currency asset) private view returns (PoolKey memory key, bool zeroForOne) {
        key = _quoteRoutes[asset];
        zeroForOne = key.currency0 == asset;
    }

    /// @dev The launch's own graduation pool, read off its locked position and then CHECKED.
    ///
    /// Two lookups and one assertion:
    ///
    /// 1. each locker in turn, until one has a position registered for `launchId`;
    /// 2. the position manager, for the `PoolKey` that position is in - authoritative, because it
    ///    is where the position actually sits and it was fixed at graduation;
    /// 3. the key must hold `currency` on one of its two sides.
    ///
    /// Step 3 is what makes step 1's argument safe to accept from anybody. A caller who names the
    /// wrong launch names a pool that does not hold the currency being sold, and gets nothing.
    /// **No launch id routes a swap through a pool the caller chose**, because the caller does
    /// not choose the pool - the settler did, at graduation, and the locker remembers.
    ///
    /// ⚠️ It used to require the OTHER side to be `QUOTE` as well. That check moved up into
    /// `_resolveRoute`, which now decides between "this pool finishes the job" and "this pool is
    /// the first of two legs". The safety property is unchanged: what bounded a caller's power
    /// was always the currency being SOLD matching, and the destination is bounded separately -
    /// by `QUOTE` being immutable, and by `setQuoteRoute` refusing a hop that does not end there.
    ///
    /// @return key The launch's real pool key; zero when nothing matched.
    /// @return zeroForOne True when `currency` is that pool's `currency0`, i.e. selling 0 -> 1.
    /// @return found False when no locker knows the launch, or when the pool it names does not
    /// hold this currency at all.
    function _launchPoolFor(Currency currency, uint256 launchId)
        private
        view
        returns (PoolKey memory key, bool zeroForOne, bool found)
    {
        address[] memory set = _lockers;
        for (uint256 i; i < set.length; ++i) {
            uint256 tokenId = ILaunchPositionLocker(set[i]).getPosition(launchId).tokenId;
            if (tokenId == 0) continue;

            (PoolKey memory held,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
            if (held.currency0 == currency) return (held, true, true);
            if (held.currency1 == currency) return (held, false, true);
        }
    }

    // -------------------------------------------------------------------------------------
    // The swap both legs share
    // -------------------------------------------------------------------------------------

    /// @inheritdoc ILockCallback
    /// @dev Gated on a lock this contract opened, not merely on the vault's identity. The vault
    /// is immutable here so `msg.sender` alone is nearly sufficient, but "nearly" is not a
    /// property worth resting a swap on - the same reasoning as `ChoiceRouter.lockAcquired`.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault();
        if (!_lockOpen()) revert LockNotOpen();

        // The ROUTE travels with the call. Every path this contract opens - a buyback, a
        // one-leg conversion, a two-leg conversion through a registered quote route - is the
        // same shape, so they share one callback rather than one each.
        (Route memory route, uint256 amountIn) = abi.decode(data, (Route, uint256));

        // 🔑 ONE COMPOSITE BOUND, split across the legs, rather than one bound per leg.
        //
        // `maxImpactBps` is the operator's answer to "how far may a conversion push prices",
        // and that number has to keep ONE meaning however long the route is. Giving each leg
        // the full setting would silently let a two-leg conversion move twice as far as a
        // one-leg one at the same setting - "a per-leg bound on a two-leg route is not the same
        // protection". So the allowance is divided: a one-leg route is bounded exactly as it
        // was before routes existed, and a two-leg route's two bounds sum to the same total.
        //
        // ⚠️ It is a bound on IMPACT, not on realised price: the swap fee sits on top of it on
        // every leg, so a two-leg conversion pays two pools' fees. That is a cost of the route,
        // not something a price limit can express, and `minConvertAmount` is the lever for it.
        uint16 perLeg = maxImpactBps / route.legs;

        uint256 amount = amountIn;
        for (uint8 i; i < route.legs; ++i) {
            PoolKey memory key = i == 0 ? route.first : route.second;
            bool zeroForOne = i == 0 ? route.firstZeroForOne : route.secondZeroForOne;

            // Read inside the lock rather than passed in, so a `getSlot0` that reverts - an
            // uninitialised pool reached despite `setBuybackPool`'s check, or a route pool that
            // has since been closed - is caught by the caller's `try/catch` along with
            // everything else, instead of escaping it.
            ICLPoolManager(address(key.poolManager))
                .swap(
                    key,
                    ICLPoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        // Negative is exact-input. The pool consumes up to this much and stops
                        // at the limit, so a partial fill is the expected outcome, not an error.
                        amountSpecified: -amount.toInt256(),
                        sqrtPriceLimitX96: _priceLimit(key, zeroForOne, perLeg)
                    }),
                    ""
                );

            if (i + 1 == route.legs) break;

            // What the first leg produced, read off the vault's own ledger rather than the
            // swap's return value: the delta is what the second leg can actually spend, and it
            // absorbs anything a hook adjusted on the way. A leg that filled nothing leaves
            // zero here and the route stops - the input stays owed and is settled below, so a
            // dead second pool costs the tranche nothing but the gas.
            Currency out = zeroForOne ? key.currency1 : key.currency0;
            int256 credit = VAULT.currencyDelta(address(this), out);
            if (credit <= 0) break;
            // forge-lint: disable-next-line(unsafe-typecast) - guarded positive above.
            amount = uint256(credit);
        }

        // Debts before credits: the vault pays a credit out of real reserves, so taking first
        // can fail on a vault that is exactly funded. Same ordering as `ChoiceRouter`.
        //
        // Across BOTH legs, and the intermediate is the interesting one: leg 1 credits it and
        // leg 2 owes it, so a route that consumed everything nets to zero here and neither call
        // does anything. A second leg that filled only PARTIALLY leaves a positive remainder,
        // which `_takeDelta` brings into this contract as a real balance - where the registered
        // route makes it convertible again on the next call, rather than stranding it.
        _settleDelta(route.first.currency0);
        _settleDelta(route.first.currency1);
        if (route.legs > 1) {
            _settleDelta(route.second.currency0);
            _settleDelta(route.second.currency1);
        }
        _takeDelta(route.first.currency0);
        _takeDelta(route.first.currency1);
        if (route.legs > 1) {
            _takeDelta(route.second.currency0);
            _takeDelta(route.second.currency1);
        }
        return "";
    }

    function _settleDelta(Currency currency) private {
        int256 delta = VAULT.currencyDelta(address(this), currency);
        if (delta >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a known negative.
        uint256 owed = uint256(-delta);
        VAULT.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(VAULT), owed);
        VAULT.settle();
    }

    function _takeDelta(Currency currency) private {
        int256 delta = VAULT.currencyDelta(address(this), currency);
        if (delta <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast) - guarded positive above.
        VAULT.take(currency, address(this), uint256(delta));
    }

    /// @dev The impact guard, expressed as the price the swap may walk to and no further.
    ///
    /// `maxImpactBps` bounds the **sqrt** price, because that is what the pool takes. The
    /// realised bound on PRICE is `b - b²/4`, i.e. very slightly TIGHTER than `b` - the guard
    /// stops marginally earlier than its nominal setting, which is the right direction for a
    /// safety rail.
    ///
    /// ⚠️ Two things this does NOT bound. It is measured against the pool's raw spot price, so
    /// the **swap fee is on top** - on the launchpad's 1% graduation tier the effective cost of
    /// a buyback is roughly `1% + maxImpactBps`. And spot is whatever the pool says right now,
    /// so a pool already pushed off-market by an attacker moves the reference with it; the rate
    /// limit, not this, is what makes that unprofitable to farm.
    ///
    /// One setting serves every path, and `lockAcquired` divides it by the number of legs before
    /// calling this - so `bps` here is this leg's SHARE of the conversion's total allowance, not
    /// `maxImpactBps` itself. A conversion sells into a graduate's own pool, which is thinner
    /// than SPROUT/wINJ rather than deeper, so a setting sized for the buyback is if anything
    /// conservative there - and a leg that hits its bound fills PARTIALLY and leaves the rest
    /// for the next window, exactly as an oversized buyback does.
    function _priceLimit(PoolKey memory key, bool zeroForOne, uint16 bps) private view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = ICLPoolManager(address(key.poolManager)).getSlot0(key.toId());
        uint256 halfImpact = uint256(bps) / 2;
        if (zeroForOne) {
            // 0 -> 1 walks the price DOWN.
            return FullMath.mulDiv(sqrtPriceX96, BPS_DENOMINATOR - halfImpact, BPS_DENOMINATOR).toUint160();
        }
        return FullMath.mulDiv(sqrtPriceX96, BPS_DENOMINATOR + halfImpact, BPS_DENOMINATOR).toUint160();
    }

    // -------------------------------------------------------------------------------------
    // Burn
    // -------------------------------------------------------------------------------------

    /// @dev The last thing inside the never-revert perimeter, and the one gate that was outside
    /// it. Both call sites - `burn` when the harvested currency IS the burn token, and
    /// `_tryBuyback` after a swap that already succeeded - sit under
    /// `ChoiceFeeController.harvest`, so a revert raised here bricks harvesting exactly as a
    /// reverting swap would. The second site is the worse of the two: the buyback has landed and
    /// `lastBuybackAt` is written by then, so propagating would unwind a good swap rather than
    /// merely refusing a settle.
    ///
    /// Neither leg is unfailable. `BURN_TOKEN.burn` and the treasury transfer both route through
    /// the bank precompile on a `MintBurnBankERC20`, and `treasury` is owner-settable to any
    /// address - a module account among them.
    ///
    /// ⛔ Wrapping the two legs in SEPARATE `try/catch`es is the obvious fix and it is wrong. A
    /// burn that succeeds beside a transfer that fails leaves only the treasury's share sitting
    /// here, and the next call - which acts on the BALANCE, as everything in this contract does -
    /// would apply `burnBps` to that remainder and burn 80% of the ops share. The split has to be
    /// all-or-nothing, so the whole settle goes through ONE external self-call: either both legs
    /// land or the balance is untouched and parks intact for a later attempt.
    function _settleBurnToken() private {
        uint256 balance = IERC20(address(BURN_TOKEN)).balanceOf(address(this));
        if (balance == 0) return;

        // Settled on the success path, where `Burnt` is emitted from inside the call.
        try this.settleBurnTokenSelf() {}
        catch {
            emit Parked(Currency.wrap(address(BURN_TOKEN)), balance, PARK_SETTLE_FAILED);
        }
    }

    /// @notice The burn/treasury split, as an external function so it can be caught.
    /// @dev Solidity cannot `try` a revert raised in its own frame, so the atomicity argued for
    /// above needs a real external call. Callable by this contract ONLY - it moves the burn
    /// token and would otherwise be a permissionless way to force the split at a chosen moment.
    ///
    /// Deliberately NOT `nonReentrant`: it is reached from inside `burn`/`buyback`, both of
    /// which hold the guard, so carrying the modifier here would make every settle revert into
    /// the `catch` above and park the balance forever.
    ///
    /// The treasury gets the remainder rather than a second multiplication, so integer division
    /// cannot strand dust here on every call.
    function settleBurnTokenSelf() external {
        if (msg.sender != address(this)) revert NotSelf();

        uint256 balance = IERC20(address(BURN_TOKEN)).balanceOf(address(this));
        if (balance == 0) return;

        uint256 toBurn = balance * burnBps / BPS_DENOMINATOR;
        uint256 toTreasury = balance - toBurn;

        if (toBurn > 0) BURN_TOKEN.burn(toBurn);
        if (toTreasury > 0) IERC20(address(BURN_TOKEN)).safeTransfer(treasury, toTreasury);

        emit Burnt(toBurn, toTreasury);
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    /// @notice Quote revenue waiting to be spent.
    function pendingQuote() external view returns (uint256) {
        return QUOTE.balanceOfSelf();
    }

    /// @notice Whether a `buyback()` right now would actually trade.
    /// @dev For keepers and dashboards deciding whether a call is worth its gas.
    function canBuyback() external view returns (bool) {
        uint256 amountIn = QUOTE.balanceOfSelf();
        return amountIn > 0 && amountIn >= minBuybackAmount
            && (lastBuybackAt == 0 || block.timestamp >= uint256(lastBuybackAt) + minBuybackInterval)
            && address(buybackPool.poolManager) != address(0);
    }

    /// @notice Whether a `convert(currency, launchId)` right now would actually trade.
    /// @dev For keepers and dashboards deciding whether a call is worth its gas. It answers false
    /// for a held currency, which is the point: holding is meant to be visible from outside, not
    /// inferred from nothing happening. It also answers false for a hint that would revert, so a
    /// caller can tell a bad launch id from an empty balance without spending a transaction.
    /// @notice The registered second leg for a quote asset, if it has one.
    /// @return key The pool; zero when nothing is registered.
    /// @return assetIsCurrency0 True when `asset` is that pool's `currency0`.
    /// @return found Whether a route exists at all.
    function quoteRoute(Currency asset) external view returns (PoolKey memory key, bool assetIsCurrency0, bool found) {
        key = _quoteRoutes[asset];
        found = address(key.poolManager) != address(0);
        assetIsCurrency0 = found && key.currency0 == asset;
    }

    function canConvert(Currency currency, uint256 launchId) external view returns (bool) {
        if (Currency.unwrap(currency) == address(BURN_TOKEN) || currency == QUOTE) return false;
        if (isHeld[currency]) return false;
        if (_resolveRoute(currency, launchId).legs == 0) return false;
        uint256 amountIn = currency.balanceOfSelf();
        uint64 last = lastConvertAt[currency];
        return amountIn > 0 && amountIn >= minConvertAmount[currency]
            && (last == 0 || block.timestamp >= uint256(last) + minBuybackInterval);
    }

    /// @notice The pool a launch token would convert through, and the direction it would sell.
    /// @dev The same lookup `convert` makes, exposed so a deploy or a dashboard can see the key
    /// rather than infer it from a swap that did or did not happen. A zero `poolManager` means
    /// the hint does not resolve - either no locker knows the launch, or its pool does not trade
    /// this currency against `QUOTE`.
    function conversionRoute(Currency currency, uint256 launchId) external view returns (Route memory) {
        return _resolveRoute(currency, launchId);
    }

    /// @notice A launch's real graduation pool key, whatever currencies it holds.
    /// @dev Unfiltered, unlike `conversionPool`: this one answers for a launch paired against
    /// something other than `QUOTE`, and for the burn token's own launch. That last case is the
    /// point - `setBuybackPool` needs SPROUT's own graduation key, and reading it off SPROUT's
    /// locked position is how a deploy script gets it without a human retyping a tier.
    /// @return key Zero when no locker in the set knows this launch.
    /// @return locker Which locker answered, or the zero address.
    function launchPool(uint256 launchId) external view returns (PoolKey memory key, address locker) {
        address[] memory set = _lockers;
        for (uint256 i; i < set.length; ++i) {
            uint256 tokenId = ILaunchPositionLocker(set[i]).getPosition(launchId).tokenId;
            if (tokenId == 0) continue;
            (key,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
            return (key, set[i]);
        }
    }

    /// @notice The position lockers a conversion may read a graduate's pool out of.
    function lockers() external view returns (address[] memory) {
        return _lockers;
    }

    // -------------------------------------------------------------------------------------
    // Owner
    // -------------------------------------------------------------------------------------

    /// @notice Raise the burn share. It can never be lowered past `MIN_BURN_BPS`.
    function setBurnBps(uint16 newBurnBps) external onlyOwner {
        if (newBurnBps > BPS_DENOMINATOR) revert InvalidBps(newBurnBps);
        if (newBurnBps < MIN_BURN_BPS) revert BurnBpsBelowFloor(newBurnBps, MIN_BURN_BPS);
        emit BurnBpsUpdated(burnBps, newBurnBps);
        burnBps = newBurnBps;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Point the buyback at a pool.
    /// @dev Both legs are checked, so a key that does not actually trade the pair cannot be
    /// installed - a misconfiguration here would otherwise park revenue silently forever.
    function setBuybackPool(PoolKey calldata key) external onlyOwner {
        address burnToken = address(BURN_TOKEN);
        address quote = Currency.unwrap(QUOTE);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (address(key.poolManager) == address(0)) revert ZeroAddress();
        bool quoteFirst = c0 == quote && c1 == burnToken;
        bool burnFirst = c0 == burnToken && c1 == quote;
        if (!quoteFirst && !burnFirst) revert PoolMissingLeg();

        // Both legs being right does not make the pool exist. A key on a tier nobody has
        // opened installs cleanly and then parks every tranche for as long as nobody notices,
        // so it is refused here where the error names the cause. Doubles as a check that
        // `poolManager` is a CL manager at all - this sink swaps through `ICLPoolManager`.
        (uint160 sqrtPriceX96,,,) = ICLPoolManager(address(key.poolManager)).getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialised();

        buybackPool = key;
        quoteIsCurrency0 = quoteFirst;
        emit BuybackPoolUpdated(key, quoteFirst);
    }

    /// @notice Set the three guards that decide when a buyback runs and how far it may push.
    function setGuards(uint256 newMinBuybackAmount, uint16 newMaxImpactBps, uint32 newMinBuybackInterval)
        external
        onlyOwner
    {
        // Half of BPS, because `_priceLimit` halves it and a limit at or past zero is not a
        // price. Well above anything sane; the real setting is in the hundreds.
        if (newMaxImpactBps >= BPS_DENOMINATOR) revert InvalidBps(newMaxImpactBps);
        // And below the floor it is not a bound at all - it truncates to the pool's own price,
        // which no swap can cross. See `MIN_IMPACT_BPS`.
        if (newMaxImpactBps < MIN_IMPACT_BPS) revert ImpactBpsTooLow(newMaxImpactBps, MIN_IMPACT_BPS);
        // D20: without this, `maxImpactBps` bounds one buyback and nothing bounds how many a
        // searcher can trigger. Zero is the absence of the policy, not a loose version of it.
        if (newMinBuybackInterval == 0) revert RateLimitRequired();
        minBuybackAmount = newMinBuybackAmount;
        maxImpactBps = newMaxImpactBps;
        minBuybackInterval = newMinBuybackInterval;
        emit GuardsUpdated(newMinBuybackAmount, newMaxImpactBps, newMinBuybackInterval);
    }

    /// @notice Set the position lockers a conversion may read a graduate's pool key out of.
    ///
    /// @dev The whole list every time, rather than add/remove: the timelock states the complete
    /// intended set, one event carries it, and there is no index arithmetic to get wrong. It is
    /// idempotent and the natural shape for a governance call somebody has to read before
    /// signing.
    ///
    /// 🔴 **This is the sensitive setter on this contract.** A locker is what turns a caller's
    /// launch id into a pool, so a hostile one could hand back a pool it had priced - the
    /// currency check in `_verifiedPool` bounds WHICH pair, not whose pool. That is not a new
    /// power: `setConversionTier`, which this replaces, let the owner name any hook, and a hook
    /// the owner controls is the same thing with more steps. It is narrower, and it should still
    /// be read as governance rather than housekeeping.
    ///
    /// Three checks, each of which has a failure it is there for:
    ///
    /// - **`POSITION_MANAGER()` must match.** It proves the candidate speaks the locker ABI at
    ///   all - a contract without that function reverts here rather than silently answering
    ///   `getPosition` with garbage later - and it pins the second half of the lookup chain, so
    ///   an installed locker cannot redirect the key read to a manager of its own.
    /// - **No duplicates**, or one locker would be walked twice on every miss.
    /// - **A bounded length**, because `_verifiedPool` walks the list inside `convert`. The cap
    ///   is far above the two generations any deployment has ever had.
    function setLockers(address[] calldata newLockers) external onlyOwner {
        if (newLockers.length > MAX_LOCKERS) revert TooManyLockers(newLockers.length, MAX_LOCKERS);

        address[] memory previous = _lockers;
        for (uint256 i; i < previous.length; ++i) {
            isLocker[previous[i]] = false;
        }

        for (uint256 i; i < newLockers.length; ++i) {
            address locker = newLockers[i];
            if (locker == address(0)) revert ZeroAddress();
            if (isLocker[locker]) revert DuplicateLocker(locker);
            if (ILaunchPositionLocker(locker).POSITION_MANAGER() != POSITION_MANAGER) {
                revert LockerHasAnotherPositionManager(locker);
            }
            isLocker[locker] = true;
        }

        _lockers = newLockers;
        emit LockersUpdated(newLockers);
    }

    /// @notice Register the pool a quote asset reaches `QUOTE` through - the second leg.
    ///
    /// @param asset The quote asset a launch may be paired against. Neither leg of the buyback
    /// is accepted: `QUOTE` is already the destination and the burn token has its own path.
    /// @param key The pool. A zero `poolManager` CLEARS the route, which is the only way to
    /// remove one - so retiring a venue is an explicit call that emits, never an omission.
    ///
    /// @dev 🔑 **Why this is registered and not derived.** A5 proved a graduation pool's key
    /// rather than guessing it, and that works there because `LaunchPoolGuardHook` makes such a
    /// key un-createable by anyone but an allowlisted settler. An ordinary SAI/wINJ pool has no
    /// hook: anyone may open a hookless pool at any key, at any price. A derived second leg
    /// would therefore name a pool an ATTACKER can create and price, and `maxImpactBps` would
    /// not help, because it is measured against that pool's own spot. Deriving is not merely
    /// unavailable here - it is worse than useless. Letting the permissionless caller pass a key
    /// is the same hole with fewer steps.
    ///
    /// 🔑 **And it is the same object as `buybackPool`, not a return of `conversionTier`.** This
    /// contract has always had one owner-named venue, for the same reason: liquidity moves and
    /// the sink should follow it without a redeploy. `conversionTier` was different in kind - a
    /// COPY of the settler's mutable config, describing a class of pools rather than naming one,
    /// which went stale the moment a launch graduated on another tier. Nothing else in this
    /// system decides which pool trades SAI against wINJ, so there is nothing for this to drift
    /// from.
    ///
    /// The two checks are what keep it a choice of VENUE rather than of destination:
    ///
    /// - the key must trade exactly `{asset, QUOTE}`, so a route can only ever end where the
    ///   buyback spends. The owner cannot point revenue at a third currency.
    /// - the pool must be initialised, so a key on a tier nobody has opened is refused here,
    ///   where the error names the cause, rather than parking every tranche silently.
    function setQuoteRoute(Currency asset, PoolKey calldata key) external onlyOwner {
        if (Currency.unwrap(asset) == address(BURN_TOKEN) || asset == QUOTE) {
            revert NotAConvertibleCurrency(asset);
        }

        if (address(key.poolManager) == address(0)) {
            delete _quoteRoutes[asset];
            PoolKey memory cleared;
            emit QuoteRouteUpdated(asset, cleared, false);
            return;
        }

        bool assetFirst = key.currency0 == asset && key.currency1 == QUOTE;
        bool quoteFirst = key.currency1 == asset && key.currency0 == QUOTE;
        if (!assetFirst && !quoteFirst) revert RouteMissingLeg(asset);

        (uint160 sqrtPriceX96,,,) = ICLPoolManager(address(key.poolManager)).getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialised();

        _quoteRoutes[asset] = key;
        emit QuoteRouteUpdated(asset, key, assetFirst);
    }

    /// @notice D32. Designate a launch token to accumulate here instead of being converted.
    /// @dev Convert is the default and holding is the exception, because the burn rate is what
    /// `MIN_BURN_BPS` promises: holding every launch token would roughly halve the graduated
    /// burn, since only the quote half of the LP fee would ever reach the buyback.
    ///
    /// Neither leg of the buyback can be held - `QUOTE` and the burn token have their own paths,
    /// and letting either onto this list would make `sweep`'s exclusion negotiable.
    function setHold(Currency currency, bool held) external onlyOwner {
        if (Currency.unwrap(currency) == address(BURN_TOKEN) || currency == QUOTE) {
            revert NotAConvertibleCurrency(currency);
        }
        isHeld[currency] = held;
        emit HoldUpdated(currency, held);
    }

    /// @notice Below this amount, a currency accumulates instead of paying a swap's gas.
    /// @dev Zero means no minimum. Per currency, because a launch token's units say nothing
    /// about its value and nothing about any other launch token's.
    function setMinConvertAmount(Currency currency, uint256 amount) external onlyOwner {
        minConvertAmount[currency] = amount;
        emit MinConvertAmountUpdated(currency, amount);
    }

    /// @notice Recover a currency this contract is holding rather than burning.
    /// @dev ⛔ Cannot touch either leg of the buyback. Unlike `PositionLocker`, revenue DOES sit
    /// in this contract between harvests, so an unrestricted sweep would be a way for the owner
    /// to take burn revenue before it is burnt.
    ///
    /// 🔴 And since the normalise leg landed, a LAUNCH TOKEN is burn revenue too - it converts,
    /// buys and burns like everything else - so excluding the two named currencies is no longer
    /// enough. What is sweepable is what the timelock has explicitly designated as held (D32).
    /// Taking a token out is therefore `setHold` and then `sweep`: two calls, both of which
    /// emit, rather than one that looks like housekeeping. A donation with no pool behind it is
    /// recovered the same way, which costs one extra call and makes every exit look identical
    /// from outside.
    function sweep(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        if (Currency.unwrap(currency) == address(BURN_TOKEN) || currency == QUOTE) {
            revert CannotSweepBuybackLeg(currency);
        }
        if (!isHeld[currency]) revert SweepRequiresHold(currency);
        amount = currency.balanceOfSelf();
        if (amount > 0) currency.transfer(to, amount);
        emit TokenSwept(currency, to, amount);
    }

    // -------------------------------------------------------------------------------------
    // Transient lock flag
    // -------------------------------------------------------------------------------------

    function _setLockOpen(bool open) private {
        assembly ("memory-safe") {
            tstore(LOCK_OPEN_SLOT, open)
        }
    }

    function _lockOpen() private view returns (bool open) {
        assembly ("memory-safe") {
            open := tload(LOCK_OPEN_SLOT)
        }
    }

    /// @dev Reached only if a pool ever pairs native INJ; `take` would deliver it here.
    receive() external payable {}
}
