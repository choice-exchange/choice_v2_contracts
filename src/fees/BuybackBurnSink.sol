// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";

import {IBurnSink} from "../interfaces/IBurnSink.sol";
import {IBurnableERC20} from "../interfaces/IBurnableERC20.sol";

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
/// **The sink DERIVES that pool rather than being told about it** - see `conversionTier`.
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
/// Thin, in the shape of `PositionLocker`'s: the pool to trade through, the tier launches
/// graduate onto, the thresholds, the treasury, and which launch tokens are held rather than
/// converted. The owner **cannot** lower `burnBps` past the floor, and **cannot** sweep the quote
/// asset or the burn token, which is what stops "recover a stuck token" from becoming a way to
/// take pending burn revenue.
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
    uint16 public constant MIN_IMPACT_BPS = 2;

    /// @notice The token bought and burnt. Immutable: a sink that could be repointed at another
    /// token is a sink whose burn is a promise again.
    IBurnableERC20 public immutable BURN_TOKEN;

    /// @notice The currency revenue arrives in and the buyback spends. wINJ in practice - the
    /// pad's curve fee always exits as wINJ, which is what makes one quote leg sufficient.
    Currency public immutable QUOTE;

    /// @notice The vault holding the buyback pool. One deployment, so it is immutable and the
    /// lock callback needs no allowlist.
    IVault public immutable VAULT;

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

    /// @notice The fee tier, hook and parameters every graduation pool is keyed to - everything
    /// a launch's own pool key contains EXCEPT its two currencies.
    ///
    /// @dev This is how the sink knows where to convert a launch token, and it is deliberately
    /// not a per-launch registration. Three options were on the table:
    ///
    /// ⛔ **The timelock registers each launch's pool.** Graduation is permissionless and
    /// continuous, so this is a governance transaction per graduate - and every launch nobody
    /// got around to registering parks for ever, which is the exact defect this leg exists to
    /// close. `ChoiceFeeController.zeroLaunchPoolProtocolFee` rejected the same shape for the
    /// same reason.
    ///
    /// ⛔ **`InfinitySettler` pushes the key at graduation.** It knows the key, so this reads
    /// as the obvious answer, and it is worse than it looks. It registers nothing for the
    /// launches that ALREADY graduated - the long tail this leg is about - and it puts another
    /// cross-contract call inside `settle`, the one transaction in this system that must not
    /// fail. On 2026-09-06 exactly that shape (settler -> locker, one changed selector) reverted
    /// with EMPTY returndata after passing every gate and wedged a graduation. Wrapping the push
    /// in `try/catch` to protect graduation only trades a loud failure for a silent one: the
    /// registration quietly does not happen and the revenue parks with nothing to look at.
    ///
    /// ✅ **The sink derives the key.** A graduation pool's key is its two currencies plus this
    /// triple, and the launch token is the currency `burn` was just handed - so one timelock
    /// call covers every launch, past and future, and `settle` is untouched.
    ///
    /// 🔑 The derived pool is provably a graduate, for the same reason the fee controller's
    /// permissionless zeroing is safe: `hooks` is part of a pool's identity and
    /// `LaunchPoolGuardHook` permissions `beforeInitialize` to the settler alone, so a pool that
    /// exists at this key is a pool the settler created. `setConversionTier` therefore refuses a
    /// zero hook - a hookless tier is one anybody can open, and derivation would then follow a
    /// pool an attacker priced.
    ///
    /// ⚠️ A launch that graduated under a DIFFERENT tier is not derivable while this one is
    /// installed. Point the tier back at the old triple, convert the stragglers, and point it
    /// forward again; or `setHold` them and sweep. There is deliberately no per-token override:
    /// one would let the owner aim a conversion at a pool of their own choosing, which is the
    /// value-extraction path the sweep guard below exists to close.
    struct ConversionTier {
        IPoolManager poolManager;
        IHooks hooks;
        uint24 fee;
        bytes32 parameters;
    }

    ConversionTier public conversionTier;

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
    error InvalidTier(uint24 fee);

    /// @param quoteSpent quote actually consumed; may be less than offered if the limit bound.
    event BoughtBack(uint256 quoteOffered, uint256 quoteSpent, uint256 tokensReceived);
    /// @param burnt destroyed via `BURN_TOKEN.burn`; `toTreasury` is the ops remainder.
    event Burnt(uint256 burnt, uint256 toTreasury);
    /// @param quoteReceived what the sink now holds to buy back with; it goes on to do so.
    event Converted(Currency indexed currency, uint256 offered, uint256 spent, uint256 quoteReceived);
    /// @param reason 0 = below the minimum, 1 = inside `minBuybackInterval`, 2 = currency has no
    /// route, 3 = the swap itself reverted, 4 = the burn/treasury settle reverted, 5 = held by
    /// policy (D32). Funds stay here in every case.
    event Parked(Currency indexed currency, uint256 amount, uint8 reason);
    event BurnBpsUpdated(uint16 oldBps, uint16 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event BuybackPoolUpdated(PoolKey key, bool quoteIsCurrency0);
    event GuardsUpdated(uint256 minBuybackAmount, uint16 maxImpactBps, uint32 minBuybackInterval);
    event ConversionTierUpdated(IPoolManager poolManager, IHooks hooks, uint24 fee, bytes32 parameters);
    event HoldUpdated(Currency indexed currency, bool held);
    event MinConvertAmountUpdated(Currency indexed currency, uint256 amount);
    event TokenSwept(Currency indexed currency, address indexed to, uint256 amount);

    uint8 private constant PARK_BELOW_MINIMUM = 0;
    uint8 private constant PARK_RATE_LIMITED = 1;
    uint8 private constant PARK_NO_ROUTE = 2;
    uint8 private constant PARK_SWAP_FAILED = 3;
    uint8 private constant PARK_SETTLE_FAILED = 4;
    uint8 private constant PARK_HELD = 5;

    constructor(
        IBurnableERC20 _burnToken,
        Currency _quote,
        IVault _vault,
        address _treasury,
        address _owner,
        uint16 _minBurnBps,
        uint16 _burnBps
    ) Ownable(_owner) {
        if (
            address(_burnToken) == address(0) || Currency.unwrap(_quote) == address(0) || address(_vault) == address(0)
                || _treasury == address(0) || _owner == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_minBurnBps > BPS_DENOMINATOR) revert InvalidBps(_minBurnBps);
        if (_burnBps > BPS_DENOMINATOR) revert InvalidBps(_burnBps);
        if (_burnBps < _minBurnBps) revert BurnBpsBelowFloor(_burnBps, _minBurnBps);

        BURN_TOKEN = _burnToken;
        QUOTE = _quote;
        VAULT = _vault;
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
        } else {
            // A launch token. Converted to `QUOTE` against its own graduation pool and then
            // bought back in the same call - or parked, if any gate says so. It is NEVER
            // forwarded to the treasury: the ops wallet taking 100% of a currency the burn was
            // entitled to `burnBps` of would be a silent policy change.
            _tryConvert(currency);
        }
    }

    /// @notice Run a buyback now if the guards allow, without waiting for a harvest.
    /// @dev For keepers, and for draining a balance parked by an earlier guard.
    function buyback() external nonReentrant {
        _tryBuyback();
    }

    /// @notice Convert a parked launch token to `QUOTE` now, and buy back with the proceeds.
    /// @dev The counterpart to `buyback()` for the normalise leg: revenue that reached this
    /// contract WITHOUT a `burn` call - `PositionLocker.claim` pays the launchpad's LP-fee share
    /// straight here, it does not notify - would otherwise sit until the next harvest of that
    /// same currency, which for a launch token may never come.
    ///
    /// Permissionless, like everything else that only chooses WHEN: the pool is derived, the
    /// bound is `maxImpactBps`, and the proceeds can only become `QUOTE` in this contract.
    ///
    /// Unlike `burn`, this one is allowed to revert - it is not on the harvest path, and a named
    /// error on the two currencies that have their own leg says what is wrong while somebody is
    /// looking at it.
    function convert(Currency currency) external nonReentrant {
        if (Currency.unwrap(currency) == address(BURN_TOKEN) || currency == QUOTE) {
            revert NotAConvertibleCurrency(currency);
        }
        _tryConvert(currency);
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
        try VAULT.lock(abi.encode(buybackPool, quoteIsCurrency0, amountIn)) returns (bytes memory) {
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
    /// Every branch below parks, for the same reason the buyback's do: `ChoiceFeeController`
    /// calls `burn` from inside `harvest`, and a launch token whose conversion could revert would
    /// be a trivially weaponisable way to brick harvesting for that currency.
    ///
    /// 🔑 The pool this trades through is DERIVED, not registered - see `conversionTier` for why,
    /// and for what happens to a launch that graduated under a different tier.
    ///
    /// 🔑 Infinity skips a pool's hooks when the hook itself is the caller, so a conversion
    /// through a pool with a fee hook on it would not be taxed by that hook - the sink is not the
    /// hook here, but the graduation pool's guard hook registers `beforeInitialize` and nothing
    /// else, so there is no swap-time hook on this path at all.
    function _tryConvert(Currency currency) private {
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

        (PoolKey memory key, bool zeroForOne) = _conversionKey(currency);
        // A tier that was never configured. Everything else about the pool - whether it exists,
        // whether it holds liquidity, whether the manager is paused - is left to the `try/catch`
        // below, deliberately: `getSlot0` on an address with no code answers with empty
        // returndata, so a pre-flight existence check is itself a way to revert a harvest.
        if (address(key.poolManager) == address(0)) {
            emit Parked(currency, amountIn, PARK_NO_ROUTE);
            return;
        }

        uint256 quoteBefore = QUOTE.balanceOfSelf();

        bool swapped;
        _setLockOpen(true);
        try VAULT.lock(abi.encode(key, zeroForOne, amountIn)) returns (bytes memory) {
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

    /// @dev The pool key a launch token converts through: its two currencies, sorted, plus the
    /// tier every graduation pool is keyed to.
    /// @return key Zero `poolManager` when no tier is configured - the caller parks on that.
    /// @return zeroForOne True when `currency` is the pool's `currency0`, i.e. selling 0 -> 1.
    function _conversionKey(Currency currency) private view returns (PoolKey memory key, bool zeroForOne) {
        ConversionTier memory tier = conversionTier;
        if (address(tier.poolManager) == address(0)) return (key, false);

        zeroForOne = Currency.unwrap(currency) < Currency.unwrap(QUOTE);
        (Currency currency0, Currency currency1) = zeroForOne ? (currency, QUOTE) : (QUOTE, currency);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: tier.hooks,
            poolManager: tier.poolManager,
            fee: tier.fee,
            parameters: tier.parameters
        });
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

        // The KEY travels with the call, because there are two legs now: the buyback trades
        // `buybackPool` and a conversion trades a key derived from `conversionTier`. Everything
        // downstream is identical, so they share one callback rather than one each.
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        // Read inside the lock rather than passed in, so a `getSlot0` that reverts - an
        // uninitialised pool reached despite `setBuybackPool`'s check, or a conversion pool that
        // was never opened at all - is caught by the caller's `try/catch` along with everything
        // else, instead of escaping it.
        uint160 limit = _priceLimit(key, zeroForOne);

        ICLPoolManager(address(key.poolManager))
            .swap(
                key,
                ICLPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    // Negative is exact-input. The pool consumes up to this much and stops at
                    // `limit`, so a partial fill is the expected outcome, not an error.
                    amountSpecified: -amountIn.toInt256(),
                    sqrtPriceLimitX96: limit
                }),
                ""
            );

        // Debts before credits: the vault pays a credit out of real reserves, so taking first
        // can fail on a vault that is exactly funded. Same ordering as `ChoiceRouter`.
        _settleDelta(key.currency0);
        _settleDelta(key.currency1);
        _takeDelta(key.currency0);
        _takeDelta(key.currency1);
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
    /// One bound serves both legs. A conversion sells into a graduate's own pool, which is
    /// thinner than SPROUT/wINJ rather than deeper, so a setting sized for the buyback is if
    /// anything conservative there - and a conversion that hits the bound fills PARTIALLY and
    /// leaves the rest for the next window, exactly as an oversized buyback does.
    function _priceLimit(PoolKey memory key, bool zeroForOne) private view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = ICLPoolManager(address(key.poolManager)).getSlot0(key.toId());
        uint256 halfImpact = uint256(maxImpactBps) / 2;
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

    /// @notice Whether a `convert(currency)` right now would actually trade.
    /// @dev For keepers and dashboards. It answers false for a held currency, which is the
    /// point: holding is meant to be visible from outside, not inferred from nothing happening.
    function canConvert(Currency currency) external view returns (bool) {
        if (Currency.unwrap(currency) == address(BURN_TOKEN) || currency == QUOTE) return false;
        if (isHeld[currency]) return false;
        uint256 amountIn = currency.balanceOfSelf();
        uint64 last = lastConvertAt[currency];
        (PoolKey memory key,) = _conversionKey(currency);
        return amountIn > 0 && amountIn >= minConvertAmount[currency]
            && (last == 0 || block.timestamp >= uint256(last) + minBuybackInterval)
            && address(key.poolManager) != address(0);
    }

    /// @notice The pool a launch token would convert through, and the direction it would sell.
    /// @dev Public so a deploy or a dashboard can check the derivation against the settler's own
    /// `poolParameters()` rather than trusting that the tier was entered correctly.
    function conversionPool(Currency currency) external view returns (PoolKey memory key, bool zeroForOne) {
        return _conversionKey(currency);
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

    /// @notice Point the normalise leg at the tier launches graduate onto.
    /// @dev Everything a graduation pool key holds except its currencies, which come from the
    /// launch token being converted. Ask the settler for them: `lpFee()`, `poolParameters()` and
    /// `hooks()` are exactly these three fields, and `conversionPool` lets a deploy check the
    /// derived key against a pool that already exists.
    ///
    /// 🔴 A zero hook is refused, and that check is load-bearing rather than hygiene. The whole
    /// reason a derived key can be trusted is that `LaunchPoolGuardHook` permissions
    /// `beforeInitialize` to the settler, so a pool at the derived key must be one the settler
    /// created. A hookless tier is one anybody can open at a price of their choosing, and the
    /// conversion would walk straight into it.
    function setConversionTier(IPoolManager poolManager, IHooks hooks, uint24 fee, bytes32 parameters)
        external
        onlyOwner
    {
        if (address(poolManager) == address(0) || address(hooks) == address(0)) revert ZeroAddress();
        // Upstream's own bound: an LP fee above 100% is unrepresentable.
        if (fee > 1_000_000) revert InvalidTier(fee);
        conversionTier = ConversionTier({poolManager: poolManager, hooks: hooks, fee: fee, parameters: parameters});
        emit ConversionTierUpdated(poolManager, hooks, fee, parameters);
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
