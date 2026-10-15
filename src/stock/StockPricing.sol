// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {StockLib} from "./StockLib.sol";
import {Fill, Reference, Refusal, StockConfig, StockContext, StockState, SwapRequest} from "./StockTypes.sol";

/// @title StockPricing
/// @notice A `StockVault`'s instant-lane pricing: the fill for a swap or the reason there is none, the
/// spread, every guard, and the jump breaker's anchor. Its external functions run by DELEGATECALL, as
/// the vault.
library StockPricing {
    using SafeCast for uint256;
    using SafeCast for int256;

    event Anchored(uint256 price);
    event JumpSeen(uint256 price, uint256 anchor);
    event Reanchored(uint256 price, uint256 wideUntil);
    event JumpHalted(uint256 price, uint256 anchor);

    error NoActionPending();
    error BadRatio(uint256 ratio, uint256 announced);
    error ActionMove(uint256 price, uint256 anchor);

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
        if (s.paused & StockLib.PAUSE_FILLS != 0) return _refuse(f, Refusal.Paused);
        if (!s.poolRegistered) return _refuse(f, Refusal.Disabled);
        Reference memory r = StockLib.referencePrice(c, ctx, pickPrice(ctx, hookData));
        f.price = r.price;
        f.closed = r.closed;
        if (r.reason != Refusal.None) return _refuse(f, r.reason);
        if (r.closed && !c.weekendFills) return _refuse(f, Refusal.Closed);
        if (s.anchorPrice != 0 && StockLib.deviationBps(r.price, s.anchorPrice) > c.maxJumpBps) {
            return _refuse(f, Refusal.Jump);
        }
        if (StockLib.ownStock(s, ctx) < s.stockBooked) return _refuse(f, Refusal.Deficit);

        uint256 scale = 10 ** (uint256(ctx.stockDecimals) + 18 - ctx.cashDecimals);
        (uint256 maxTrade, uint256 windowCap) =
            r.closed ? (uint256(c.maxTradeClosed), uint256(c.windowCapClosed)) : (c.maxTrade, c.windowCap);
        uint256 used = StockLib.windowUsedNow(c, s);
        {
            // The size terms read the trade at the reference price, before the spread is known.
            uint256 cashEstimate = w.cashIn == w.exactInput ? w.amount : Math.mulDiv(w.amount, r.price, scale);
            f.spreadBps = spread(c, s, r, cashEstimate, used, maxTrade, windowCap);
        }
        if (f.spreadBps > c.maxSpread) return _refuse(f, Refusal.Spread);

        int256 lean = skew(c, s, ctx, r.price);
        if (w.cashIn) {
            // forge-lint: disable-next-line(unsafe-typecast) - |lean| < minSpread <= spread.
            uint256 up = uint256(int256(StockLib.BPS + f.spreadBps) + lean);
            uint256 ask = Math.mulDiv(r.price, up, StockLib.BPS, Math.Rounding.Ceil);
            (f.amountIn, f.amountOut) = w.exactInput
                ? (w.amount, Math.mulDiv(w.amount, scale, ask))
                : (Math.mulDiv(w.amount, ask, scale, Math.Rounding.Ceil), w.amount);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast) - |lean| < minSpread <= spread < StockLib.BPS.
            uint256 bid = r.price * uint256(int256(StockLib.BPS - f.spreadBps) + lean) / StockLib.BPS;
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
        uint256 outValue = w.cashIn ? StockLib.stockToCash(ctx, f.amountOut, f.price, Math.Rounding.Ceil) : f.amountOut;
        if (used + outValue > windowCap) return Refusal.Window;
        // Fills pay out of claims only.
        if (ctx.vault.balanceOf(address(this), w.cashIn ? ctx.stock : ctx.cash) < f.amountOut) {
            return Refusal.Inventory;
        }
        if (w.cashIn && f.amountOut > s.stockBooked) return Refusal.Inventory;
        uint256 bookedAfter = w.cashIn ? s.stockBooked - f.amountOut : s.stockBooked + f.amountIn;
        if (!w.cashIn) {
            uint256 inventoryAfter = StockLib.stockInventory(s) + f.amountIn;
            if (StockLib.stockToCash(ctx, inventoryAfter, f.price, Math.Rounding.Ceil) > c.maxInventory) {
                return Refusal.InventoryCap;
            }
            // The cash left must cover the reserve plus the margin to hedge what comes in.
            uint256 margin = StockLib.stockToCash(ctx, f.amountIn, f.price, Math.Rounding.Ceil) * 10 / c.leverageX10;
            if (StockLib.ownCash(s, ctx) < f.amountOut + StockLib.cashKept(c, s) + margin) return Refusal.Reserve;
        }
        if (_widensExposure(c, s, ctx, bookedAfter, f.price)) return Refusal.Unhedged;
        if (!withinLimit(w.zeroForOne, f.amountIn, f.amountOut, w.sqrtPriceLimitX96)) return Refusal.PriceLimit;
        return Refusal.None;
    }

    /// @dev Exposure may grow only up to `maxUnhedged`, judged against the confirmed short and
    /// against the short a pending hedge, or what may still fill of a resting maker order, would
    /// leave: until it is read back, it might not have filled, and it might have. (A market hedge
    /// cancels any maker order first, so at most one of the two is ever open.)
    function _widensExposure(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        uint256 bookedAfter,
        uint256 price
    ) internal view returns (bool) {
        // In share units, the perp's: the short is in shares, the stock in tokens.
        uint256 inTransit = s.orderOpen ? s.orderStock : 0;
        int256 before = _shares(ctx, s.stockBooked + inTransit);
        int256 next = _shares(ctx, bookedAfter + inTransit);
        int256 resting = s.makerSell ? s.makerFillable.toInt256() : -s.makerFillable.toInt256();
        uint256 sharePrice = Math.mulDiv(price, ctx.tokenPerShare, StockLib.RATIO_ONE);
        for (uint256 k; k < 2; ++k) {
            int256 short_ = k == 0 ? s.shortConfirmed : s.shortConfirmed + s.pendingQty + resting;
            uint256 b = StockLib.abs(before - short_);
            uint256 a = StockLib.abs(next - short_);
            if (a > b && StockLib.unitsToCash(ctx, a, sharePrice) > c.maxUnhedged) return true;
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
        uint256 held = StockLib.stockToCash(ctx, s.stockBooked, price, Math.Rounding.Floor);
        int256 bps = StockLib.BPS.toInt256();
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
    /// a signed price, and only slowly across a jump. A jump past `MAX_ACTION_MOVE` is never
    /// followed: it is what a split looks like when the feed moves before the ratio registry does,
    /// so it halts the vault for the owner's `acceptAction`, as an announced ratio would.
    function poke(StockConfig storage c, StockState storage s, StockContext storage ctx) external {
        Reference memory r = StockLib.storedReference(c, ctx);
        if (r.reason != Refusal.None || r.closed) revert StockLib.PriceNotUsable(r.reason);
        uint256 move = s.anchorPrice == 0 ? 0 : StockLib.deviationBps(r.price, s.anchorPrice);
        if (move > StockLib.MAX_ACTION_MOVE) {
            ctx.actionHalt = true;
            emit JumpHalted(r.price, s.anchorPrice);
        } else if (move <= c.maxJumpBps) {
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

    /// @notice Apply an accepted corporate action: the new ratio (in range, and the registry's if there
    /// is one), and the anchor moved to the stored price at it in the same call, with the re-anchor
    /// widen. The halt is the owner's review; the stored price may be of any age (a split usually
    /// lands over a weekend). The price per token at the new ratio must be within `maxMoveBps` (at most
    /// `MAX_ACTION_MOVE`) of the anchor: across a split it should not have moved at all, so a ratio
    /// accepted before the feed reflects it is refused. When the market really has moved further than
    /// that while halted (a merger, a gap on news), the owner states the per-token price it expects
    /// (`expectedPrice`, 1e18) and the check is against that instead, so no move strands the halt.
    function acceptAction(
        StockConfig storage c,
        StockState storage s,
        StockContext storage ctx,
        uint56 ratio,
        uint16 maxMoveBps,
        uint256 expectedPrice
    ) external {
        if (!StockLib.actionPending(ctx)) revert NoActionPending();
        uint256 announced =
            address(ctx.ratios) == address(0) ? ratio : ctx.ratios.tokenPerShare(Currency.unwrap(ctx.stock));
        if (ratio < StockLib.MIN_RATIO || ratio > StockLib.MAX_RATIO || ratio != announced) {
            revert BadRatio(ratio, announced);
        }
        ctx.tokenPerShare = ratio;
        ctx.actionHalt = false;
        uint256 price = StockLib.markPrice(ctx);
        uint256 against = expectedPrice != 0 ? expectedPrice : s.anchorPrice;
        if (against == 0 || maxMoveBps > StockLib.MAX_ACTION_MOVE || StockLib.deviationBps(price, against) > maxMoveBps)
        revert ActionMove(price, against);
        s.anchorPrice = price.toUint128();
        s.jumpSince = 0;
        s.wideUntil = uint64(block.timestamp + c.reanchorWide);
        emit Reanchored(price, s.wideUntil);
    }

    function _shares(StockContext memory ctx, uint256 amount) private pure returns (int256) {
        return StockLib.toShares(ctx, StockLib.toUnits(amount, ctx.stockDecimals)).toInt256();
    }

    function _refuse(Fill memory f, Refusal reason) private pure returns (Fill memory) {
        f.reason = reason;
        f.amountIn = 0;
        f.amountOut = 0;
        return f;
    }
}
