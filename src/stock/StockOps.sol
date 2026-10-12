// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {StockLib} from "./StockLib.sol";
import {Fill, StockConfig, StockContext, StockState, SwapRequest} from "./StockTypes.sol";

/// @title StockOps
/// @notice A `StockVault`'s bookkeeping: what a fill changes, the restock order's life, and the
/// checks before a deposit or withdrawal prices shares. Like `StockLib`, its external functions run
/// by DELEGATECALL, as the vault.
library StockOps {
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;

    error NavNotReady();
    error IsPaused(uint8 flag);
    error NavJump(uint256 sharePrice, uint256 last);
    error RestockUnavailable();
    error RestockCapExceeded(uint256 wanted, uint256 remaining);
    error MinOutTooLow(uint256 minOutValue, uint256 floor);
    error IssuerTransferFailed();
    error NotDelivered(uint256 surplus, uint256 minOut);
    error OrderOpen();

    event Filled(
        address indexed sender,
        bool cashIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 price,
        uint256 spreadBps,
        bool closed
    );
    event RestockOrdered(uint256 cash, uint256 minStockOut, uint64 deadline);
    event Restocked(uint256 cash, uint256 stock);
    event RestockExpired(uint256 cash);
    event Windfall(uint256 stock);

    // -------------------------------------------------------------------------------------
    // Fills
    // -------------------------------------------------------------------------------------

    /// @notice Settle a priced fill in claims and book it: the input minted to the vault, the output
    /// burned from its claims, the stock ledger, the outflow window, and the anchor (a fill on a
    /// live price is a fresh anchor; a frozen weekend price is not).
    function applyFill(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        address sender,
        SwapRequest memory w,
        Fill memory f
    ) external {
        (Currency cIn, Currency cOut) = w.cashIn ? (ctx.cash, ctx.stock) : (ctx.stock, ctx.cash);
        ctx.vault.mint(address(this), cIn, f.amountIn);
        ctx.vault.burn(address(this), cOut, f.amountOut);

        s.stockBooked = w.cashIn ? s.stockBooked - f.amountOut : s.stockBooked + f.amountIn;
        uint256 outValue = w.cashIn ? StockLib.stockToCash(ctx, f.amountOut, f.price, Math.Rounding.Ceil) : f.amountOut;
        if (block.timestamp >= uint256(s.windowStart) + c.window) {
            s.windowStart = uint64(block.timestamp);
            s.windowUsed = 0;
        }
        s.windowUsed += outValue.toUint96();
        if (!f.closed) {
            s.anchorPrice = f.price.toUint128();
            s.jumpSince = 0;
        }
        emit Filled(sender, w.cashIn, f.amountIn, f.amountOut, f.price, f.spreadBps, f.closed);
    }

    // -------------------------------------------------------------------------------------
    // Restock (tracked memo orders, buy only)
    // -------------------------------------------------------------------------------------

    /// @notice Send `cash` to `issuer` with `memo` appended after the transfer's arguments (the
    /// issuer's order format), expecting at least `minStockOut` back by the deadline. One order at a
    /// time, within the daily cap, only while the market is open, and with a minimum worth at least
    /// the reference price less `restockSlippageBps`.
    function restock(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        address issuer,
        bool restockOpen,
        uint256 cash,
        uint256 minStockOut,
        bytes calldata memo
    ) external {
        if (!restockOpen || s.orderOpen) revert RestockUnavailable();
        requireNavPrice(c, ctx);
        uint256 floor = cash * (BPS - c.restockSlippageBps) / BPS;
        uint256 minValue = StockLib.stockToCash(ctx, minStockOut, StockLib.markPrice(ctx), Math.Rounding.Floor);
        if (minValue < floor) revert MinOutTooLow(minValue, floor);
        if (block.timestamp >= uint256(s.restockWindowStart) + StockLib.RESTOCK_CAP_WINDOW) {
            s.restockWindowStart = uint64(block.timestamp);
            s.restockUsed = 0;
        }
        uint256 remaining = c.restockDailyCap > s.restockUsed ? c.restockDailyCap - s.restockUsed : 0;
        if (cash > remaining) revert RestockCapExceeded(cash, remaining);
        s.restockUsed += cash.toUint96();

        StockLib.spendOwnCash(s, ctx, cash);
        s.orderOpen = true;
        s.orderCash = cash.toUint96();
        s.orderMinOut = minStockOut.toUint128();
        s.orderDeadline = uint64(block.timestamp + c.restockDeadline);
        address token = Currency.unwrap(ctx.cash);
        (bool ok, bytes memory ret) =
            token.call(abi.encodePacked(abi.encodeCall(IERC20.transfer, (issuer, cash)), memo));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert IssuerTransferFailed();
        emit RestockOrdered(cash, minStockOut, s.orderDeadline);
    }

    /// @notice Book the open order's delivery: every unbooked stock the vault holds, once it reaches
    /// the order's minimum, moved into claims for fills. Past the deadline without it, the order
    /// drops out of the value and restocking halts for the owner.
    function settleRestock(StockState storage s, StockContext memory ctx) external {
        if (!s.orderOpen) revert RestockUnavailable();
        uint256 surplus = unbooked(s, ctx);
        if (surplus >= s.orderMinOut) {
            s.stockBooked += surplus;
            s.orderOpen = false;
            uint256 tokens = IERC20(Currency.unwrap(ctx.stock)).balanceOf(address(this));
            if (tokens != 0) StockLib.lock(ctx, StockLib.OP_TO_CLAIMS, ctx.stock, tokens);
            emit Restocked(s.orderCash, surplus);
        } else if (block.timestamp > s.orderDeadline) {
            s.orderOpen = false;
            s.restockHalted = true;
            emit RestockExpired(s.orderCash);
        } else {
            revert NotDelivered(surplus, s.orderMinOut);
        }
    }

    /// @notice Book stock that arrived with no order open (a late delivery, an in-kind dividend, a
    /// donation). Refused while an order is open, which a delivery must settle first.
    function syncWindfall(StockState storage s, StockContext memory ctx) external {
        if (s.orderOpen) revert OrderOpen();
        uint256 surplus = unbooked(s, ctx);
        s.stockBooked += surplus;
        emit Windfall(surplus);
    }

    // -------------------------------------------------------------------------------------
    // Deposits and withdrawals
    // -------------------------------------------------------------------------------------

    /// @notice Everything a deposit or withdrawal must see before it prices shares: not paused, no
    /// pending hedge or open lock, the market open for this vault and the price fresh; then the
    /// short's funding settled, so the value it prices off is exact.
    function beforeNav(StockConfig storage c, StockState storage s, StockContext memory ctx, uint8 flag) external {
        if (s.paused & flag != 0) revert IsPaused(flag);
        if (ctx.vault.getLocker() != address(0) || s.hedgeBlock == block.number) revert NavNotReady();
        requireNavPrice(c, ctx);
        (bool found,) = StockLib.position(s);
        if (found) {
            // A one-unit margin decrease applies accrued funding in the same transaction and moves
            // nothing that matters.
            string memory sub = StockLib.subaccount();
            StockLib.EXCHANGE.decreasePositionMargin(address(this), sub, sub, s.marketId, 1);
        }
    }

    /// @notice Refuse a share price more than `navJumpBps` from the last one priced, then record it.
    function checkSharePrice(StockConfig storage c, StockState storage s, uint256 price) external {
        uint256 last = s.lastSharePrice;
        if (last != 0 && StockLib.deviationBps(price, last) > c.navJumpBps) revert NavJump(price, last);
        s.lastSharePrice = price;
    }

    function requireNavPrice(StockConfig storage c, StockContext memory ctx) internal view {
        StockLib.requireUsable(StockLib.storedReference(c, ctx));
    }

    /// @dev Stock held beyond the booked stock and what is held for fixing-lane requesters.
    function unbooked(StockState storage s, StockContext memory ctx) internal view returns (uint256) {
        uint256 held = StockLib.ownStock(s, ctx);
        return held > s.stockBooked ? held - s.stockBooked : 0;
    }
}
