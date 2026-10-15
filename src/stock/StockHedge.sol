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
    error NoMarket();

    event HedgeOrdered(bool sell, uint256 quantity, uint256 worstPrice, uint256 margin, string orderHash);
    event MakerPlaced(bool sell, uint256 quantity, uint256 price, uint256 margin, string orderHash);
    event MakerCancelled(string orderHash, uint256 fillableLeft);
    event HedgeConfirmed(int256 shortQty);
    event MarginAdded(uint256 amount);

    // -------------------------------------------------------------------------------------
    // Hedge
    // -------------------------------------------------------------------------------------

    /// @notice Read the short back from the position: the truth a pending order is judged against.
    /// A resting maker order is read back too: what may still fill, or cleared once it is gone.
    function confirmHedge(StockState storage s) public {
        if (s.hedgeBlock == block.number) revert HedgePending();
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = StockLib.position(s);
        s.shortConfirmed = !found ? int256(0) : (p.isLong ? -p.quantity.toInt256() : p.quantity.toInt256());
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
        if (bytes(s.makerHash).length != 0) {
            _requireMakerReplaceable(c, s, isKeeper);
            _cancelMaker(s);
        }
        Reference memory r = StockLib.storedReference(c, ctx);
        if (r.reason != Refusal.None) revert StockLib.PriceNotUsable(r.reason);

        (bool sell, uint256 qty) = _hedgeOrder(c, s, ctx, r, restockOpen);
        if (qty == 0) return false;
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
        uint256 margin = _holdMargin(c, s, ctx, sell, qty, worst, r.sharePrice);

        string memory sub = StockLib.subaccount();
        string memory orderHash =
            StockLib.EXCHANGE
        .createDerivativeMarketOrder(
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
        confirmHedge(s);
        if (bytes(s.makerHash).length != 0) _cancelMaker(s);
        Reference memory r = StockLib.storedReference(c, ctx);
        if (r.reason != Refusal.None) revert StockLib.PriceNotUsable(r.reason);

        (bool sell, uint256 qty) = _hedgeOrder(c, s, ctx, r, restockOpen);
        if (qty == 0) return false;
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
    function cancelMaker(StockConfig storage c, StockState storage s, bool isKeeper) external {
        if (bytes(s.makerHash).length == 0) revert NoMaker();
        _requireMakerReplaceable(c, s, isKeeper);
        confirmHedge(s);
        if (bytes(s.makerHash).length != 0) _cancelMaker(s);
    }

    /// @dev The order that would bring the short to target: which way, and how much in shares, rounded
    /// to the tick; zero inside the band or under the minimum. A buy only ever reduces a short.
    function _hedgeOrder(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        Reference memory r,
        bool restockOpen
    ) private view returns (bool sell, uint256 qty) {
        int256 gap = StockLib.hedgeGap(c, s, ctx, r.price, restockOpen && !r.closed);
        uint256 mag = StockLib.abs(gap);
        if (StockLib.unitsToCash(ctx, mag, r.sharePrice) < c.hedgeBand) return (false, 0);
        sell = gap > 0;
        qty = mag / c.qtyTick * c.qtyTick;
        // forge-lint: disable-next-line(unsafe-typecast) - sign tested.
        if (!sell) qty = Math.min(qty, s.shortConfirmed > 0 ? uint256(s.shortConfirmed) : 0);
        if (qty == 0 || StockLib.unitsToCash(ctx, qty, r.sharePrice) < c.minHedge) qty = 0;
    }

    /// @dev An opening order's margin, made available out of the vault's own cash; a reducing order
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
        if (!sell) return 0;
        margin = Math.mulDiv(qty, Math.max(price, mark), 1e18) * 10 / c.leverageX10;
        if (mark > price) margin += Math.mulDiv(qty, mark - price, 1e18, Math.Rounding.Ceil);
        // The margin hold also covers the fee; 1% over is far above any fee tier.
        StockLib.spendOwnCash(s, ctx, StockLib.fromApi(ctx, margin, Math.Rounding.Ceil) * 101 / 100 + 1);
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

    /// @notice The short to add (positive) or cover (negative) to reach the target now, in shares.
    function gapNow(StockConfig storage c, StockState storage s, StockContext memory ctx, bool restockOpen)
        external
        view
        returns (int256)
    {
        return StockLib.hedgeGap(c, s, ctx, StockLib.markPrice(ctx), restockOpen);
    }

    /// @notice Point the vault at a new perp market, as when the old one is settled ahead of a split:
    /// only during a corporate-action halt, and only with nothing open on the old one.
    function migrateMarket(StockState storage s, StockContext memory ctx, string calldata marketId) external {
        if (!StockLib.actionPending(ctx)) revert NoActionPending();
        (bool found,) = StockLib.position(s);
        if (found || s.pendingQty != 0 || s.shortConfirmed != 0 || bytes(s.makerHash).length != 0) revert HedgeOpen();
        if (bytes(marketId).length == 0) revert NoMarket();
        s.marketId = marketId;
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
        StockLib.spendOwnCash(s, ctx, StockLib.fromApi(ctx, amount, Math.Rounding.Ceil) + 1);
        string memory sub = StockLib.subaccount();
        if (!StockLib.EXCHANGE.increasePositionMargin(address(this), sub, sub, s.marketId, amount)) {
            revert ExchangeRefused();
        }
        emit MarginAdded(amount);
    }

    // -------------------------------------------------------------------------------------
    // Value
    // -------------------------------------------------------------------------------------

    /// @notice Cash, plus the booked stock (never more than is held) at the stored price, plus the
    /// short at margin plus PnL, plus an open restock order (a buy's cash, a sell's stock), plus the margin a resting
    /// maker order still holds (not its fee hold, which is small and may be a rebate). What the
    /// vault holds for fixing-lane requesters, and what it owes an in-kind redeem epoch, is not its
    /// own and is left out. ⚠️ Funding reaches the margin only
    /// when it settles; deposits and withdrawals settle it first.
    function value(StockState storage s, StockContext memory ctx) external view returns (uint256 total) {
        uint256 price = StockLib.markPrice(ctx);
        total = StockLib.ownCash(s, ctx) + StockLib.orderValue(s, ctx, price);
        total += StockLib.stockToCash(
            ctx, Math.min(s.stockBooked, StockLib.ownStock(s, ctx)), price, Math.Rounding.Floor
        );
        (bool found, IExchangeDerivatives.DerivativePosition memory p) = StockLib.position(s);
        if (found) total += StockLib.positionValue(ctx, p, StockLib.markSharePrice(ctx));
        if (bytes(s.makerHash).length != 0) {
            // The margin still held by what may fill; a filled part's margin is in the position.
            (bool live, IExchangeDerivatives.TrimmedDerivativeLimitOrder memory o) = StockLib.makerOrder(s);
            if (live && o.quantity != 0) {
                total += StockLib.fromApi(ctx, Math.mulDiv(o.margin, o.fillable, o.quantity), Math.Rounding.Floor);
            }
        }
        // An in-kind redeem epoch's unpaid debt is not the vault's, though the cash for it still is.
        total = total > s.debtOwed ? total - s.debtOwed : 0;
    }
}
