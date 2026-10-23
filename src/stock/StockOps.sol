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
    using SafeCast for int256;

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
    /// @notice A share was priced with the short's funding unsettled: the exchange refused the settle,
    /// or settling would have left the position unreadable (see `StockOps.beforeNav`).
    event FundingUnsettled();

    // -------------------------------------------------------------------------------------
    // Fills
    // -------------------------------------------------------------------------------------

    /// @notice Settle a priced fill in claims and book it: the input minted to the vault, the output
    /// burned from its claims, both ledgers, the flow buckets and closed-period count, and the anchor (a
    /// fill on a live price is a fresh anchor; a frozen weekend price is not).
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
        _countFlow(c, s, ctx, w.cashIn, f.closed, outValue);
        if (!f.closed) {
            s.anchorPrice = f.price.toUint128();
            s.jumpSince = 0;
        }
        emit Filled(sender, w.cashIn, f.amountIn, f.amountOut, f.price, f.spreadBps, f.closed);
    }

    /// @dev Count a fill's outflow in the flow buckets (`StockPricing.guards` checked it fits) and, on a
    /// closed market, in its period's net.
    function _countFlow(
        StockConfig storage c,
        StockState storage s,
        StockContext memory ctx,
        bool cashIn,
        bool closed,
        uint256 outValue
    ) private {
        (uint256 gross, int256 net) = StockLib.flowNow(c, s);
        int256 sign = cashIn ? int256(1) : int256(-1);
        s.flowAt = uint64(block.timestamp);
        s.grossUsed = (gross + StockLib.share(outValue, closed ? c.windowCapClosed : c.windowCap)).toUint64();
        s.netUsed = (net + sign * StockLib.share(outValue, c.netCap).toInt256()).toInt64();
        if (closed) {
            (, uint256 start) = ctx.calendar.sessionAt(block.timestamp);
            s.closedNet = (StockLib.closedNetNow(c, s, ctx, start) + sign * outValue.toInt256()).toInt128();
            s.closedStart = uint64(start);
        }
    }

    // -------------------------------------------------------------------------------------
    // Deposits and withdrawals
    // -------------------------------------------------------------------------------------

    /// @notice Everything a deposit or withdrawal must see before it prices shares: not paused, no
    /// pending hedge or open lock, no short gone unexplained, the market open for this vault and the
    /// price fresh; then the short's funding settled, so the value it prices off is exact.
    function beforeNav(StockConfig storage c, StockState storage s, StockContext memory ctx, uint8 flag) external {
        if (s.paused & flag != 0) revert IsPaused(flag);
        if (ctx.vault.getLocker() != address(0) || s.hedgeBlock == block.number || s.positionLost) {
            revert NavNotReady();
        }
        requireNavPrice(c, ctx);
        (bool readable, bool found,) = StockLib.readPosition(s);
        if (found || !readable) {
            // A one-unit margin decrease applies accrued funding in the same transaction and moves
            // nothing that matters. It also stamps the market's funding index on the position, and a
            // negative index makes the position unreadable (`StockLib.readPosition`): so it runs as a
            // call to the vault itself (`StockHedge.settleFunding`) that reverts, undoing it, unless the
            // position still reads after. A refusal either way leaves funding unsettled rather than
            // freezing every exit; and on an unreadable position this is the one move that can heal it.
            (bool ok,) = address(this).call(abi.encodeWithSignature("settleFunding()"));
            if (!ok) emit FundingUnsettled();
        } else if (!StockLib.covered(s)) {
            // The short is gone and nothing of the vault's covered it: a liquidation, a settlement or a
            // paused market. No share is priced before a confirmation marks it and the owner has looked.
            revert NavNotReady();
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
        if (c.scarcityBps > StockLib.MAX_SPREAD_LIMIT) revert StockLib.BadConfig();
        // Every cap one trade is promised must be reachable: the flow caps hold at least a trade, the
        // closed ones are no wider than the open ones, and a full trade from inside the hedge band
        // leaves no more unhedged than allowed.
        if (
            c.maxTrade > c.netCap || c.netCap > c.windowCap || c.maxTradeClosed > c.maxTrade
                || c.windowCapClosed > c.windowCap || c.maxTradeClosed > c.windowCapClosed
                || c.maxTradeClosed > c.closedNetCap
        ) revert StockLib.BadConfig();
        if (uint256(c.maxTrade) + c.hedgeBand > c.maxUnhedged) revert StockLib.BadConfig();
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
        if (c.depositLock > StockLib.MAX_DEPOSIT_LOCK) revert StockLib.BadConfig();
    }

    function requireNavPrice(StockConfig storage c, StockContext memory ctx) internal view {
        StockLib.requireUsable(StockLib.storedReference(c, ctx));
    }
}
