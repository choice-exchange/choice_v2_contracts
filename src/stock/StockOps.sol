// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {StockLib} from "./StockLib.sol";
import {Fill, StockConfig, StockContext, StockState, SwapRequest} from "./StockTypes.sol";

/// @title StockOps
/// @notice A `StockVault`'s bookkeeping: what a fill changes and the checks before a deposit or
/// withdrawal prices shares (restocking is in `StockRestock`). Like `StockLib`, its external functions run
/// by DELEGATECALL, as the vault.
library StockOps {
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;

    error NavNotReady();
    error IsPaused(uint8 flag);
    error NavJump(uint256 sharePrice, uint256 last);

    event Filled(
        address indexed sender,
        bool cashIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 price,
        uint256 spreadBps,
        bool closed
    );

    // -------------------------------------------------------------------------------------
    // Fills
    // -------------------------------------------------------------------------------------

    /// @notice Settle a priced fill in claims and book it: the input minted to the vault, the output
    /// burned from its claims, both ledgers, the outflow window, and the anchor (a fill on a
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

        (s.stockBooked, s.cashBooked) = w.cashIn
            ? (s.stockBooked - f.amountOut, s.cashBooked + f.amountIn)
            : (s.stockBooked + f.amountIn, s.cashBooked - f.amountOut);
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
            // nothing that matters. If the exchange refuses it (a short under its initial margin
            // ratio), the value is read with funding unsettled rather than freezing every exit.
            string memory sub = StockLib.subaccount();
            try StockLib.EXCHANGE.decreasePositionMargin(address(this), sub, sub, s.marketId, 1) {} catch {}
        }
    }

    /// @notice Refuse a share price more than `navJumpBps` from the last one priced, then record it.
    function checkSharePrice(StockConfig storage c, StockState storage s, uint256 price) external {
        uint256 last = s.lastSharePrice;
        if (last != 0 && StockLib.deviationBps(price, last) > c.navJumpBps) revert NavJump(price, last);
        s.lastSharePrice = price;
    }

    // -------------------------------------------------------------------------------------
    // Config
    // -------------------------------------------------------------------------------------

    /// @notice Revert unless every tunable is inside the hard limits in `StockLib`.
    function checkConfig(StockConfig memory c) external pure {
        if (c.maxSpread > StockLib.MAX_SPREAD_LIMIT || c.minSpread == 0 || c.minSpread > c.maxSpread) {
            revert StockLib.BadConfig();
        }
        if (
            c.spreadRegular > c.maxSpread || c.spreadExtended > c.maxSpread || c.spreadOvernight > c.maxSpread
                || c.spreadClosed > c.maxSpread
        ) revert StockLib.BadConfig();
        // The lean must stay inside the spread, so neither side ever crosses the reference.
        if (c.skewBps >= c.minSpread) revert StockLib.BadConfig();
        if (c.maxJumpBps == 0 || c.maxJumpBps > StockLib.MAX_JUMP_LIMIT) revert StockLib.BadConfig();
        if (c.hedgeSlippageBps > StockLib.MAX_HEDGE_SLIPPAGE || c.restockSlippageBps > StockLib.MAX_RESTOCK_SLIPPAGE) {
            revert StockLib.BadConfig();
        }
        if (c.navJumpBps == 0 || c.navJumpBps > StockLib.MAX_NAV_JUMP) revert StockLib.BadConfig();
        if (c.leverageX10 < StockLib.MIN_LEVERAGE_X10 || c.leverageX10 > StockLib.MAX_LEVERAGE_X10) {
            revert StockLib.BadConfig();
        }
        if (
            c.maxAgeMs == 0 || c.maxAgeMs > StockLib.MAX_AGE_MS_LIMIT || c.closeTolerance > StockLib.MAX_CLOSE_TOLERANCE
        ) {
            revert StockLib.BadConfig();
        }
        if (
            c.window < StockLib.MIN_WINDOW || c.reanchorDelay < StockLib.MIN_REANCHOR_DELAY
                || c.publicHedgeDelay < StockLib.MIN_REANCHOR_DELAY
        ) {
            revert StockLib.BadConfig();
        }
        if (c.restockDeadline < StockLib.MIN_RESTOCK_DEADLINE || c.restockDeadline > StockLib.MAX_RESTOCK_DEADLINE) {
            revert StockLib.BadConfig();
        }
        // The issuer's two units: the memo's expiry key follows this.
        if (c.restockExpiryUnit != 1 hours && c.restockExpiryUnit != 1 days) revert StockLib.BadConfig();
        // A day of restocking can never move more than the inventory cap.
        if (c.restockDailyCap > c.maxInventory) revert StockLib.BadConfig();
        if (c.makerTimeout > StockLib.MAX_MAKER_TIMEOUT) revert StockLib.BadConfig();
        if (
            c.exitFeeBps > StockLib.MAX_EXIT_FEE || c.queueDeadline < StockLib.MIN_QUEUE_DEADLINE
                || c.queueDeadline > StockLib.MAX_QUEUE_DEADLINE
        ) revert StockLib.BadConfig();
        if (c.targetInventory > c.maxInventory || c.qtyTick == 0 || c.priceTick == 0) revert StockLib.BadConfig();
    }

    function requireNavPrice(StockConfig storage c, StockContext memory ctx) internal view {
        StockLib.requireUsable(StockLib.storedReference(c, ctx));
    }
}
