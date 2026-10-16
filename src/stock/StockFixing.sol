// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {PythLazerLib} from "./PythLazerLib.sol";
import {StockLib} from "./StockLib.sol";
import {
    FixingBatch,
    FixingConfig,
    FixingRequest,
    FixingSide,
    Refusal,
    StockConfig,
    StockContext,
    StockLayout,
    StockState
} from "./StockTypes.sol";

/// @title StockFixing
/// @notice A `StockVault`'s fixing lane, for trades too large for the instant lane and for batched
/// flows (DCA, rebalances): requests are committed before a boundary with their input held in
/// escrow, every request for that boundary fills at one price, the signed update stamped exactly
/// at the boundary's tick, and each requester then pulls their fill. Like `StockLib`, its external
/// functions run by DELEGATECALL, as the vault.
///
/// **Why the price cannot be chosen.**
/// - One valid update: Pyth Pro's fixed-rate channel stamps every update on a 200 ms grid, and a
///   settlement must present the one stamped at the batch's tick. No settler picks among several.
/// - Committed blind: a request lands in a block stamped before the boundary, and the tick is at
///   least 2 s after it. Nothing is cancelled, and there is no minimum out: a request is an order
///   at the fixing, so there is no option to fill only when the price moved one's way, and no
///   penalty is needed to price one.
/// - A short window: a settlement is accepted only within `settleWindow` of the tick. A requester
///   who would rather not settle an unfavourable fixing holds an option over that window's move at
///   most, and only if nobody else (the keeper) settles first.
/// - Constant gas: settlement books one total per side, so dust requests cost their senders, not
///   the settler; requesters pull their own fills.
///
/// **Capacity.** The vault takes on the batch's net, not its gross: the two sides cross at the
/// fixing. The net is capped by the stock the vault has booked, its cash above the reserve and the
/// margin to hedge what comes in, its inventory cap, and `maxNet`; past those the larger side fills
/// pro rata and the rest is refunded.
///
/// **Lapse.** A batch not settled in its window (no update, a stale or jumped price, a pause, a
/// spread over the maximum) lapses, and every request in it is refunded in full.
library StockFixing {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;
    uint32 internal constant MIN_INTERVAL = 1 minutes;
    uint32 internal constant MAX_INTERVAL = 1 days;
    uint32 internal constant GRID_MS = 200;
    /// @dev Block times trail the wall clock: a transaction runs up to its height's length after its
    /// block's time (BFT time is the previous height's median precommit), measured up to 2.6 s over
    /// 40k blocks (10-16). 5 s keeps every commit blind.
    uint32 internal constant MIN_DELAY_MS = 5000;
    uint32 internal constant MAX_DELAY_MS = 60_000;
    uint32 internal constant MIN_SETTLE_WINDOW = 5;
    uint32 internal constant MAX_SETTLE_WINDOW = 10 minutes;

    error FixingClosed();
    error FixingPaused();
    error WrongBoundary(uint256 next);
    error ZeroRecipient();
    error SessionClosed();
    error RequestTooSmall(uint256 value, uint256 minimum);
    error SideFull(uint256 value, uint256 room);
    error NothingToSettle();
    error AlreadySettled();
    error SettleWindowClosed(uint256 deadline);
    error WrongTick(uint256 timestampUs, uint256 tickUs);
    error FixingRefused(Refusal reason);
    error NoRequest();
    error NotYetSettled(uint256 deadline);
    error BadFixingConfig();

    event FixingCommitted(
        uint256 indexed id,
        uint64 indexed boundary,
        address indexed recipient,
        address sender,
        bool cashIn,
        uint256 amountIn
    );
    event FixingSettled(
        uint64 indexed boundary,
        uint256 price,
        uint256 spreadBps,
        uint256 buyIn,
        uint256 buyFilled,
        uint256 stockOut,
        uint256 sellIn,
        uint256 sellFilled,
        uint256 cashOut
    );
    event FixingClaimed(uint256 indexed id, address indexed recipient, uint256 out, uint256 refund);

    // -------------------------------------------------------------------------------------
    // Commit
    // -------------------------------------------------------------------------------------

    /// @notice Commit `amountIn` (cash to buy stock when `cashIn`, stock to sell otherwise) to the
    /// next boundary's fixing, paid in now and held in escrow. `boundary` must be that next one, so
    /// a request that lands late fails rather than drifting into the boundary after.
    /// @return id the request, for `claim`
    function commit(StockLayout storage l, uint64 boundary, bool cashIn, uint256 amountIn, address recipient)
        external
        returns (uint256 id)
    {
        FixingConfig memory fc = l.fixing;
        StockState storage s = l.state;
        StockContext memory ctx = l.ctx;
        if (fc.interval == 0) revert FixingClosed();
        if (s.paused & StockLib.PAUSE_FIXING != 0) revert FixingPaused();
        uint256 next = (block.timestamp / fc.interval + 1) * fc.interval;
        if (boundary != next) revert WrongBoundary(next);
        if (recipient == address(0)) revert ZeroRecipient();

        FixingBatch storage b = l.batches[boundary];
        if (b.tickMs == 0) {
            b.tickMs = (uint256(boundary) * 1000 + fc.delayMs).toUint64();
            b.deadline = b.tickMs / 1000 + fc.settleWindow;
        }
        if (!_open(l.config, ctx, b.tickMs / 1000)) revert SessionClosed();

        FixingSide storage side = cashIn ? b.buy : b.sell;
        uint256 mark = cashIn ? 0 : StockLib.markPrice(ctx);
        uint256 value = cashIn ? amountIn : StockLib.stockToCash(ctx, amountIn, mark, Math.Rounding.Floor);
        if (amountIn == 0 || value < fc.minRequest) revert RequestTooSmall(value, fc.minRequest);
        uint256 held = cashIn ? side.amountIn : StockLib.stockToCash(ctx, side.amountIn, mark, Math.Rounding.Ceil);
        if (held + value > fc.maxSide) revert SideFull(value, fc.maxSide > held ? fc.maxSide - held : 0);

        // Book what arrived, not what was asked for.
        IERC20 token = IERC20(Currency.unwrap(cashIn ? ctx.cash : ctx.stock));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        uint128 got = (token.balanceOf(address(this)) - before).toUint128();

        side.amountIn += got;
        if (cashIn) s.cashOwed += got;
        else s.stockOwed += got;
        id = ++l.nextRequestId;
        l.requests[id] = FixingRequest({recipient: recipient, boundary: boundary, cashIn: cashIn, amountIn: got});
        emit FixingCommitted(id, boundary, recipient, msg.sender, cashIn, got);
    }

    // -------------------------------------------------------------------------------------
    // Settle
    // -------------------------------------------------------------------------------------

    /// @notice Fill the batch for `boundary` at the signed update stamped exactly at its tick.
    /// Permissionless: there is one valid update, so the caller chooses nothing.
    function settle(StockLayout storage l, uint64 boundary, bytes calldata update) external {
        StockState storage s = l.state;
        StockConfig storage c = l.config;
        StockContext memory ctx = l.ctx;
        FixingBatch storage b = l.batches[boundary];
        if (b.buy.amountIn == 0 && b.sell.amountIn == 0) revert NothingToSettle();
        if (b.settled) revert AlreadySettled();
        if (block.timestamp > b.deadline) revert SettleWindowClosed(b.deadline);
        if (s.paused & StockLib.PAUSE_FIXING != 0) revert FixingPaused();

        IPriceStore.Price memory p = ctx.store.verify(update, ctx.feedId);
        if (p.timestampUs != uint256(b.tickMs) * 1000) revert WrongTick(p.timestampUs, uint256(b.tickMs) * 1000);
        uint256 usd = StockLib.toWad(p.price, p.exponent);
        if (ctx.cashFeedId != 0) {
            // The cash's price from the same update, so at the same tick: the settler picks no moment.
            IPriceStore.Price memory q = ctx.store.verify(update, ctx.cashFeedId);
            uint256 cashUsd = StockLib.toWad(q.price, q.exponent);
            usd = cashUsd == 0 ? 0 : Math.mulDiv(usd, 1e18, cashUsd);
        }
        uint256 price = StockLib.perToken(ctx, usd);
        Refusal why = _check(c, s, ctx, p, price, b.tickMs / 1000);
        if (why != Refusal.None) revert FixingRefused(why);

        FixingConfig memory fc = l.fixing;
        uint256 bps = _spread(c, s, fc, ctx, p, price, b.buy.amountIn, b.sell.amountIn);
        if (bps > fc.maxSpreadBps) revert FixingRefused(Refusal.Spread);

        (uint256 buyFilled, uint256 stockOut, uint256 sellFilled, uint256 cashOut) =
            _fills(c, s, fc, ctx, price, bps, b.buy.amountIn, b.sell.amountIn);

        // The filled inputs become the vault's; the outputs are held for the requesters. Capacity
        // keeps both of the vault's own balances whole: it never delivers more stock than it booked
        // plus what the sellers brought, nor pays more cash than it has above the reserve.
        s.cashOwed = s.cashOwed - buyFilled.toUint128() + cashOut.toUint128();
        s.stockOwed = s.stockOwed - sellFilled.toUint128() + stockOut.toUint128();
        s.stockBooked = s.stockBooked + sellFilled - stockOut;
        s.cashBooked = s.cashBooked + buyFilled - cashOut;
        (b.buy.filled, b.buy.out) = (buyFilled.toUint128(), stockOut.toUint128());
        (b.sell.filled, b.sell.out) = (sellFilled.toUint128(), cashOut.toUint128());
        b.price = price.toUint128();
        b.spreadBps = bps.toUint16();
        b.settled = true;
        // A live, signed fixing is a fresh anchor, as an instant fill is.
        s.anchorPrice = price.toUint128();
        s.jumpSince = 0;
        emit FixingSettled(
            boundary, price, bps, b.buy.amountIn, buyFilled, stockOut, b.sell.amountIn, sellFilled, cashOut
        );
    }

    /// @dev Why the update cannot fix the batch, judged at the tick: the feed's own time fresh at
    /// it, the market open at it, the signer not reporting a halt, no jump from the anchor, and no
    /// stock missing from what the vault booked.
    function _check(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        IPriceStore.Price memory p,
        uint256 price,
        uint256 tick
    ) private view returns (Refusal) {
        if (price == 0 || uint256(p.feedTimestampUs) + uint256(c.maxAgeMs) * 1000 < p.timestampUs) {
            return Refusal.Stale;
        }
        if (StockLib.actionPending(ctx)) return Refusal.Action;
        if (!_open(c, ctx, tick)) return Refusal.Closed;
        if (p.flags & PythLazerLib.HAS_SESSION != 0 && p.marketSession == PythLazerLib.SESSION_CLOSED) {
            return Refusal.Halted;
        }
        if (s.anchorPrice != 0 && StockLib.deviationBps(price, s.anchorPrice) > c.maxJumpBps) return Refusal.Jump;
        if (StockLib.ownStock(s, ctx) < s.stockBooked) return Refusal.Deficit;
        return Refusal.None;
    }

    /// @dev The fixing's spread: the base, the market-spread and confidence terms (or their
    /// defaults), the size term on the net at the fixing, and any keeper or re-anchor widen. No age
    /// term: the price is the tick's, whenever the batch settles.
    function _spread(
        StockConfig storage c,
        StockState storage s,
        FixingConfig memory fc,
        StockContext memory ctx,
        IPriceStore.Price memory p,
        uint256 price,
        uint256 buyIn,
        uint256 sellIn
    ) private view returns (uint256 bps) {
        bps = fc.spreadBps;
        // forge-lint: disable-next-line(unsafe-typecast) - price > 0 is checked before this runs.
        uint256 mantissa = uint256(int256(p.price));
        if (p.flags & PythLazerLib.HAS_QUOTE != 0) {
            // forge-lint: disable-next-line(unsafe-typecast) - both positive, ask >= bid.
            uint256 width = uint256(int256(p.bestAsk - p.bestBid));
            bps += Math.mulDiv(width, BPS, 2 * mantissa, Math.Rounding.Ceil);
        } else {
            bps += c.quoteMissingBps;
        }
        if (p.flags & PythLazerLib.HAS_CONFIDENCE != 0) {
            bps += Math.mulDiv(p.confidence, BPS, mantissa, Math.Rounding.Ceil);
        } else {
            bps += c.confidenceMissingBps;
        }
        uint256 sellValue = StockLib.stockToCash(ctx, sellIn, price, Math.Rounding.Floor);
        uint256 net = buyIn > sellValue ? buyIn - sellValue : sellValue - buyIn;
        bps += Math.mulDiv(fc.sizeBps, Math.min(net, fc.maxNet), fc.maxNet, Math.Rounding.Ceil);
        if (block.timestamp < s.widenUntil) bps += s.widenBps;
        if (block.timestamp < s.wideUntil) bps += c.reanchorBps;
    }

    /// @dev Both sides at the fixing, the net within capacity. Rounding favours the vault: outputs
    /// down, the filled part of a cut buy side up.
    function _fills(
        StockConfig storage c,
        StockState storage s,
        FixingConfig memory fc,
        StockContext memory ctx,
        uint256 price,
        uint256 bps,
        uint256 buyIn,
        uint256 sellIn
    ) private view returns (uint256 buyFilled, uint256 stockOut, uint256 sellFilled, uint256 cashOut) {
        uint256 scale = 10 ** (uint256(ctx.stockDecimals) + 18 - ctx.cashDecimals);
        uint256 ask = Math.mulDiv(price, BPS + bps, BPS, Math.Rounding.Ceil);
        uint256 bid = price * (BPS - bps) / BPS;
        (buyFilled, sellFilled) = (buyIn, sellIn);
        stockOut = Math.mulDiv(buyIn, scale, ask);
        if (stockOut >= sellIn) {
            // The vault delivers stock net, out of what it has booked.
            uint256 cap = Math.min(s.stockBooked, Math.mulDiv(fc.maxNet, scale, price));
            if (stockOut - sellIn > cap) {
                stockOut = sellIn + cap;
                buyFilled = Math.min(buyIn, Math.mulDiv(stockOut, ask, scale, Math.Rounding.Ceil));
            }
        } else {
            // The vault takes stock net and pays cash. The cash out is below the net's value, and
            // hedging that value needs value * 10 / leverageX10 of margin; both must fit above the
            // reserve.
            uint256 own = StockLib.ownCash(s, ctx);
            uint256 kept = StockLib.cashKept(c, s);
            uint256 room = own > kept ? own - kept : 0;
            uint256 capValue = Math.min(fc.maxNet, room * c.leverageX10 / (uint256(c.leverageX10) + 10));
            uint256 heldValue = StockLib.stockToCash(ctx, StockLib.stockInventory(s), price, Math.Rounding.Ceil);
            capValue = Math.min(capValue, c.maxInventory > heldValue ? c.maxInventory - heldValue : 0);
            uint256 cap = Math.mulDiv(capValue, scale, price);
            if (sellIn - stockOut > cap) sellFilled = stockOut + cap;
        }
        cashOut = Math.mulDiv(sellFilled, bid, scale);
    }

    // -------------------------------------------------------------------------------------
    // Claim
    // -------------------------------------------------------------------------------------

    /// @notice Pay request `id` to its recipient: its share of its side's output and the unfilled
    /// rest of its input once the batch is settled, or all of its input once the batch has lapsed.
    /// Permissionless, and never paused: it only pays out what is owed.
    function claim(StockLayout storage l, uint256 id) external returns (uint256 out, uint256 refund) {
        FixingRequest memory r = l.requests[id];
        if (r.recipient == address(0)) revert NoRequest();
        StockState storage s = l.state;
        StockContext memory ctx = l.ctx;
        FixingBatch storage b = l.batches[r.boundary];
        FixingSide storage side = r.cashIn ? b.buy : b.sell;
        if (b.settled) {
            // A share of what is left, so the last claim takes the rounding dust.
            uint256 filled = Math.mulDiv(r.amountIn, side.filled, side.amountIn);
            out = Math.mulDiv(r.amountIn, side.out, side.amountIn);
            refund = r.amountIn - filled;
            side.filled -= filled.toUint128();
            side.out -= out.toUint128();
        } else {
            if (block.timestamp <= b.deadline) revert NotYetSettled(b.deadline);
            refund = r.amountIn;
        }
        side.amountIn -= r.amountIn;
        delete l.requests[id];

        (Currency cIn, Currency cOut) = r.cashIn ? (ctx.cash, ctx.stock) : (ctx.stock, ctx.cash);
        if (r.cashIn) {
            s.cashOwed -= refund.toUint128();
            s.stockOwed -= out.toUint128();
        } else {
            s.stockOwed -= refund.toUint128();
            s.cashOwed -= out.toUint128();
        }
        _pay(ctx, cOut, r.recipient, out);
        _pay(ctx, cIn, r.recipient, refund);
        emit FixingClaimed(id, r.recipient, out, refund);
    }

    // -------------------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------------------

    function checkConfig(FixingConfig memory fc) external pure {
        if (fc.interval == 0) return;
        if (fc.interval < MIN_INTERVAL || fc.interval > MAX_INTERVAL) revert BadFixingConfig();
        if (fc.delayMs < MIN_DELAY_MS || fc.delayMs > MAX_DELAY_MS || fc.delayMs % GRID_MS != 0) {
            revert BadFixingConfig();
        }
        if (fc.settleWindow < MIN_SETTLE_WINDOW || fc.settleWindow > MAX_SETTLE_WINDOW) revert BadFixingConfig();
        if (fc.spreadBps == 0 || fc.maxSpreadBps > StockLib.MAX_SPREAD_LIMIT) revert BadFixingConfig();
        if (uint256(fc.spreadBps) + fc.sizeBps > fc.maxSpreadBps) revert BadFixingConfig();
        if (fc.minRequest == 0 || fc.maxSide < fc.minRequest || fc.maxNet == 0) revert BadFixingConfig();
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    /// @dev Whether the market is open for this vault at `t`: scheduled hours, and overnight only
    /// when the vault trades it live.
    function _open(StockConfig storage c, StockContext memory ctx, uint256 t) private view returns (bool) {
        (MarketCalendar.Session session,) = ctx.calendar.sessionAt(t);
        return
            session != MarketCalendar.Session.Closed && (session != MarketCalendar.Session.Overnight || c.overnightLive);
    }

    function _pay(StockContext memory ctx, Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        StockLib.ensureToken(ctx, currency, amount);
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }
}
