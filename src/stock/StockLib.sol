// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {IExchangeDerivatives} from "../interfaces/IExchangeDerivatives.sol";
import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {SubaccountLib} from "../libraries/SubaccountLib.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {PythLazerLib} from "./PythLazerLib.sol";
import {Reference, Refusal, StockConfig, StockContext, StockState} from "./StockTypes.sol";

/// @title StockLib
/// @notice What every body of a `StockVault` shares: the hard limits and flags, the errors more than one
/// raises, the reference price, the hedge gap, and the helpers (valuation inputs, conversions, the
/// Choice vault lock). Internal only, so it is inlined into each body that uses it and never deployed.
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
    uint32 internal constant MAX_MAKER_TIMEOUT = 1 days;

    /// @dev Transient: set only while the vault holds a Choice vault lock it opened itself.
    uint256 internal constant LOCK_OPEN_SLOT = 0x2c7f2a3e1b8d4c6f9e0a5b7c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e;
    uint8 internal constant OP_TO_CLAIMS = 1;
    uint8 internal constant OP_FROM_CLAIMS = 2;

    error BadConfig();
    error PriceNotUsable(Refusal reason);
    error OracleMissing();
    error CashShort(uint256 needed, uint256 own);

    // -------------------------------------------------------------------------------------
    // The reference price
    // -------------------------------------------------------------------------------------

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

    /// @notice Revert unless a deposit, withdrawal or restock may act on `r`: the market open for
    /// this vault and the price fresh.
    function requireUsable(Reference memory r) internal pure {
        if (r.reason != Refusal.None) revert PriceNotUsable(r.reason);
        if (r.closed) revert PriceNotUsable(Refusal.Closed);
    }

    // -------------------------------------------------------------------------------------
    // The hedge gap
    // -------------------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------------------
    // Helpers
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
}
