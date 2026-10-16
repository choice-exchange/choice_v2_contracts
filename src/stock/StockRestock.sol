// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {StockLib} from "./StockLib.sol";
import {Reference, StockConfig, StockContext, StockLayout, StockState} from "./StockTypes.sol";

/// @title StockRestock
/// @notice A `StockVault`'s restocking by LIMIT orders sent to the issuer as memo transfers, in both
/// directions. Runs by DELEGATECALL, as the vault.
///
/// - **The order.** The keeper names the side, the amount sent, the least it takes back (the limit) and
///   the expiry in the issuer's units. The vault checks the limit against a fresh reference and the
///   anchor, builds the memo from the owner's template with exactly those numbers, and sends the input
///   to the issuer with the memo appended to the transfer. The issuer fills it whole at the limit or
///   better, or refunds it after the expiry. One order is open at a time.
/// - **In transit.** A buy is valued at its cash and its stock is hedged as if held. A sell's stock
///   stays in the value at the mark and in the hedge until it is paid.
/// - **Closing.** Stock arriving is seen on the stock ledger: a buy's delivery, or a sell's stock coming
///   back as a refund. Cash arriving cannot be told apart from other cash, so a buy's refund or a sell's
///   payment closes the order on the keeper's word (it watches the issuer's transfer), or on anyone's
///   once the expiry plus `restockDeadline` has passed. Nothing halts: a mistaken close only drops the
///   order from the value until what arrives is booked (`syncWindfall` for stock, at once for cash).
library StockRestock {
    using SafeCast for uint256;

    uint256 internal constant MAX_MEMO = 1024;

    error RestockUnavailable();
    error OrderTooLong(uint256 life);
    error LimitOutOfBand(uint256 value, uint256 floor);
    error InventoryCapExceeded(uint256 value, uint256 cap);
    error NotEnoughStock(uint256 wanted, uint256 booked);
    error StockDeficit();
    error IssuerTransferFailed();
    error NotDelivered(uint256 surplus, uint256 wanted);
    error OrderOpen();
    error BadMemo();

    event RestockOrdered(bool sell, uint256 amountIn, uint256 limitOut, uint64 deadline, bytes memo);
    event Restocked(bool sell, uint256 amountIn, uint256 amountOut);
    event RestockRefunded(bool sell, uint256 amountIn);
    event Windfall(uint256 stock);

    /// @notice Send a LIMIT order to the issuer: `amountIn` of cash for at least `limitOut` stock, or
    /// (`sell`) `amountIn` of stock for at least `limitOut` cash, open for `expiryUnits` of the issuer's
    /// expiry unit. The limit is within `restockSlippageBps` of a fresh reference (a buy pays no more, a
    /// sale takes no less), the reference within `maxJumpBps` of the anchor, a buy within the inventory
    /// cap, and both sides' cash value within the daily restock cap.
    function order(
        StockLayout storage l,
        bool restockOpen,
        bool sell,
        uint256 amountIn,
        uint256 limitOut,
        uint16 expiryUnits
    ) external {
        StockConfig storage c = l.config;
        StockState storage s = l.state;
        StockContext memory ctx = l.ctx;
        if (!restockOpen || s.orderOpen || l.restockMemo.length == 0 || l.issuer == address(0)) {
            revert RestockUnavailable();
        }
        if (amountIn == 0 || limitOut == 0 || expiryUnits == 0) revert RestockUnavailable();
        uint256 life = uint256(expiryUnits) * c.restockExpiryUnit;
        if (life > StockLib.MAX_ORDER_LIFE) revert OrderTooLong(life);

        Reference memory r = StockLib.storedReference(c, ctx);
        StockLib.requireUsable(r);
        StockLib.requireAnchored(c, s, r.price);
        if (StockLib.ownStock(s, ctx) < s.stockBooked) revert StockDeficit();
        // Book any stock already here (a late delivery or refund of an earlier order) so that only what
        // arrives for THIS order can settle it.
        uint256 stray = StockLib.unbooked(s, ctx);
        if (stray != 0) {
            s.stockBooked += stray;
            emit Windfall(stray);
        }
        uint256 keep = StockLib.BPS - c.restockSlippageBps;
        if (sell) {
            if (amountIn > s.stockBooked) revert NotEnoughStock(amountIn, s.stockBooked);
            uint256 fair = StockLib.stockToCash(ctx, amountIn, r.price, Math.Rounding.Floor);
            _band(limitOut, fair * keep / StockLib.BPS);
            StockLib.countRestock(c, s, fair);
            s.orderCounted = fair.toUint96();
            StockLib.ensureToken(ctx, ctx.stock, amountIn);
            s.stockBooked -= amountIn;
        } else {
            _band(StockLib.stockToCash(ctx, limitOut, r.price, Math.Rounding.Floor), amountIn * keep / StockLib.BPS);
            uint256 inventory = StockLib.stockToCash(ctx, s.stockBooked + limitOut, r.price, Math.Rounding.Ceil);
            if (inventory > c.maxInventory) revert InventoryCapExceeded(inventory, c.maxInventory);
            StockLib.countRestock(c, s, amountIn);
            s.orderCounted = amountIn.toUint96();
            // The reserve, an unwinding epoch's debt and the margin the new stock's short needs stay.
            uint256 keepCash = StockLib.cashKept(c, s)
                + StockLib.stockToCash(ctx, limitOut, r.price, Math.Rounding.Ceil) * 10 / c.leverageX10;
            uint256 own = StockLib.ownCash(s, ctx);
            if (own < amountIn + keepCash) revert StockLib.CashShort(amountIn + keepCash, own);
            StockLib.spendOwnCash(s, ctx, amountIn);
        }
        s.orderOpen = true;
        s.orderSell = sell;
        s.orderWindow = s.restockWindowStart;
        (s.orderCash, s.orderStock) =
            sell ? (limitOut.toUint96(), amountIn.toUint128()) : (amountIn.toUint96(), limitOut.toUint128());
        s.orderDeadline = (block.timestamp + life + c.restockDeadline).toUint64();

        bytes memory memo = fillMemo(l.restockMemo, amountIn, limitOut, expiryUnits, c.restockExpiryUnit == 1 hours);
        address token = Currency.unwrap(sell ? ctx.stock : ctx.cash);
        (bool ok, bytes memory ret) =
            token.call(abi.encodePacked(abi.encodeCall(IERC20.transfer, (l.issuer, amountIn)), memo));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert IssuerTransferFailed();
        emit RestockOrdered(sell, amountIn, limitOut, s.orderDeadline, memo);
    }

    /// @notice Close the open order on what has arrived. Stock at least the order's (a buy delivered, a
    /// sell refunded) is booked and moved into claims. Otherwise the cash leg is taken to have arrived (a
    /// sell paid, a buy refunded): on the keeper's word any time, on anyone's past the deadline.
    function settle(StockState storage s, StockContext memory ctx, bool isKeeper) external {
        if (!s.orderOpen) revert RestockUnavailable();
        uint256 surplus = StockLib.unbooked(s, ctx);
        bool sell = s.orderSell;
        if (surplus >= s.orderStock) {
            s.stockBooked += surplus;
            s.orderOpen = false;
            uint256 tokens = IERC20(Currency.unwrap(ctx.stock)).balanceOf(address(this));
            if (tokens != 0) StockLib.lock(ctx, StockLib.OP_TO_CLAIMS, ctx.stock, tokens);
            if (sell) {
                // The stock came back, which the vault can see: the order no longer counts.
                StockLib.uncountRestock(s, s.orderWindow, s.orderCounted);
                emit RestockRefunded(true, s.orderStock);
            } else {
                emit Restocked(false, s.orderCash, surplus);
            }
        } else if (isKeeper || block.timestamp > s.orderDeadline) {
            s.orderOpen = false;
            if (sell) emit Restocked(true, s.orderStock, s.orderCash);
            else emit RestockRefunded(false, s.orderCash);
        } else {
            revert NotDelivered(surplus, s.orderStock);
        }
    }

    /// @notice Book stock that arrived with no order open (a late delivery or refund, an in-kind
    /// dividend, a donation). Refused while an order is open, which a delivery must settle first.
    function syncWindfall(StockState storage s, StockContext memory ctx) external {
        if (s.orderOpen) revert OrderOpen();
        uint256 surplus = StockLib.unbooked(s, ctx);
        s.stockBooked += surplus;
        emit Windfall(surplus);
    }

    /// @notice Revert unless `t` is a usable memo template: at most `MAX_MEMO` bytes, each placeholder
    /// (0x01 offered, 0x02 asked for, 0x03 the expiry key and value, 0x04 the vault) exactly once.
    /// Whoever the issuer pays is the vault: the template names `did_id` once, as `"did_id":"<0x04>"`,
    /// and the expiry key is the vault's to write (it follows the configured unit), so the owner can
    /// neither send a fill or refund elsewhere nor hold an order longer than the vault counts it.
    function checkMemo(bytes calldata t) external pure {
        if (t.length > MAX_MEMO) revert BadMemo();
        uint256 seen;
        for (uint256 k; k < t.length; ++k) {
            uint8 ch = uint8(t[k]);
            if (ch == 0 || ch > 4) continue;
            if (seen & (1 << ch) != 0) revert BadMemo();
            seen |= 1 << ch;
        }
        if (seen != 30) revert BadMemo();
        if (_count(t, "did_id") != 1 || _count(t, "\"did_id\":\"\x04\"") != 1 || _count(t, "expiry") != 0) {
            revert BadMemo();
        }
    }

    /// @dev Non-overlapping occurrences of `needle` in `t`.
    function _count(bytes calldata t, bytes memory needle) private pure returns (uint256 n) {
        uint256 m = needle.length;
        for (uint256 k; k + m <= t.length;) {
            if (keccak256(t[k:k + m]) == keccak256(needle)) {
                ++n;
                k += m;
            } else {
                ++k;
            }
        }
    }

    /// @dev The template with its placeholders filled: the amounts in decimal, the expiry as
    /// `"expiry_hours":N` or `"expiry_days":N`, the vault as a lowercase 0x address.
    function fillMemo(bytes storage template, uint256 offered, uint256 asked, uint256 expiry, bool hours_)
        internal
        view
        returns (bytes memory out)
    {
        bytes memory t = template;
        uint256 start;
        for (uint256 k; k < t.length; ++k) {
            uint8 ch = uint8(t[k]);
            if (ch == 0 || ch > 4) continue;
            bytes memory v;
            if (ch == 1) {
                v = bytes(Strings.toString(offered));
            } else if (ch == 2) {
                v = bytes(Strings.toString(asked));
            } else if (ch == 3) {
                v = abi.encodePacked(hours_ ? '"expiry_hours":' : '"expiry_days":', Strings.toString(expiry));
            } else {
                v = bytes(Strings.toHexString(address(this)));
            }
            out = bytes.concat(out, _slice(t, start, k), v);
            start = k + 1;
        }
        out = bytes.concat(out, _slice(t, start, t.length));
    }

    function _band(uint256 value, uint256 floor) private pure {
        if (value < floor) revert LimitOutOfBand(value, floor);
    }

    function _slice(bytes memory b, uint256 from, uint256 to) private pure returns (bytes memory r) {
        r = new bytes(to - from);
        for (uint256 k; k < r.length; ++k) {
            r[k] = b[from + k];
        }
    }
}
