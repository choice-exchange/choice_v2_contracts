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
        if (!restockOpen || s.orderOpen || l.restockMemo.length == 0) revert RestockUnavailable();
        if (amountIn == 0 || limitOut == 0 || expiryUnits == 0) revert RestockUnavailable();
        uint256 life = uint256(expiryUnits) * c.restockExpiryUnit;
        if (life > StockLib.MAX_ORDER_LIFE) revert OrderTooLong(life);

        Reference memory r = StockLib.storedReference(c, ctx);
        StockLib.requireUsable(r);
        StockLib.requireAnchored(c, s, r.price);
        if (StockLib.ownStock(s, ctx) < s.stockBooked) revert StockDeficit();
        uint256 keep = StockLib.BPS - c.restockSlippageBps;
        if (sell) {
            if (amountIn > s.stockBooked) revert NotEnoughStock(amountIn, s.stockBooked);
            uint256 fair = StockLib.stockToCash(ctx, amountIn, r.price, Math.Rounding.Floor);
            _band(limitOut, fair * keep / StockLib.BPS);
            StockLib.countRestock(c, s, fair);
            StockLib.ensureToken(ctx, ctx.stock, amountIn);
            s.stockBooked -= amountIn;
        } else {
            _band(StockLib.stockToCash(ctx, limitOut, r.price, Math.Rounding.Floor), amountIn * keep / StockLib.BPS);
            uint256 inventory = StockLib.stockToCash(ctx, s.stockBooked + limitOut, r.price, Math.Rounding.Ceil);
            if (inventory > c.maxInventory) revert InventoryCapExceeded(inventory, c.maxInventory);
            StockLib.countRestock(c, s, amountIn);
            StockLib.spendOwnCash(s, ctx, amountIn);
        }
        s.orderOpen = true;
        s.orderSell = sell;
        (s.orderCash, s.orderStock) =
            sell ? (limitOut.toUint96(), amountIn.toUint128()) : (amountIn.toUint96(), limitOut.toUint128());
        s.orderDeadline = (block.timestamp + life + c.restockDeadline).toUint64();

        bytes memory memo = fillMemo(l.restockMemo, amountIn, limitOut, expiryUnits);
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
            if (sell) emit RestockRefunded(true, s.orderStock);
            else emit Restocked(false, s.orderCash, surplus);
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
    /// (0x01 offered, 0x02 asked for, 0x03 expiry) exactly once.
    function checkMemo(bytes calldata t) external pure {
        if (t.length > MAX_MEMO) revert BadMemo();
        uint256 seen;
        for (uint256 k; k < t.length; ++k) {
            uint8 ch = uint8(t[k]);
            if (ch == 0 || ch > 3) continue;
            if (seen & (1 << ch) != 0) revert BadMemo();
            seen |= 1 << ch;
        }
        if (seen != 14) revert BadMemo();
    }

    /// @dev The template with its placeholders replaced by the numbers in decimal.
    function fillMemo(bytes storage template, uint256 offered, uint256 asked, uint256 expiry)
        internal
        view
        returns (bytes memory out)
    {
        bytes memory t = template;
        uint256 start;
        for (uint256 k; k < t.length; ++k) {
            uint8 ch = uint8(t[k]);
            if (ch == 0 || ch > 3) continue;
            out = bytes.concat(
                out, _slice(t, start, k), bytes(Strings.toString(ch == 1 ? offered : ch == 2 ? asked : expiry))
            );
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
