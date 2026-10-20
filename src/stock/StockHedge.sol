// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IExchangeDerivatives} from "../interfaces/IExchangeDerivatives.sol";
import {StockLib} from "./StockLib.sol";
import {Reference, Refusal, StockConfig, StockContext, StockState} from "./StockTypes.sol";

/// @title StockHedge
/// @notice A `StockVault`'s short and its value: reading the position back, market and maker hedges
/// toward the target, margin top-ups, and what the vault is worth. Its external functions run by
/// DELEGATECALL, as the vault: the perp position they trade is the vault's.
///
/// The short trades from the vault's hedge subaccount (`StockLib.HEDGE_NONCE`), which holds a deposit of
/// its own: each order or top-up first leaves exactly what it needs available there, depositing the
/// shortfall from the vault's booked cash or bringing the rest back to the bank, and a confirmation
/// brings back whatever is free. Cash crosses between the bank and the subaccount only here, booked
/// both ways.
library StockHedge {
    using SafeCast for uint256;
    using SafeCast for int256;

    error HedgePending();
    error HedgeTooSoon(uint256 allowedAt);
    error MarginHealthy();
    error ExchangeRefused();
    error MakerOff();
    error NoMaker();
    error MakerResting(uint256 replaceableAt);
    error MakerPriceOutOfBand(uint256 price, uint256 low, uint256 high);
    error NoActionPending();
    error HedgeOpen();
    error PositionReadable();
    error BadCover();

    event HedgeOrdered(bool sell, uint256 quantity, uint256 worstPrice, uint256 margin, string orderHash);
    event MakerPlaced(bool sell, uint256 quantity, uint256 price, uint256 margin, string orderHash);
    event MakerCancelled(string orderHash, uint256 fillableLeft);
    event HedgeConfirmed(int256 shortQty);
    event MarginAdded(uint256 amount);
    event PositionLost(int256 shortConfirmed);

    // -------------------------------------------------------------------------------------
    // Hedge
    // -------------------------------------------------------------------------------------

    /// @notice Read the short back from the position, then bring the subaccount's free cash back to the
    /// bank and into claims (best effort: if the exchange refuses, it stays there, still in the value).
    /// The cash comes back even when the position cannot be read. (`ctx` is the stored copy, read only
    /// when cash comes back.)
    function confirmHedge(StockState storage s, StockContext storage ctx) external {
        _confirm(s, false);
        (uint256 available,) = StockLib.subaccountCash(s);
        if (available == 0) return;
        try StockLib.EXCHANGE.withdraw(address(this), StockLib.subaccount(), s.cashDenom, available) returns (bool ok) {
            if (!ok) return;
            s.cashBooked += available;
        } catch {
            return;
        }
        StockLib.intoClaims(ctx, ctx.cash);
    }

    /// @dev Read the short back from the position: the truth a pending order is judged against. A
    /// resting maker order is read back too: what may still fill, or cleared once it is gone. A short
    /// found gone with no buy of the vault's that could have covered it marks the position lost. When
    /// the exchange cannot read the position (`StockLib.readPosition`), `strict` reverts and otherwise
    /// nothing is confirmed.
    function _confirm(StockState storage s, bool strict) private {
        if (s.hedgeBlock == block.number) revert HedgePending();
        (bool readable, bool found, IExchangeDerivatives.DerivativePosition memory p) = StockLib.readPosition(s);
        if (!readable) {
            if (strict) revert StockLib.PositionUnreadable();
            return;
        }
        if (!found && !StockLib.covered(s)) {
            s.positionLost = true;
            emit PositionLost(s.shortConfirmed);
        }
        s.shortConfirmed = found ? StockLib.signed(p) : int256(0);
        s.pendingQty = 0;
        if (bytes(s.makerHash).length != 0) {
            (bool live, IExchangeDerivatives.TrimmedDerivativeLimitOrder memory o) = StockLib.makerOrder(s);
            if (live) s.makerFillable = o.fillable;
            else _clearMaker(s);
        }
        emit HedgeConfirmed(s.shortConfirmed);
    }

    /// @notice Confirm the short, then move it toward the target exposure in one market order if
    /// it has drifted past the band. Keeper any time; anyone else `publicHedgeDelay` after the last.
    /// A resting maker order is cancelled first: by the keeper any time, by anyone once it has
    /// rested `makerTimeout`.
    /// @param restockOpen whether the issuer can be ordered from: then the short may run ahead of what
    /// the vault holds toward the target inventory, and the issuer closes the gap; otherwise it tracks
    /// what the vault holds. See `StockLib.hedgeGap`.
    /// @return ordered whether an order went out
    function syncHedge(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        bool restockOpen,
        bool isKeeper
    ) external returns (bool ordered) {
        _confirm(s, true);
        if (bytes(s.makerHash).length != 0) {
            _requireMakerReplaceable(c, s, isKeeper);
            _cancelMaker(s);
        }
        Reference memory r = StockLib.storedReference(c, ctx);
        if (r.reason != Refusal.None) revert StockLib.PriceNotUsable(r.reason);

        (bool sell, uint256 qty) = _hedgeOrder(c, s, ctx, r, restockOpen);
        if (qty == 0) {
            _fund(s, ctx, 0);
            return false;
        }
        if (!isKeeper && block.timestamp < uint256(s.lastHedgeTime) + c.publicHedgeDelay) {
            revert HedgeTooSoon(uint256(s.lastHedgeTime) + c.publicHedgeDelay);
        }

        // Anyone's hedge may cross at most the narrowest spread the vault charges, so moving the book
        // against it costs more than it can take; the keeper's may use the full slippage.
        uint256 slip = isKeeper ? c.hedgeSlippageBps : Math.min(c.hedgeSlippageBps, c.minSpread);
        uint256 worst = sell
            ? r.sharePrice * (StockLib.BPS - slip) / StockLib.BPS / c.priceTick * c.priceTick
            : Math.ceilDiv(
                    Math.mulDiv(r.sharePrice, StockLib.BPS + slip, StockLib.BPS, Math.Rounding.Ceil), c.priceTick
                ) * c.priceTick;
        _marketOrder(s, sell, qty, worst, _holdMargin(c, s, ctx, sell, qty, worst, r.sharePrice));
        return true;
    }

    /// @notice The way out when the exchange cannot read the position back (`StockLib.readPosition`):
    /// then nothing that needs the read works (no hedge, no value, no exit), and while the market's
    /// funding index stays negative no fill or margin move can make it readable again. A reduce-only
    /// market buy needs no read: the exchange cuts it to the short, so `qty` at least the short closes
    /// it, and with no position the read works again. `qty` must be at least the most the short can be
    /// (the last confirmed, a sell from an earlier block, a resting maker sell): the read is gone, and a
    /// cover asked for less could close it without the vault knowing. A resting maker order is cancelled
    /// first, so the cut leaves the whole short to this order. `worst` is on the tick and within
    /// `hedgeSlippageBps` above the mark. Hedging that adds to the short pauses (`PAUSE_HEDGE`) until the
    /// owner lifts it: on a negative index, the next sale would make the position unreadable again.
    function coverUnreadable(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        uint256 qty,
        uint256 worst
    ) external {
        if (s.hedgeBlock == block.number) revert HedgePending();
        (bool readable,,) = StockLib.readPosition(s);
        if (readable) revert PositionReadable();
        uint256 cap = Math.mulDiv(StockLib.markSharePrice(ctx), StockLib.BPS + c.hedgeSlippageBps, StockLib.BPS);
        uint256 most = (s.shortConfirmed > 0 ? StockLib.abs(s.shortConfirmed) : 0)
            + (s.pendingQty > 0 ? StockLib.abs(s.pendingQty) : 0) + (s.makerSell ? s.makerFillable : 0);
        if (qty < most || qty % c.qtyTick != 0 || worst > cap || worst % c.priceTick != 0) revert BadCover();
        if (bytes(s.makerHash).length != 0) {
            (bool live,) = StockLib.makerOrder(s);
            if (live) _cancelMaker(s);
            else _clearMaker(s);
        }
        _marketOrder(s, false, qty, worst, 0);
        s.paused |= StockLib.PAUSE_HEDGE;
    }

    function _marketOrder(StockState storage s, bool sell, uint256 qty, uint256 worst, uint256 margin) private {
        string memory orderHash =
            StockLib.EXCHANGE
        .createDerivativeMarketOrder(
            address(this),
            IExchangeDerivatives.DerivativeOrder({
                marketID: s.marketId,
                subaccountID: StockLib.subaccount(),
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
    }

    /// @notice Rest a post-only order at `price` for the same gap `syncHedge` would cross the book
    /// for, replacing any maker order already resting. The keeper picks the price, inside
    /// `hedgeSlippageBps` of the reference on either side and on the market's tick; post-only means
    /// it can only ever fill as maker, and an order that would cross reverts. Until it fills or is
    /// cancelled the vault's exposure is judged both with and without what may still fill.
    /// @return placed whether an order went out (false inside the band)
    function placeMaker(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        bool restockOpen,
        uint256 price
    ) external returns (bool placed) {
        if (c.makerTimeout == 0) revert MakerOff();
        _confirm(s, true);
        if (bytes(s.makerHash).length != 0) _cancelMaker(s);
        Reference memory r = StockLib.storedReference(c, ctx);
        if (r.reason != Refusal.None) revert StockLib.PriceNotUsable(r.reason);

        (bool sell, uint256 qty) = _hedgeOrder(c, s, ctx, r, restockOpen);
        if (qty == 0) {
            _fund(s, ctx, 0);
            return false;
        }
        uint256 low = r.sharePrice * (StockLib.BPS - c.hedgeSlippageBps) / StockLib.BPS;
        uint256 high = Math.mulDiv(r.sharePrice, StockLib.BPS + c.hedgeSlippageBps, StockLib.BPS, Math.Rounding.Ceil);
        if (price < low || price > high || price % c.priceTick != 0) revert MakerPriceOutOfBand(price, low, high);
        uint256 margin = _holdMargin(c, s, ctx, sell, qty, price, r.sharePrice);

        string memory orderHash =
            StockLib.EXCHANGE
        .createDerivativeLimitOrder(
            address(this),
            IExchangeDerivatives.DerivativeOrder({
                marketID: s.marketId,
                subaccountID: StockLib.subaccount(),
                feeRecipient: "",
                price: price,
                quantity: qty,
                cid: "",
                orderType: sell ? "sellPostOnly" : "buyPostOnly",
                margin: margin,
                triggerPrice: 0
            })
        )
        .orderHash;
        s.makerHash = orderHash;
        s.makerSell = sell;
        s.makerFillable = qty;
        s.makerPlacedAt = uint64(block.timestamp);
        emit MakerPlaced(sell, qty, price, margin, orderHash);
        return true;
    }

    /// @notice Cancel the resting maker order: the keeper any time, anyone once it has rested
    /// `makerTimeout` (so a stalled keeper cannot leave one resting at a stale price).
    function cancelMaker(StockConfig storage c, StockState storage s, StockContext memory ctx, bool isKeeper) external {
        if (bytes(s.makerHash).length == 0) revert NoMaker();
        _requireMakerReplaceable(c, s, isKeeper);
        _confirm(s, true);
        if (bytes(s.makerHash).length != 0) _cancelMaker(s);
        _fund(s, ctx, 0);
    }

    /// @dev The order that would bring the short to target: which way, and how much in shares, rounded
    /// to the tick; zero inside the band or under the minimum. A buy only ever reduces a short. The
    /// exchange checks its minimum notional at the ORDER price, which may be `hedgeSlippageBps` under the
    /// reference, so the minimum is judged there.
    function _hedgeOrder(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        Reference memory r,
        bool restockOpen
    ) private view returns (bool sell, uint256 qty) {
        int256 gap = StockLib.hedgeGap(c, s, ctx, r.price, restockOpen, r.closed, s.shortConfirmed);
        uint256 mag = StockLib.abs(gap);
        if (StockLib.unitsToCash(ctx, mag, r.sharePrice) < c.hedgeBand) return (false, 0);
        sell = gap > 0;
        if (sell && s.paused & StockLib.PAUSE_HEDGE != 0) return (sell, 0);
        qty = mag / c.qtyTick * c.qtyTick;
        // forge-lint: disable-next-line(unsafe-typecast) - sign tested.
        if (!sell) qty = Math.min(qty, s.shortConfirmed > 0 ? uint256(s.shortConfirmed) : 0);
        uint256 lowest = r.sharePrice * (StockLib.BPS - c.hedgeSlippageBps) / StockLib.BPS / c.priceTick * c.priceTick;
        if (qty == 0 || StockLib.unitsToCash(ctx, qty, lowest) < c.minHedge) qty = 0;
    }

    /// @dev An opening order's margin, made available in the hedge subaccount; a reducing order
    /// carries none (reduce-only). The exchange wants the initial margin at the order price AND at the
    /// mark, the latter less the PnL the order opens at; so it is sized at the higher of the two prices,
    /// plus, for a sell placed below the mark, the loss it opens at, `qty * (mark - price)`.
    function _holdMargin(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        bool sell,
        uint256 qty,
        uint256 price,
        uint256 mark
    ) private returns (uint256 margin) {
        if (sell) {
            margin = Math.mulDiv(qty, Math.max(price, mark), 1e18) * 10 / c.leverageX10;
            if (mark > price) margin += Math.mulDiv(qty, mark - price, 1e18, Math.Rounding.Ceil);
        }
        // The margin hold also covers the fee; 1% over is far above any fee tier.
        _fund(s, ctx, margin == 0 ? 0 : StockLib.fromApi(ctx, margin, Math.Rounding.Ceil) * 101 / 100 + 1);
    }

    /// @dev Leave exactly `need` (cash units) available in the hedge subaccount: deposit the shortfall
    /// out of the vault's own cash, or bring the rest back to the bank and into claims. Booked either way.
    function _fund(StockState storage s, StockContext memory ctx, uint256 need) private {
        (uint256 available,) = StockLib.subaccountCash(s);
        if (available == need) return;
        string memory sub = StockLib.subaccount();
        if (available < need) {
            uint256 amount = need - available;
            StockLib.spendOwnCash(s, ctx, amount);
            s.cashBooked -= amount;
            if (!StockLib.EXCHANGE.deposit(address(this), sub, s.cashDenom, amount)) revert ExchangeRefused();
        } else {
            uint256 amount = available - need;
            if (!StockLib.EXCHANGE.withdraw(address(this), sub, s.cashDenom, amount)) revert ExchangeRefused();
            s.cashBooked += amount;
            StockLib.intoClaims(ctx, ctx.cash);
        }
    }

    function _requireMakerReplaceable(StockConfig storage c, StockState storage s, bool isKeeper) private view {
        uint256 at = uint256(s.makerPlacedAt) + c.makerTimeout;
        if (!isKeeper && block.timestamp < at) revert MakerResting(at);
    }

    /// @dev Cancel the resting order, which `confirmHedge` has just seen live in this transaction.
    function _cancelMaker(StockState storage s) private {
        if (!StockLib.EXCHANGE
            .cancelDerivativeOrder(address(this), s.marketId, StockLib.subaccount(), s.makerHash, 1, "")) {
            revert ExchangeRefused();
        }
        emit MakerCancelled(s.makerHash, s.makerFillable);
        _clearMaker(s);
    }

    function _clearMaker(StockState storage s) private {
        delete s.makerHash;
        s.makerSell = false;
        s.makerFillable = 0;
        s.makerPlacedAt = 0;
    }

    /// @notice The short to add (positive) or cover (negative) to bring the position as the exchange
    /// has it now into range, in shares.
    function gapNow(StockConfig storage c, StockState storage s, StockContext memory ctx, bool restockOpen, bool closed)
        external
        view
        returns (int256)
    {
        return StockLib.hedgeGap(c, s, ctx, StockLib.markPrice(ctx), restockOpen, closed, StockLib.liveShort(s));
    }

    /// @notice Point the vault at a new perp market, with that market's ticks, as when the old one is
    /// settled ahead of a split: only during a corporate-action halt, only with nothing open on the old
    /// one, and only once the owner has accepted the NAV a vanished short left (a forced settlement
    /// marks the position lost: so does a market merely paused, whose short would still be there).
    function migrateMarket(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        string calldata marketId,
        uint64 qtyTick,
        uint64 priceTick
    ) external {
        if (!StockLib.actionPending(ctx)) revert NoActionPending();
        (bool found,) = StockLib.position(s);
        if (found || s.positionLost || s.pendingQty != 0 || s.shortConfirmed != 0 || bytes(s.makerHash).length != 0) {
            revert HedgeOpen();
        }
        StockLib.requireMarketId(marketId);
        if (qtyTick == 0 || priceTick == 0) revert StockLib.BadConfig();
        s.marketId = marketId;
        (c.qtyTick, c.priceTick) = (qtyTick, priceTick);
    }

    /// @notice Settle the short's accrued funding into its margin with a one-unit margin decrease, kept
    /// only if the exchange can still read the position after it. Only the vault calls it, on itself,
    /// so that a revert undoes the decrease: see `StockOps.beforeNav`.
    function settleFunding(StockState storage s) external {
        string memory sub = StockLib.subaccount();
        StockLib.EXCHANGE.decreasePositionMargin(address(this), sub, sub, s.marketId, 1);
        StockLib.position(s);
    }

    /// @notice Bring the short back to its target leverage: its equity (margin plus unrealised PnL,
    /// which the exchange liquidates on) back up to what that leverage needs at the mark. The keeper
    /// may top up whenever equity is short of the target; anyone once it is below 70% of it. It only
    /// adds the vault's own cash to its own position.
    function topUpMargin(StockConfig storage c, StockState storage s, StockContext memory ctx, bool isKeeper) external {
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = StockLib.position(s);
        if (!found) revert MarginHealthy();
        uint256 mark = StockLib.markSharePrice(ctx);
        uint256 target = Math.mulDiv(p.quantity, mark, 1e18) * 10 / c.leverageX10;
        int256 move = p.isLong ? mark.toInt256() - p.entryPrice.toInt256() : p.entryPrice.toInt256() - mark.toInt256();
        int256 eq = p.margin.toInt256() + move * p.quantity.toInt256() / 1e18;
        // forge-lint: disable-next-line(unsafe-typecast) - positive by the test.
        uint256 equity = eq <= 0 ? 0 : uint256(eq);
        if (isKeeper ? equity >= target : equity * 10 >= target * 7) revert MarginHealthy();
        uint256 amount = target - equity;
        _fund(s, ctx, StockLib.fromApi(ctx, amount, Math.Rounding.Ceil) + 1);
        string memory sub = StockLib.subaccount();
        if (!StockLib.EXCHANGE.increasePositionMargin(address(this), sub, sub, s.marketId, amount)) {
            revert ExchangeRefused();
        }
        emit MarginAdded(amount);
    }

    // -------------------------------------------------------------------------------------
    // Value
    // -------------------------------------------------------------------------------------

    /// @notice The booked cash, plus the booked stock (never more than is held) at the stored price,
    /// plus an open restock order's stock, plus the hedge subaccount's cash (a resting maker order's
    /// margin hold included, the unit the subaccount always keeps left out: `StockLib.subaccountCash`),
    /// plus the short at margin plus PnL. Cash that arrived unbooked, what the vault holds for fixing-lane
    /// requesters and redeemers, and what it owes an in-kind redeem epoch, are left out. ⚠️ Funding
    /// reaches the margin only when it settles; deposits and withdrawals settle it first.
    function value(StockState storage s, StockContext memory ctx) external view returns (uint256 total) {
        uint256 price = StockLib.markPrice(ctx);
        total = StockLib.ownCash(s, ctx) + StockLib.orderValue(s, ctx, price);
        total += StockLib.stockToCash(
            ctx, Math.min(s.stockBooked, StockLib.ownStock(s, ctx)), price, Math.Rounding.Floor
        );
        (, uint256 held) = StockLib.subaccountCash(s);
        total += held;
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = StockLib.position(s);
        if (found) total += StockLib.positionValue(ctx, p, StockLib.markSharePrice(ctx));
        // An in-kind redeem epoch's unpaid debt is not the vault's, though the cash for it still is.
        total = total > s.debtOwed ? total - s.debtOwed : 0;
    }
}
