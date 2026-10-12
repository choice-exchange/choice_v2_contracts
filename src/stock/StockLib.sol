// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {IExchangeDerivatives} from "../interfaces/IExchangeDerivatives.sol";
import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {SubaccountLib} from "../libraries/SubaccountLib.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {PythLazerLib} from "./PythLazerLib.sol";
import {Fill, Reference, Refusal, StockConfig, StockContext, StockState, SwapRequest} from "./StockTypes.sol";

/// @title StockLib
/// @notice The pricing, guards, hedge and valuation of a `StockVault`, kept out of the vault's own
/// bytecode. Its external functions run by DELEGATECALL, so they act as the vault: the perp position
/// they trade is the vault's, the Choice vault lock they take calls the vault back, and their events
/// are the vault's.
library StockLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    IExchangeDerivatives internal constant EXCHANGE = IExchangeDerivatives(0x0000000000000000000000000000000000000065);
    uint256 internal constant BPS = 10_000;

    // Pause flags.
    uint8 internal constant PAUSE_FILLS = 1;
    uint8 internal constant PAUSE_DEPOSITS = 2;
    uint8 internal constant PAUSE_WITHDRAWALS = 4;
    uint8 internal constant PAUSE_RESTOCK = 8;
    uint8 internal constant PAUSE_FIXING = 16;

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
    uint32 internal constant MAX_RESTOCK_DEADLINE = 1 days;
    uint32 internal constant RESTOCK_CAP_WINDOW = 1 days;

    /// @dev Transient: set only while the vault holds a Choice vault lock it opened itself.
    uint256 internal constant LOCK_OPEN_SLOT = 0x2c7f2a3e1b8d4c6f9e0a5b7c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e;
    uint8 internal constant OP_TO_CLAIMS = 1;
    uint8 internal constant OP_FROM_CLAIMS = 2;

    error BadConfig();
    error PriceNotUsable(Refusal reason);
    error OracleMissing();
    error HedgePending();
    error HedgeTooSoon(uint256 allowedAt);
    error MarginHealthy();
    error CashShort(uint256 needed, uint256 own);

    event HedgeOrdered(bool sell, uint256 quantity, uint256 worstPrice, uint256 margin, string orderHash);
    event HedgeConfirmed(int256 shortQty);
    event MarginAdded(uint256 amount);
    event Anchored(uint256 price);
    event JumpSeen(uint256 price, uint256 anchor);
    event Reanchored(uint256 price, uint256 wideUntil);

    // -------------------------------------------------------------------------------------
    // Fills
    // -------------------------------------------------------------------------------------

    /// @notice The fill for one swap, or the reason there is none. Every amount rounds the vault's
    /// way: output down, input up.
    function quote(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        SwapRequest memory w,
        bytes calldata hookData
    ) external view returns (Fill memory f) {
        if (s.paused & PAUSE_FILLS != 0) return _refuse(f, Refusal.Paused);
        if (!s.poolRegistered) return _refuse(f, Refusal.Disabled);
        Reference memory r = referencePrice(c, ctx, pickPrice(ctx, hookData));
        f.price = r.price;
        f.closed = r.closed;
        if (r.reason != Refusal.None) return _refuse(f, r.reason);
        if (r.closed && !c.weekendFills) return _refuse(f, Refusal.Closed);
        if (s.anchorPrice != 0 && deviationBps(r.price, s.anchorPrice) > c.maxJumpBps) {
            return _refuse(f, Refusal.Jump);
        }
        if (ownStock(s, ctx) < s.stockBooked) return _refuse(f, Refusal.Deficit);

        uint256 scale = 10 ** (uint256(ctx.stockDecimals) + 18 - ctx.cashDecimals);
        (uint256 maxTrade, uint256 windowCap) =
            r.closed ? (uint256(c.maxTradeClosed), uint256(c.windowCapClosed)) : (c.maxTrade, c.windowCap);
        uint256 used = windowUsedNow(c, s);
        {
            // The size terms read the trade at the reference price, before the spread is known.
            uint256 cashEstimate = w.cashIn == w.exactInput ? w.amount : Math.mulDiv(w.amount, r.price, scale);
            f.spreadBps = spread(c, s, r, cashEstimate, used, maxTrade, windowCap);
        }
        if (f.spreadBps > c.maxSpread) return _refuse(f, Refusal.Spread);

        int256 lean = skew(c, s, ctx, r.price);
        if (w.cashIn) {
            // forge-lint: disable-next-line(unsafe-typecast) - |lean| < minSpread <= spread.
            uint256 ask = Math.mulDiv(r.price, uint256(int256(BPS + f.spreadBps) + lean), BPS, Math.Rounding.Ceil);
            (f.amountIn, f.amountOut) = w.exactInput
                ? (w.amount, Math.mulDiv(w.amount, scale, ask))
                : (Math.mulDiv(w.amount, ask, scale, Math.Rounding.Ceil), w.amount);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast) - |lean| < minSpread <= spread < BPS.
            uint256 bid = r.price * uint256(int256(BPS - f.spreadBps) + lean) / BPS;
            (f.amountIn, f.amountOut) = w.exactInput
                ? (w.amount, Math.mulDiv(w.amount, bid, scale))
                : (Math.mulDiv(w.amount, scale, bid, Math.Rounding.Ceil), w.amount);
        }
        Refusal g = guards(c, s, ctx, w, f, maxTrade, windowCap, used);
        if (g != Refusal.None) return _refuse(f, g);
    }

    /// @notice The newer of the stored price and a signed update handed in with the swap. A bad
    /// update is ignored, never fatal.
    function pickPrice(StockContext memory ctx, bytes calldata hookData)
        internal
        view
        returns (IPriceStore.Price memory p)
    {
        p = ctx.store.latest(ctx.feedId);
        if (hookData.length != 0) {
            try ctx.store.verify(hookData, ctx.feedId) returns (IPriceStore.Price memory q) {
                if (q.price > 0 && q.timestampUs > p.timestampUs) p = q;
            } catch {}
        }
    }

    /// @notice The reference off the stored price alone.
    function storedReference(StockConfig storage c, StockContext memory ctx) internal view returns (Reference memory) {
        return referencePrice(c, ctx, ctx.store.latest(ctx.feedId));
    }

    /// @notice The reference price, the session, and whether a call may act on them.
    function referencePrice(StockConfig storage c, StockContext memory ctx, IPriceStore.Price memory p)
        internal
        view
        returns (Reference memory r)
    {
        (r.session, r.sessionStart) = ctx.calendar.sessionAt(block.timestamp);
        r.closed = r.session == MarketCalendar.Session.Closed
            || (r.session == MarketCalendar.Session.Overnight && !c.overnightLive);
        r.price = toWad(p.price, p.exponent);
        if (r.price == 0) {
            r.reason = Refusal.Stale;
            return r;
        }
        // 🔴 Judge the FEED's own time: a shut market's feed rides every fresh batch.
        uint256 feedMs = p.feedTimestampUs / 1000;
        uint256 nowMs = block.timestamp * 1000;
        r.ageMs = nowMs > feedMs ? nowMs - feedMs : 0;
        if (r.closed) {
            // Weekend mode needs the close itself: a price from before the close is an outage
            // that started in session, not a frozen market.
            if (p.feedTimestampUs / 1e6 + c.closeTolerance < r.sessionStart) r.reason = Refusal.Stale;
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

    /// @notice The spread for a fill, before the inventory lean, floored at `minSpread`.
    function spread(
        StockConfig storage c,
        StockState storage s,
        Reference memory r,
        uint256 cashEstimate,
        uint256 used,
        uint256 maxTrade,
        uint256 windowCap
    ) internal view returns (uint256 bps) {
        if (r.closed) {
            bps = c.spreadClosed;
        } else {
            if (r.session == MarketCalendar.Session.Regular) bps = c.spreadRegular;
            else if (r.session == MarketCalendar.Session.Overnight) bps = c.spreadOvernight;
            else bps = c.spreadExtended;
            bps += Math.mulDiv(c.agePerSecondBps, r.ageMs, 1000, Math.Rounding.Ceil);
            if (r.session == MarketCalendar.Session.Regular && block.timestamp < r.sessionStart + c.openWindow) {
                bps += c.openBps;
            }
        }
        bps += r.hasQuote ? r.quoteBps : c.quoteMissingBps;
        bps += r.hasConfidence ? r.confidenceBps : c.confidenceMissingBps;
        if (maxTrade != 0) {
            bps += Math.mulDiv(c.sizeBps, Math.min(cashEstimate, maxTrade), maxTrade, Math.Rounding.Ceil);
        }
        if (windowCap != 0) {
            bps += Math.mulDiv(c.windowBps, Math.min(used + cashEstimate, windowCap), windowCap, Math.Rounding.Ceil);
        }
        if (block.timestamp < s.widenUntil) bps += s.widenBps;
        if (block.timestamp < s.wideUntil) bps += c.reanchorBps;
        if (bps < c.minSpread) bps = c.minSpread;
    }

    /// @dev Every guard a priced fill must pass. A failure is a refusal, never a revert.
    function guards(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        SwapRequest memory w,
        Fill memory f,
        uint256 maxTrade,
        uint256 windowCap,
        uint256 used
    ) internal view returns (Refusal) {
        uint256 cashLeg = w.cashIn ? f.amountIn : f.amountOut;
        if (f.amountIn == 0 || f.amountOut == 0 || cashLeg > maxTrade) return Refusal.Size;
        uint256 outValue = w.cashIn ? stockToCash(ctx, f.amountOut, f.price, Math.Rounding.Ceil) : f.amountOut;
        if (used + outValue > windowCap) return Refusal.Window;
        // Fills pay out of claims only.
        if (ctx.vault.balanceOf(address(this), w.cashIn ? ctx.stock : ctx.cash) < f.amountOut) {
            return Refusal.Inventory;
        }
        if (w.cashIn && f.amountOut > s.stockBooked) return Refusal.Inventory;
        uint256 bookedAfter = w.cashIn ? s.stockBooked - f.amountOut : s.stockBooked + f.amountIn;
        if (!w.cashIn) {
            if (stockToCash(ctx, bookedAfter, f.price, Math.Rounding.Ceil) > c.maxInventory) {
                return Refusal.InventoryCap;
            }
            // The cash left must cover the reserve plus the margin to hedge what comes in.
            uint256 margin = stockToCash(ctx, f.amountIn, f.price, Math.Rounding.Ceil) * 10 / c.leverageX10;
            if (ownCash(s, ctx) < f.amountOut + c.cashReserve + margin) return Refusal.Reserve;
        }
        if (_widensExposure(c, s, ctx, bookedAfter, f.price)) return Refusal.Unhedged;
        if (!withinLimit(w.zeroForOne, f.amountIn, f.amountOut, w.sqrtPriceLimitX96)) return Refusal.PriceLimit;
        return Refusal.None;
    }

    /// @dev Exposure may grow only up to `maxUnhedged`, judged against the confirmed short and
    /// against the short a pending hedge would leave: until a hedge is read back, it might not
    /// have filled, and it might have.
    function _widensExposure(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        uint256 bookedAfter,
        uint256 price
    ) internal view returns (bool) {
        int256 inTransit = s.orderOpen ? toUnits(s.orderMinOut, ctx.stockDecimals).toInt256() : int256(0);
        int256 before = toUnits(s.stockBooked, ctx.stockDecimals).toInt256() + inTransit;
        int256 next = toUnits(bookedAfter, ctx.stockDecimals).toInt256() + inTransit;
        for (uint256 k; k < 2; ++k) {
            int256 short_ = k == 0 ? s.shortConfirmed : s.shortConfirmed + s.pendingQty;
            uint256 b = abs(before - short_);
            uint256 a = abs(next - short_);
            if (a > b && unitsToCash(ctx, a, price) > c.maxUnhedged) return true;
        }
        return false;
    }

    /// @dev The lean in bps from the holding before the fill: `+skewBps` holding nothing,
    /// `-skewBps` holding twice the target or more, zero on target or with no target.
    function skew(StockConfig storage c, StockState storage s, StockContext memory ctx, uint256 price)
        internal
        view
        returns (int256)
    {
        if (c.skewBps == 0 || c.targetInventory == 0) return 0;
        uint256 held = stockToCash(ctx, s.stockBooked, price, Math.Rounding.Floor);
        int256 bps = BPS.toInt256();
        int256 target = uint256(c.targetInventory).toInt256();
        int256 deviation = (target - held.toInt256()) * bps / target;
        if (deviation < -bps) deviation = -bps;
        return deviation * uint256(c.skewBps).toInt256() / bps;
    }

    /// @dev The swapper's price limit, applied to the fill's own rate. A limit at either end of
    /// the price range is the routers' "no limit" and always passes.
    function withinLimit(bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceLimitX96)
        internal
        pure
        returns (bool)
    {
        if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO + 1 || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO - 1) {
            return true;
        }
        uint256 limitX96 = Math.mulDiv(sqrtPriceLimitX96, sqrtPriceLimitX96, 1 << 96);
        return zeroForOne
            ? amountOut >= Math.mulDiv(amountIn, limitX96, 1 << 96)
            : amountIn <= Math.mulDiv(amountOut, limitX96, 1 << 96);
    }

    // -------------------------------------------------------------------------------------
    // The anchor
    // -------------------------------------------------------------------------------------

    /// @notice Keep the jump breaker's anchor on the feed. A move within the breaker re-anchors at
    /// once; a jump is noted, and re-anchored only once it has stood for `reanchorDelay`, after
    /// which fills pay `reanchorBps` more for `reanchorWide`. Permissionless: it can only follow
    /// a signed price, and only slowly across a jump.
    function poke(StockConfig storage c, StockState storage s, StockContext memory ctx) external {
        Reference memory r = storedReference(c, ctx);
        if (r.reason != Refusal.None || r.closed) revert PriceNotUsable(r.reason);
        if (s.anchorPrice == 0 || deviationBps(r.price, s.anchorPrice) <= c.maxJumpBps) {
            s.anchorPrice = r.price.toUint128();
            s.jumpSince = 0;
            emit Anchored(r.price);
        } else if (s.jumpSince == 0) {
            s.jumpSince = uint64(block.timestamp);
            emit JumpSeen(r.price, s.anchorPrice);
        } else if (block.timestamp >= uint256(s.jumpSince) + c.reanchorDelay) {
            s.anchorPrice = r.price.toUint128();
            s.jumpSince = 0;
            s.wideUntil = uint64(block.timestamp + c.reanchorWide);
            emit Reanchored(r.price, s.wideUntil);
        }
    }

    // -------------------------------------------------------------------------------------
    // Hedge
    // -------------------------------------------------------------------------------------

    /// @notice Read the short back from the position: the truth a pending order is judged against.
    function confirmHedge(StockState storage s) public {
        if (s.hedgeBlock == block.number) revert HedgePending();
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = position(s);
        s.shortConfirmed = !found ? int256(0) : (p.isLong ? -p.quantity.toInt256() : p.quantity.toInt256());
        s.pendingQty = 0;
        emit HedgeConfirmed(s.shortConfirmed);
    }

    /// @notice Confirm the short, then move it toward the target exposure in one market order if
    /// it has drifted past the band. Keeper any time; anyone else `publicHedgeDelay` after the last.
    /// @param restockOpen whether the issuer can be ordered from now: then the short tracks the
    /// target inventory and the issuer closes the gap; otherwise it tracks what the vault holds.
    /// @return ordered whether an order went out
    function syncHedge(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        bool restockOpen,
        bool isKeeper
    ) external returns (bool ordered) {
        confirmHedge(s);
        Reference memory r = storedReference(c, ctx);
        if (r.reason != Refusal.None) revert PriceNotUsable(r.reason);

        int256 gap = hedgeGap(c, s, ctx, r.price, restockOpen && !r.closed);
        uint256 mag = abs(gap);
        if (unitsToCash(ctx, mag, r.price) < c.hedgeBand) return false;
        if (!isKeeper && block.timestamp < uint256(s.lastHedgeTime) + c.publicHedgeDelay) {
            revert HedgeTooSoon(uint256(s.lastHedgeTime) + c.publicHedgeDelay);
        }
        bool sell = gap > 0;
        uint256 qty = mag / c.qtyTick * c.qtyTick;
        // A buy only ever reduces a short; it never opens a long.
        // forge-lint: disable-next-line(unsafe-typecast) - sign tested.
        if (!sell) qty = Math.min(qty, s.shortConfirmed > 0 ? uint256(s.shortConfirmed) : 0);
        if (qty == 0 || unitsToCash(ctx, qty, r.price) < c.minHedge) return false;

        uint256 worst = sell
            ? r.price * (BPS - c.hedgeSlippageBps) / BPS / c.priceTick * c.priceTick
            : Math.ceilDiv(Math.mulDiv(r.price, BPS + c.hedgeSlippageBps, BPS, Math.Rounding.Ceil), c.priceTick)
                * c.priceTick;
        uint256 margin = sell ? Math.mulDiv(qty, worst, 1e18) * 10 / c.leverageX10 : 0;
        // The margin hold also covers the taker fee; 1% over is far above any fee tier.
        if (margin != 0) spendOwnCash(s, ctx, fromApi(ctx, margin, Math.Rounding.Ceil) * 101 / 100 + 1);

        string memory sub = subaccount();
        string memory orderHash =
            EXCHANGE.createDerivativeMarketOrder(
            address(this),
            IExchangeDerivatives.DerivativeOrder({
                marketID: s.marketId,
                subaccountID: sub,
                feeRecipient: "",
                price: worst,
                quantity: qty,
                cid: "",
                orderType: sell ? "sell" : "buy",
                margin: margin,
                triggerPrice: 0
            })
        )
        .orderHash;
        s.hedgeBlock = uint64(block.number);
        s.lastHedgeTime = uint64(block.timestamp);
        s.pendingQty = sell ? qty.toInt256() : -qty.toInt256();
        emit HedgeOrdered(sell, qty, worst, margin, orderHash);
        return true;
    }

    /// @notice The short the vault should add (positive) or cover (negative), 1e18 units, against
    /// the confirmed short.
    function hedgeGap(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        uint256 price,
        bool restockOpen
    ) internal view returns (int256) {
        uint256 units = toUnits(s.stockBooked, ctx.stockDecimals);
        if (s.orderOpen) units += toUnits(s.orderMinOut, ctx.stockDecimals);
        if (restockOpen) {
            uint256 held = stockToCash(ctx, s.stockBooked, price, Math.Rounding.Floor) + (s.orderOpen ? s.orderCash : 0);
            if (c.targetInventory > held) {
                uint256 used = block.timestamp >= uint256(s.restockWindowStart) + RESTOCK_CAP_WINDOW ? 0 : s.restockUsed;
                uint256 room = c.restockDailyCap > used ? c.restockDailyCap - used : 0;
                // Never short more than `maxUnhedged` ahead of what is held, whatever the target:
                // if the restock never comes, that is the exposure left.
                uint256 gapCash = Math.min(Math.min(c.targetInventory - held, room), c.maxUnhedged);
                units += cashToUnits(ctx, gapCash, price);
            }
        }
        return units.toInt256() - s.shortConfirmed;
    }

    /// @notice Bring the short back to its target leverage once its margin is below 70% of what
    /// that leverage needs. Permissionless: it only adds the vault's own cash to its own position.
    function topUpMargin(StockConfig storage c, StockState storage s, StockContext memory ctx) external {
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = position(s);
        if (!found) revert MarginHealthy();
        uint256 target = Math.mulDiv(p.quantity, markPrice(ctx), 1e18) * 10 / c.leverageX10;
        if (p.margin * 10 >= target * 7) revert MarginHealthy();
        uint256 amount = target - p.margin;
        spendOwnCash(s, ctx, fromApi(ctx, amount, Math.Rounding.Ceil) + 1);
        string memory sub = subaccount();
        EXCHANGE.increasePositionMargin(address(this), sub, sub, s.marketId, amount);
        emit MarginAdded(amount);
    }

    // -------------------------------------------------------------------------------------
    // Value
    // -------------------------------------------------------------------------------------

    /// @notice Cash, plus the booked stock (never more than is held) at the stored price, plus the
    /// short at margin plus PnL, plus the cash of an open restock order. What the vault holds for
    /// fixing-lane requesters is not its own and is left out. ⚠️ Funding reaches the margin only
    /// when it settles; deposits and withdrawals settle it first.
    function value(StockState storage s, StockContext memory ctx) external view returns (uint256 total) {
        uint256 price = markPrice(ctx);
        total = ownCash(s, ctx) + (s.orderOpen ? s.orderCash : 0);
        total += stockToCash(ctx, Math.min(s.stockBooked, ownStock(s, ctx)), price, Math.Rounding.Floor);
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = position(s);
        if (found) total += positionValue(ctx, p, price);
    }

    /// @notice Revert unless a deposit, withdrawal or restock may act on `r`: the market open for
    /// this vault and the price fresh.
    function requireUsable(Reference memory r) internal pure {
        if (r.reason != Refusal.None) revert PriceNotUsable(r.reason);
        if (r.closed) revert PriceNotUsable(Refusal.Closed);
    }

    // -------------------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------------------

    function checkConfig(StockConfig memory c) external pure {
        if (c.maxSpread > MAX_SPREAD_LIMIT || c.minSpread == 0 || c.minSpread > c.maxSpread) revert BadConfig();
        if (
            c.spreadRegular > c.maxSpread || c.spreadExtended > c.maxSpread || c.spreadOvernight > c.maxSpread
                || c.spreadClosed > c.maxSpread
        ) revert BadConfig();
        // The lean must stay inside the spread, so neither side ever crosses the reference.
        if (c.skewBps >= c.minSpread) revert BadConfig();
        if (c.maxJumpBps == 0 || c.maxJumpBps > MAX_JUMP_LIMIT) revert BadConfig();
        if (c.hedgeSlippageBps > MAX_HEDGE_SLIPPAGE || c.restockSlippageBps > MAX_RESTOCK_SLIPPAGE) revert BadConfig();
        if (c.navJumpBps == 0 || c.navJumpBps > MAX_NAV_JUMP) revert BadConfig();
        if (c.leverageX10 < MIN_LEVERAGE_X10 || c.leverageX10 > MAX_LEVERAGE_X10) revert BadConfig();
        if (c.maxAgeMs == 0 || c.maxAgeMs > MAX_AGE_MS_LIMIT || c.closeTolerance > MAX_CLOSE_TOLERANCE) {
            revert BadConfig();
        }
        if (c.window < MIN_WINDOW || c.reanchorDelay < MIN_REANCHOR_DELAY) revert BadConfig();
        if (c.restockDeadline == 0 || c.restockDeadline > MAX_RESTOCK_DEADLINE) revert BadConfig();
        if (c.targetInventory > c.maxInventory || c.qtyTick == 0 || c.priceTick == 0) revert BadConfig();
    }

    // -------------------------------------------------------------------------------------
    // Helpers (inlined into whichever side calls them)
    // -------------------------------------------------------------------------------------

    function windowUsedNow(StockConfig storage c, StockState storage s) internal view returns (uint256) {
        return block.timestamp >= uint256(s.windowStart) + c.window ? 0 : s.windowUsed;
    }

    /// @dev The stored price for valuation: any age, but it must exist.
    function markPrice(StockContext memory ctx) internal view returns (uint256 price) {
        IPriceStore.Price memory p = ctx.store.latest(ctx.feedId);
        price = toWad(p.price, p.exponent);
        if (price == 0) revert OracleMissing();
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

    /// @notice The cash held less what is held for fixing-lane requesters.
    function ownCash(StockState storage s, StockContext memory ctx) internal view returns (uint256) {
        uint256 h = holding(ctx, ctx.cash);
        return h > s.cashOwed ? h - s.cashOwed : 0;
    }

    /// @notice The stock held less what is held for fixing-lane requesters.
    function ownStock(StockState storage s, StockContext memory ctx) internal view returns (uint256) {
        uint256 h = holding(ctx, ctx.stock);
        return h > s.stockOwed ? h - s.stockOwed : 0;
    }

    /// @dev Make `amount` of cash available as the token for the vault to spend, refusing to dip
    /// into what it holds for fixing-lane requesters.
    function spendOwnCash(StockState storage s, StockContext memory ctx, uint256 amount) internal {
        uint256 own = ownCash(s, ctx);
        if (own < amount) revert CashShort(amount, own);
        ensureToken(ctx, ctx.cash, amount);
    }

    function position(StockState storage s)
        internal
        view
        returns (bool, IExchangeDerivatives.DerivativePosition memory p)
    {
        IExchangeDerivatives.DerivativePosition[] memory all = EXCHANGE.subaccountPositions(subaccount());
        bytes32 h = keccak256(bytes(s.marketId));
        for (uint256 k; k < all.length; ++k) {
            if (keccak256(bytes(all[k].marketID)) == h) return (true, all[k]);
        }
        return (false, p);
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

    /// @notice The vault's default exchange subaccount, which trades off its bank balance.
    function subaccount() internal view returns (string memory) {
        return SubaccountLib.defaultSubaccount(address(this));
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
    function ensureToken(StockContext memory ctx, Currency currency, uint256 amount) internal {
        uint256 bal = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal < amount) lock(ctx, OP_FROM_CLAIMS, currency, amount - bal);
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

    function _refuse(Fill memory f, Refusal reason) private pure returns (Fill memory) {
        f.reason = reason;
        f.amountIn = 0;
        f.amountOut = 0;
        return f;
    }
}
