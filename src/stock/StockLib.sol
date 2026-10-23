// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {IExchangeDerivatives} from "../interfaces/IExchangeDerivatives.sol";
import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {SubaccountLib} from "../libraries/SubaccountLib.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {PythLazerLib} from "./PythLazerLib.sol";
import {Reference, Refusal, StockConfig, StockContext, StockLayout, StockState} from "./StockTypes.sol";

/// @title StockLib
/// @notice What every body of a `StockVault` shares: the hard limits and flags, the errors more than one
/// raises, the reference price, the hedge gap, and the helpers (valuation inputs, conversions, the
/// Choice vault lock). Internal only, so it is inlined into each body that uses it and never deployed.
library StockLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    IExchangeDerivatives internal constant EXCHANGE = IExchangeDerivatives(0x0000000000000000000000000000000000000065);
    uint256 internal constant BPS = 10_000;
    /// @dev A full flow bucket (`flowNow`).
    uint256 internal constant FULL = 1e18;

    // Pause flags.
    uint8 internal constant PAUSE_FILLS = 1;
    uint8 internal constant PAUSE_DEPOSITS = 2;
    uint8 internal constant PAUSE_WITHDRAWALS = 4;
    uint8 internal constant PAUSE_RESTOCK = 8;
    uint8 internal constant PAUSE_FIXING = 16;
    /// @dev No order may ADD to the short (covers still go out): set by `coverUnreadable`, so nobody
    /// re-opens a short on a market whose negative funding index would make it unreadable again.
    uint8 internal constant PAUSE_HEDGE = 32;

    // Hard limits on the owner's tunables, so a captured owner still cannot price a fill at any
    // number it likes, run the hedge at any leverage, or let a price of any age through.
    uint16 internal constant MAX_SPREAD_LIMIT = 500;
    uint16 internal constant MAX_JUMP_LIMIT = 2000;
    uint16 internal constant MAX_HEDGE_SLIPPAGE = 200;
    uint16 internal constant MAX_RESTOCK_SLIPPAGE = 500;
    uint16 internal constant MAX_NAV_JUMP = 2000;
    uint16 internal constant MIN_LEVERAGE_X10 = 10;
    uint16 internal constant MAX_LEVERAGE_X10 = 50;
    uint32 internal constant MAX_AGE_MS_LIMIT = 5000;
    uint32 internal constant MAX_CLOSE_TOLERANCE = 1 hours;
    uint32 internal constant MIN_WINDOW = 1 minutes;
    uint32 internal constant MIN_REANCHOR_DELAY = 1 minutes;
    uint32 internal constant MAX_RESTOCK_DEADLINE = 2 days;
    /// @dev The issuer refunded a 1 h order 62 s after expiry (10-15) but has been hours late before.
    uint32 internal constant MIN_RESTOCK_DEADLINE = 1 hours;
    /// @dev The longest a restock order may ask the issuer to keep it open.
    uint32 internal constant MAX_ORDER_LIFE = 7 days;
    uint32 internal constant RESTOCK_CAP_WINDOW = 1 days;
    uint32 internal constant MAX_MAKER_TIMEOUT = 1 days;
    uint16 internal constant MAX_EXIT_FEE = 200;
    /// @dev The vault's ERC-4626 virtual-share offset.
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint32 internal constant MIN_QUEUE_DEADLINE = 1 hours;
    uint32 internal constant MAX_QUEUE_DEADLINE = 14 days;
    uint32 internal constant MAX_DEPOSIT_LOCK = 1 days;
    /// @dev The oldest the cash's own price may be for a fill, a hedge, a restock or a share price:
    /// relayers land it with every batch, every second or so, weekends included.
    uint256 internal constant MAX_CASH_AGE_MS = 60_000;

    /// @dev The exchange subaccount the short trades from. Not the default one, which trades off the
    /// bank balance: here its margin, PnL, fees and funding move a deposit of its own, so the bank
    /// balance the cash ledger reads moves only on the vault's own calls and on arrivals. One arrival
    /// is the vault's own: an order's relayer fee share (40% of its fee, `feeRecipient` empty = the
    /// sender) accrues on the DEFAULT subaccount and reaches the bank in whole units (measured 10-16).
    uint96 internal constant HEDGE_NONCE = 1;

    /// @dev Transient: set only while the vault holds a Choice vault lock it opened itself.
    uint256 internal constant LOCK_OPEN_SLOT = 0x2c7f2a3e1b8d4c6f9e0a5b7c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e;
    uint8 internal constant OP_TO_CLAIMS = 1;
    uint8 internal constant OP_FROM_CLAIMS = 2;

    /// @dev `tokenPerShare` for one token per share, and the range a vault accepts (as `StockRatios`).
    uint256 internal constant RATIO_ONE = 1e12;
    uint256 internal constant MIN_RATIO = 1e6;
    uint256 internal constant MAX_RATIO = 1e16;
    /// @dev The most the price per token may move across an accepted corporate action. A correct
    /// acceptance leaves it where it was; a ratio accepted before the feed moved (or after the wrong
    /// one) moves it by the split factor: 33% for a 3:2, 50% for a 2:1.
    uint16 internal constant MAX_ACTION_MOVE = 3000;

    error BadConfig();
    error BadMarket();
    error PositionUnreadable();
    error PriceNotUsable(Refusal reason);
    error OracleMissing();
    error CashShort(uint256 needed, uint256 own);
    error RestockCapExceeded(uint256 wanted, uint256 remaining);

    // -------------------------------------------------------------------------------------
    // The reference price
    // -------------------------------------------------------------------------------------

    /// @notice The reference off the stored price alone.
    function storedReference(StockConfig storage c, StockContext memory ctx) internal view returns (Reference memory) {
        return referencePrice(c, ctx, ctx.store.latest(ctx.feedId));
    }

    /// @notice The reference price per token, the session, and whether a call may act on them. A
    /// pending corporate action refuses every reference (`Refusal.Action`), so nothing that prices off
    /// one runs until the owner accepts it.
    function referencePrice(StockConfig storage c, StockContext memory ctx, IPriceStore.Price memory p)
        internal
        view
        returns (Reference memory r)
    {
        (r.session, r.sessionStart) = ctx.calendar.sessionAt(block.timestamp);
        r.closed = closedFor(c, r.session);
        r.sharePrice = inCash(ctx, toWad(p.price, p.exponent), MAX_CASH_AGE_MS);
        r.price = perToken(ctx, r.sharePrice);
        if (r.price == 0) {
            r.reason = Refusal.Stale;
            return r;
        }
        if (actionPending(ctx)) {
            r.reason = Refusal.Action;
            return r;
        }
        // 🔴 Judge the FEED's own time: a shut market's feed rides every fresh batch.
        uint256 feedMs = p.feedTimestampUs / 1000;
        uint256 nowMs = block.timestamp * 1000;
        r.ageMs = nowMs > feedMs ? nowMs - feedMs : 0;
        if (r.closed) {
            // Weekend mode needs the close itself: a price from before the close is an outage
            // that started in session, not a frozen market.
            uint256 feedS = p.feedTimestampUs / 1e6;
            if (feedS + c.closeTolerance < r.sessionStart) {
                r.reason = Refusal.Stale;
            } else if (
                r.session == MarketCalendar.Session.Overnight && feedS > r.sessionStart + c.closeTolerance
                    && r.ageMs > c.maxAgeMs
            ) {
                // An overnight priced as closed, on a price from after the close: the overnight
                // market is trading, so its price must be as fresh as one in session.
                r.reason = Refusal.Stale;
            }
        } else if (r.ageMs > c.maxAgeMs) {
            r.reason = Refusal.Stale;
        } else if (p.flags & PythLazerLib.HAS_SESSION != 0 && p.marketSession == PythLazerLib.SESSION_CLOSED) {
            // Scheduled hours, but the signer says the market is shut: a halt.
            r.reason = Refusal.Halted;
        }
        if (p.flags & PythLazerLib.HAS_QUOTE != 0) {
            r.hasQuote = true;
            // forge-lint: disable-next-line(unsafe-typecast) - both positive, ask >= bid.
            uint256 width = uint256(int256(p.bestAsk - p.bestBid));
            r.quoteBps = Math.mulDiv(width, BPS, 2 * uint256(int256(p.price)), Math.Rounding.Ceil);
        }
        if (p.flags & PythLazerLib.HAS_CONFIDENCE != 0) {
            r.hasConfidence = true;
            r.confidenceBps = Math.mulDiv(p.confidence, BPS, uint256(int256(p.price)), Math.Rounding.Ceil);
        }
    }

    /// @notice Revert unless a deposit, withdrawal or restock may act on `r`: the market open for
    /// this vault and the price fresh.
    function requireUsable(Reference memory r) internal pure {
        if (r.reason != Refusal.None) revert PriceNotUsable(r.reason);
        if (r.closed) revert PriceNotUsable(Refusal.Closed);
    }

    /// @notice Revert if `price` is a jump from the anchor: a restock never trades on one.
    function requireAnchored(StockConfig storage c, StockState storage s, uint256 price) internal view {
        if (s.anchorPrice != 0 && deviationBps(price, s.anchorPrice) > c.maxJumpBps) {
            revert PriceNotUsable(Refusal.Jump);
        }
    }

    /// @notice A corporate action is pending: halted by hand, or the registry announces a ratio other
    /// than the one the vault accepted.
    function actionPending(StockContext memory ctx) internal view returns (bool) {
        return ctx.actionHalt
            || (address(ctx.ratios) != address(0)
                && ctx.ratios.tokenPerShare(Currency.unwrap(ctx.stock)) != ctx.tokenPerShare);
    }

    // -------------------------------------------------------------------------------------
    // The hedge gap
    // -------------------------------------------------------------------------------------

    /// @notice The short the vault should add (positive) or cover (negative) against `short_`, 1e18
    /// units. The short tracks what the vault holds. While the issuer can restock (`restockOpen`) it may
    /// run ahead of that toward the target inventory, by at most `maxUnhedged`: if the restock never
    /// comes, that is the exposure left. That pre-short is put on only while the market is open and only
    /// as far as today's restock room, but once on it is kept across a close or a spent room, so the
    /// short does not churn at every session boundary. So it moves only when it is outside a range:
    /// from the holding plus what may be put on now, to the holding plus the most it may run ahead.
    function hedgeGap(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        uint256 price,
        bool restockOpen,
        bool closed,
        int256 short_
    ) internal view returns (int256) {
        // A restock order counts as held both ways: a buy's stock is on its way, a sell's is still ours.
        uint256 low = toUnits(Math.min(s.stockBooked, ownStock(s, ctx)), ctx.stockDecimals);
        if (s.orderOpen) low += toUnits(s.orderStock, ctx.stockDecimals);
        uint256 high = low;
        // No pre-hedge while an in-kind epoch unwinds: its debt is paid from cash the short would hold.
        if (restockOpen && s.debtOwed == 0) {
            uint256 held = stockToCash(ctx, s.stockBooked, price, Math.Rounding.Floor) + orderValue(s, ctx, price);
            if (c.targetInventory > held) {
                uint256 ahead = Math.min(c.targetInventory - held, c.maxUnhedged);
                high += cashToUnits(ctx, ahead, price);
                if (!closed) {
                    uint256 used =
                        block.timestamp >= uint256(s.restockWindowStart) + RESTOCK_CAP_WINDOW ? 0 : s.restockUsed;
                    uint256 room = c.restockDailyCap > used ? c.restockDailyCap - used : 0;
                    low += cashToUnits(ctx, Math.min(ahead, room), price);
                }
            }
        }
        int256 lo = toShares(ctx, low).toInt256();
        int256 hi = toShares(ctx, high).toInt256();
        return short_ < lo ? lo - short_ : short_ > hi ? hi - short_ : int256(0);
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    /// @dev The flow buckets as they stand now. Each drains its whole cap over `window`, continuously: no
    /// moment resets one, so there is no edge to time a burst against, and keeping one full costs its
    /// spread for as long as it is kept full.
    /// @return gross the share of the gross cap in force that is used (`FULL` = full)
    /// @return net the share of `netCap` used, buys (stock out) up and sells down, draining toward zero
    function flowNow(StockConfig storage c, StockState storage s) internal view returns (uint256 gross, int256 net) {
        uint256 drained = (block.timestamp - s.flowAt) * FULL / c.window;
        gross = s.grossUsed > drained ? s.grossUsed - drained : 0;
        net = s.netUsed;
        if (abs(net) <= drained) net = 0;
        else net = net > 0 ? net - drained.toInt256() : net + drained.toInt256();
    }

    /// @dev `value` as a share of `cap`: what a fill adds to a bucket. Rounded down, by under a wei of a full
    /// bucket, so a cap taken in even steps fills exactly.
    function share(uint256 value, uint256 cap) internal pure returns (uint256) {
        return Math.mulDiv(value, FULL, cap);
    }

    /// @dev Whether adding `added` takes a signed count further from zero and past `cap`. A fill that brings
    /// it back toward zero always passes, however full it is.
    function overCap(int256 used, int256 added, uint256 cap) internal pure returns (bool) {
        uint256 next = abs(used + added);
        return next > abs(used) && next > cap;
    }

    /// @dev The net stock value out counted for the closed period that began at `start`: zero for a period
    /// not counted yet, unless it follows the counted one with no open session between (a weekend into an
    /// overnight priced as closed), which makes them one period.
    function closedNetNow(StockConfig storage c, StockState storage s, StockContext memory ctx, uint256 start)
        internal
        view
        returns (int256)
    {
        if (s.closedStart == start) return s.closedNet;
        if (s.closedStart == 0 || start == 0) return 0;
        (MarketCalendar.Session before, uint256 beforeStart) = ctx.calendar.sessionAt(start - 1);
        return closedFor(c, before) && beforeStart == s.closedStart ? s.closedNet : int256(0);
    }

    /// @dev Whether `session` is closed for this vault: the market shut, or an overnight it prices as closed.
    function closedFor(StockConfig storage c, MarketCalendar.Session session) internal view returns (bool) {
        return
            session == MarketCalendar.Session.Closed
                || (session == MarketCalendar.Session.Overnight && !c.overnightLive);
    }

    /// @dev The stored price per token for valuation: any age, but it must exist.
    function markPrice(StockContext memory ctx) internal view returns (uint256) {
        return perToken(ctx, markSharePrice(ctx));
    }

    /// @dev The stored price per share, as the perp marks it: any age, but it must exist.
    function markSharePrice(StockContext memory ctx) internal view returns (uint256 price) {
        IPriceStore.Price memory p = ctx.store.latest(ctx.feedId);
        price = inCash(ctx, toWad(p.price, p.exponent), type(uint256).max);
        if (price == 0) revert OracleMissing();
    }

    /// @dev A 1e18 USD price as a price in the cash. The feeds price the stock in USD, but the cash is
    /// a stablecoin, and the perp the short trades is marked in it (the stock's feed over the cash's,
    /// measured 10-16: AAPL/USDC = feed 922 / feed 7), so everything the vault does prices in the cash.
    /// Zero, which refuses, when the cash's own price is missing or more than `maxAgeMs` old; a vault with
    /// no cash feed takes the cash as exactly one USD.
    function inCash(StockContext memory ctx, uint256 usd, uint256 maxAgeMs) internal view returns (uint256) {
        if (ctx.cashFeedId == 0 || usd == 0) return usd;
        IPriceStore.Price memory q = ctx.store.latest(ctx.cashFeedId);
        uint256 cashUsd = toWad(q.price, q.exponent);
        uint256 ageMs = block.timestamp * 1000 - Math.min(block.timestamp * 1000, q.feedTimestampUs / 1000);
        if (cashUsd == 0 || ageMs > maxAgeMs) return 0;
        return Math.mulDiv(usd, 1e18, cashUsd);
    }

    /// @dev A per-share price as a per-token price.
    function perToken(StockContext memory ctx, uint256 sharePrice) internal pure returns (uint256) {
        return Math.mulDiv(sharePrice, RATIO_ONE, ctx.tokenPerShare);
    }

    /// @dev 1e18 token units as 1e18 share units, the perp's.
    function toShares(StockContext memory ctx, uint256 tokenUnits) internal pure returns (uint256) {
        return Math.mulDiv(tokenUnits, RATIO_ONE, ctx.tokenPerShare);
    }

    /// @dev What the open restock order is worth: its stock at `price`, either way. A buy's stock is
    /// hedged from the moment it is ordered, so it is valued as stock too: valued as its cash, a move
    /// before delivery would show the short's loss or gain with nothing against it.
    function orderValue(StockState storage s, StockContext memory ctx, uint256 price) internal view returns (uint256) {
        if (!s.orderOpen) return 0;
        return stockToCash(ctx, s.orderStock, price, Math.Rounding.Floor);
    }

    /// @dev Count `cash` against the daily restock cap, shared by memo orders and quotes.
    function countRestock(StockConfig storage c, StockState storage s, uint256 cash) internal {
        if (block.timestamp >= uint256(s.restockWindowStart) + RESTOCK_CAP_WINDOW) {
            s.restockWindowStart = uint64(block.timestamp);
            s.restockUsed = 0;
        }
        uint256 remaining = c.restockDailyCap > s.restockUsed ? c.restockDailyCap - s.restockUsed : 0;
        if (cash > remaining) revert RestockCapExceeded(cash, remaining);
        s.restockUsed += cash.toUint96();
    }

    /// @dev Give back `cash` counted in `window`, if that window is still the current one (a later
    /// window started from zero and owes nothing).
    function uncountRestock(StockState storage s, uint64 window, uint256 cash) internal returns (uint256 back) {
        if (window != s.restockWindowStart || block.timestamp >= uint256(window) + RESTOCK_CAP_WINDOW) return 0;
        back = Math.min(cash, s.restockUsed);
        s.restockUsed -= uint96(back);
    }

    /// @dev Stock held beyond the booked stock and what is held for fixing-lane requesters.
    function unbooked(StockState storage s, StockContext memory ctx) internal view returns (uint256) {
        uint256 held = ownStock(s, ctx);
        return held > s.stockBooked ? held - s.stockBooked : 0;
    }

    /// @dev A Lazer mantissa and exponent as 1e18 per unit; zero for a missing or negative price.
    function toWad(int64 price, int16 exponent) internal pure returns (uint256) {
        if (price <= 0) return 0;
        int256 e = int256(exponent) + 18;
        // forge-lint: disable-next-line(unsafe-typecast) - positive, tested above.
        uint256 m = uint256(int256(price));
        // forge-lint: disable-next-line(unsafe-typecast) - sign tested.
        if (e >= 0) return e > 40 ? 0 : m * 10 ** uint256(e);
        // forge-lint: disable-next-line(unsafe-typecast) - negative here, so -e is positive.
        return -e > 40 ? 0 : m / 10 ** uint256(-e);
    }

    /// @notice What the vault holds of `currency`: the token itself plus its Choice vault claims.
    function holding(StockContext memory ctx, Currency currency) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this)) + ctx.vault.balanceOf(address(this), currency);
    }

    /// @notice The booked cash, never more than is held less what is held for fixing-lane requesters
    /// and redeemers. Cash that arrived unbooked (an issuer's payment or refund, a donation) is not
    /// the vault's to spend or value until it is booked.
    function ownCash(StockState storage s, StockContext memory ctx) internal view returns (uint256) {
        return Math.min(_freeCash(s, ctx), s.cashBooked);
    }

    /// @dev Cash held beyond the booked cash and what is held for requesters and redeemers.
    function unbookedCash(StockState storage s, StockContext memory ctx) internal view returns (uint256) {
        uint256 free = _freeCash(s, ctx);
        return free > s.cashBooked ? free - s.cashBooked : 0;
    }

    function _freeCash(StockState storage s, StockContext memory ctx) private view returns (uint256) {
        uint256 h = holding(ctx, ctx.cash);
        return h > s.cashOwed ? h - s.cashOwed : 0;
    }

    /// @dev The hedge subaccount's cash, in cash units: what is free, and the total (which includes a
    /// resting order's margin hold), each one unit less than the precompile answers. 🔴 The exchange keeps
    /// a balance to 18 decimals, and the precompile answers it rounded to the NEAREST unit (measured 10-16:
    /// 10,082,710.60217 answered 10,082,711), so withdrawing what it says is free can ask for a fraction of
    /// a unit too much, and the exchange refuses. One unit less than it answers is always there: that is
    /// what this calls free, and no withdrawal asks for more. So the subaccount always keeps a unit the
    /// vault never takes back, and the total leaves it out too: the value counts only cash that can reach
    /// the bank, or every share would claim a unit more than any cash exit can pay (mainnet 10-20: a full
    /// exit reverted `CashShortForQueue(n, n - 1)`).
    function subaccountCash(StockState storage s) internal view returns (uint256 available, uint256 total) {
        (available, total) = EXCHANGE.subaccountDeposit(subaccount(), s.cashDenom);
        if (available != 0) --available;
        if (total != 0) --total;
    }

    /// @notice The stock held less what is held for fixing-lane requesters.
    function ownStock(StockState storage s, StockContext memory ctx) internal view returns (uint256) {
        uint256 h = holding(ctx, ctx.stock);
        return h > s.stockOwed ? h - s.stockOwed : 0;
    }

    /// @dev Booked stock plus an open restock buy's, which the inventory cap counts as held.
    function stockInventory(StockState storage s) internal view returns (uint256) {
        return s.stockBooked + (s.orderOpen && !s.orderSell ? s.orderStock : 0);
    }

    /// @dev Cash no trade may spend: the reserve, and what an unwinding in-kind epoch is owed.
    function cashKept(StockConfig storage c, StockState storage s) internal view returns (uint256) {
        return uint256(c.cashReserve) + s.debtOwed;
    }

    /// @dev Cash a restock buy may not spend: `cashKept`, plus the open redeem epoch's value, the cash the
    /// queue is waiting for (an instant withdrawal cannot take it either).
    function cashKeptQueued(StockLayout storage l) internal view returns (uint256) {
        uint256 shares = l.epochs[l.redeemEpoch].shares;
        uint256 queued = shares == 0 ? 0 : IERC4626(address(this)).convertToAssets(shares);
        return cashKept(l.config, l.state) + queued;
    }

    /// @dev Make `amount` of cash available as the token for the vault to spend, refusing to dip
    /// into what it holds for fixing-lane requesters. The caller books what it spends.
    function spendOwnCash(StockState storage s, StockContext memory ctx, uint256 amount) internal {
        uint256 own = ownCash(s, ctx);
        if (own < amount) revert CashShort(amount, own);
        ensureToken(ctx, ctx.cash, amount);
    }

    /// @dev The short as the exchange has it now, 1e18 units (positive = short). A hedge order placed in
    /// this block is not in it yet; one from an earlier block is, filled or not.
    function liveShort(StockState storage s) internal view returns (int256) {
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = position(s);
        return found ? signed(p) : int256(0);
    }

    /// @dev A position as a short: positive short, negative long.
    function signed(IExchangeDerivatives.DerivativePosition memory p) internal pure returns (int256) {
        return p.isLong ? -p.quantity.toInt256() : p.quantity.toInt256();
    }

    /// @dev The position, reverting `PositionUnreadable` when the exchange cannot answer (see `readPosition`).
    function position(StockState storage s)
        internal
        view
        returns (bool found, IExchangeDerivatives.DerivativePosition memory p)
    {
        bool readable;
        (readable, found, p) = readPosition(s);
        if (!readable) revert PositionUnreadable();
    }

    /// @dev Whether the short can be valued now: the exchange reads it back, and it is not missing (gone
    /// with no buy of the vault's to explain it, whether or not a confirmation has seen that yet).
    function shortValued(StockState storage s) internal view returns (bool) {
        if (s.positionLost) return false;
        (bool readable, bool found,) = readPosition(s);
        return readable && (found || covered(s));
    }

    /// @dev Whether the vault's own buys could have covered the whole confirmed short: a cover from an
    /// earlier block, and whatever was left to fill of a resting maker buy.
    function covered(StockState storage s) internal view returns (bool) {
        if (s.shortConfirmed <= 0) return true;
        uint256 buying = s.pendingQty < 0 ? abs(s.pendingQty) : 0;
        if (bytes(s.makerHash).length != 0 && !s.makerSell) buying += s.makerFillable;
        return buying >= abs(s.shortConfirmed);
    }

    /// @dev The vault's position on its market, as the exchange has it now. 🔴 The precompile packs a
    /// position's cumulative funding entry as a uint256 and REVERTS the whole read when one is negative
    /// ("negatively-signed value cannot be packed"): the entry is the market's funding index as of the
    /// position's last fill or margin decrease, and that index goes negative once shorts have paid on net
    /// (10-16: 712 of 2,015 mainnet positions). Then `readable` is false and nothing else means anything.
    /// It also lists positions on ACTIVE markets only: one on a paused market reads as none.
    function readPosition(StockState storage s)
        internal
        view
        returns (bool readable, bool found, IExchangeDerivatives.DerivativePosition memory p)
    {
        try EXCHANGE.subaccountPositions(subaccount()) returns (IExchangeDerivatives.DerivativePosition[] memory all) {
            bytes32 h = keccak256(bytes(s.marketId));
            for (uint256 k; k < all.length; ++k) {
                if (keccak256(bytes(all[k].marketID)) == h) return (true, true, all[k]);
            }
            return (true, false, p);
        } catch {
            return (false, false, p);
        }
    }

    /// @dev Revert unless `id` is a market id as the exchange answers it: `0x` and 64 LOWERCASE hex
    /// digits. Orders take any spelling, but positions come back in this one, and the vault finds its
    /// own by comparing strings: a misspelt id would never find the short it opened.
    function requireMarketId(string memory id) internal pure {
        bytes memory b = bytes(id);
        if (b.length != 66 || b[0] != "0" || b[1] != "x") revert BadMarket();
        for (uint256 k = 2; k < 66; ++k) {
            bytes1 c = b[k];
            if ((c < "0" || c > "9") && (c < "a" || c > "f")) revert BadMarket();
        }
    }

    /// @dev The resting maker order as the exchange has it now, if it still rests.
    function makerOrder(StockState storage s)
        internal
        view
        returns (bool, IExchangeDerivatives.TrimmedDerivativeLimitOrder memory o)
    {
        string[] memory hashes = new string[](1);
        hashes[0] = s.makerHash;
        IExchangeDerivatives.TrimmedDerivativeLimitOrder[] memory all = EXCHANGE.derivativeOrdersByHashes(
            IExchangeDerivatives.DerivativeOrdersRequest({
                marketID: s.marketId, subaccountID: subaccount(), orderHashes: hashes
            })
        );
        bytes32 h = keccak256(bytes(hashes[0]));
        for (uint256 k; k < all.length; ++k) {
            if (keccak256(bytes(all[k].orderHash)) == h) return (true, all[k]);
        }
        return (false, o);
    }

    /// @dev Margin plus unrealised PnL at `price`, in cash units, floored at zero.
    function positionValue(StockContext memory ctx, IExchangeDerivatives.DerivativePosition memory p, uint256 price)
        internal
        pure
        returns (uint256)
    {
        int256 move = p.isLong ? price.toInt256() - p.entryPrice.toInt256() : p.entryPrice.toInt256() - price.toInt256();
        int256 v = p.margin.toInt256() + move * p.quantity.toInt256() / 1e18;
        // forge-lint: disable-next-line(unsafe-typecast) - positive by the test.
        return v <= 0 ? 0 : fromApi(ctx, uint256(v), Math.Rounding.Floor);
    }

    /// @notice The vault's hedge subaccount (`HEDGE_NONCE`).
    function subaccount() internal view returns (string memory) {
        return SubaccountLib.subaccount(address(this), HEDGE_NONCE);
    }

    function stockToCash(StockContext memory ctx, uint256 amount, uint256 price, Math.Rounding r)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount, price, 10 ** (uint256(ctx.stockDecimals) + 18 - ctx.cashDecimals), r);
    }

    /// @dev 1e18 whole units at `price`, in cash units.
    function unitsToCash(StockContext memory ctx, uint256 units, uint256 price) internal pure returns (uint256) {
        return fromApi(ctx, Math.mulDiv(units, price, 1e18), Math.Rounding.Floor);
    }

    /// @dev Cash units at `price`, in 1e18 whole units, rounded down.
    function cashToUnits(StockContext memory ctx, uint256 cash, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(cash * 10 ** (18 - uint256(ctx.cashDecimals)), 1e18, price);
    }

    function toUnits(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return decimals == 18 ? amount : Math.mulDiv(amount, 1e18, 10 ** uint256(decimals));
    }

    /// @dev The exchange's 18-decimal format to cash units.
    function fromApi(StockContext memory ctx, uint256 v, Math.Rounding r) internal pure returns (uint256) {
        return Math.mulDiv(v, 1, 10 ** (18 - uint256(ctx.cashDecimals)), r);
    }

    function deviationBps(uint256 price, uint256 anchor) internal pure returns (uint256) {
        uint256 d = price > anchor ? price - anchor : anchor - price;
        return d * BPS / anchor;
    }

    function abs(int256 x) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a signed value.
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev Make sure `amount` of `currency` is held as the token, pulling the shortfall out of claims.
    /// Every outflow of the token goes through this (or `spendOwnCash`, which calls it).
    function ensureToken(StockContext memory ctx, Currency currency, uint256 amount) internal {
        uint256 bal = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal < amount) lock(ctx, OP_FROM_CLAIMS, currency, amount - bal);
    }

    /// @dev Move all of `currency` the vault holds as the token into its Choice vault claims, which fills
    /// pay out of (`StockPricing.guards`): called where the vault's own cash or stock arrives, so a fill can
    /// pay it out at once. Every outflow pulls what it needs back out first (`ensureToken`), and the value
    /// counts both forms (`holding`), so it changes nothing the vault is worth.
    function intoClaims(StockContext memory ctx, Currency currency) internal {
        uint256 bal = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal != 0) lock(ctx, OP_TO_CLAIMS, currency, bal);
    }

    function lock(StockContext memory ctx, uint8 op, Currency currency, uint256 amount) internal {
        setLockOpen(true);
        ctx.vault.lock(abi.encode(op, currency, amount));
        setLockOpen(false);
    }

    function setLockOpen(bool open) internal {
        assembly ("memory-safe") {
            tstore(LOCK_OPEN_SLOT, open)
        }
    }

    function lockOpen() internal view returns (bool open) {
        assembly ("memory-safe") {
            open := tload(LOCK_OPEN_SLOT)
        }
    }
}
