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
/// The named guards below still exist, because failing inside `setGuards` / `setBuybackPool`
/// says what is wrong while somebody is looking at it, where a park is silent.
///
/// That is also why the price guard is a `sqrtPriceLimitX96` on the swap rather than a
/// `minAmountOut` check afterwards. A limit makes the pool fill only as far as the bound and
/// stop, leaving the rest of the input here for next time; a minimum-out check would have to
/// revert, and reverting is the one thing this contract cannot do.
///
/// ## What the owner can and cannot do
///
/// Thin, in the shape of `PositionLocker`'s: the pool to trade through, the thresholds, the
/// treasury, and sweeping a currency that is neither leg of the buyback. The owner **cannot**
/// lower `burnBps` past the floor, and **cannot** sweep the quote asset or the burn token, which
/// is what stops "recover a stuck token" from becoming a way to take pending burn revenue.
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
    error CannotSweepBuybackLeg(Currency currency);

    /// @param quoteSpent quote actually consumed; may be less than offered if the limit bound.
    event BoughtBack(uint256 quoteOffered, uint256 quoteSpent, uint256 tokensReceived);
    /// @param burnt destroyed via `BURN_TOKEN.burn`; `toTreasury` is the ops remainder.
    event Burnt(uint256 burnt, uint256 toTreasury);
    /// @param reason 0 = below `minBuybackAmount`, 1 = inside `minBuybackInterval`,
    /// 2 = currency has no buyback route, 3 = the swap itself reverted. Funds stay here in
    /// every case.
    event Parked(Currency indexed currency, uint256 amount, uint8 reason);
    event BurnBpsUpdated(uint16 oldBps, uint16 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event BuybackPoolUpdated(PoolKey key, bool quoteIsCurrency0);
    event GuardsUpdated(uint256 minBuybackAmount, uint16 maxImpactBps, uint32 minBuybackInterval);
    event TokenSwept(Currency indexed currency, address indexed to, uint256 amount);

    uint8 private constant PARK_BELOW_MINIMUM = 0;
    uint8 private constant PARK_RATE_LIMITED = 1;
    uint8 private constant PARK_NO_ROUTE = 2;
    uint8 private constant PARK_SWAP_FAILED = 3;

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
            // No route. Held rather than forwarded to the treasury: the ops wallet taking 100%
            // of a currency the burn was entitled to 80% of would be a silent policy change.
            // `sweep` is the deliberate, visible way out.
            emit Parked(currency, currency.balanceOfSelf(), PARK_NO_ROUTE);
        }
    }

    /// @notice Run a buyback now if the guards allow, without waiting for a harvest.
    /// @dev For keepers, and for draining a balance parked by an earlier guard.
    function buyback() external nonReentrant {
        _tryBuyback();
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
        try VAULT.lock(abi.encode(amountIn)) returns (bytes memory) {
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

    /// @inheritdoc ILockCallback
    /// @dev Gated on a lock this contract opened, not merely on the vault's identity. The vault
    /// is immutable here so `msg.sender` alone is nearly sufficient, but "nearly" is not a
    /// property worth resting a swap on - the same reasoning as `ChoiceRouter.lockAcquired`.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault();
        if (!_lockOpen()) revert LockNotOpen();

        uint256 amountIn = abi.decode(data, (uint256));
        // Read inside the lock rather than passed in, so a `getSlot0` that reverts - an
        // uninitialised pool reached despite `setBuybackPool`'s check - is caught by the
        // `try/catch` in `_tryBuyback` along with everything else, instead of escaping it.
        uint160 limit = _priceLimit();
        PoolKey memory key = buybackPool;
        bool zeroForOne = quoteIsCurrency0;

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
    function _priceLimit() private view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = ICLPoolManager(address(buybackPool.poolManager)).getSlot0(buybackPool.toId());
        uint256 halfImpact = uint256(maxImpactBps) / 2;
        if (quoteIsCurrency0) {
            // 0 -> 1 walks the price DOWN.
            return FullMath.mulDiv(sqrtPriceX96, BPS_DENOMINATOR - halfImpact, BPS_DENOMINATOR).toUint160();
        }
        return FullMath.mulDiv(sqrtPriceX96, BPS_DENOMINATOR + halfImpact, BPS_DENOMINATOR).toUint160();
    }

    // -------------------------------------------------------------------------------------
    // Burn
    // -------------------------------------------------------------------------------------

    /// @dev The treasury gets the remainder rather than a second multiplication, so integer
    /// division cannot strand dust here on every call.
    function _settleBurnToken() private {
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

    /// @notice Recover a currency that reached this contract with no buyback route.
    /// @dev ⛔ Cannot touch either leg of the buyback. Unlike `PositionLocker`, revenue DOES sit
    /// in this contract between harvests, so an unrestricted sweep would be a way for the owner
    /// to take burn revenue before it is burnt. The two currencies that matter are excluded and
    /// there is no other path out.
    function sweep(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        if (Currency.unwrap(currency) == address(BURN_TOKEN) || currency == QUOTE) {
            revert CannotSweepBuybackLeg(currency);
        }
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
