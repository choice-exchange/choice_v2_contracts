// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {StockLib} from "./StockLib.sol";
import {StockOps} from "./StockOps.sol";
import {RedeemAccount, RedeemEpoch, StockConfig, StockContext, StockLayout, StockState} from "./StockTypes.sol";

/// @notice The share token's internals a module may reach, on the vault itself.
interface IStockVaultSelf {
    function escrowShares(address owner, address spender, uint256 shares) external;
    function burnEscrowed(uint256 shares) external;
}

/// @title StockQueue
/// @notice A `StockVault`'s redeem queue, for exits larger than the cash on hand. Runs by DELEGATECALL,
/// as the vault.
///
/// **Requests** follow ERC-7540's request side: `requestRedeem(shares, controller, owner)` escrows the
/// shares in the vault, per controller (`requestId` 0), with operators. They cannot be cancelled. While
/// queued, the shares still count in the share price, so nothing moves for those who stay.
///
/// **Epochs.** Every request lands in the open epoch, and an epoch settles whole, one of two ways:
/// - **in cash**, by anyone, once the vault's cash above the reserve covers it at the share price less
///   `exitFeeBps` (the keeper raises the cash first, selling stock to the issuer by quote; the hedge
///   follows). The fee stays with those who stay and is set to cover the unwind;
/// - **in kind**, the backstop: by the keeper any time, by anyone once the epoch is `queueDeadline`
///   old. The epoch takes its share of the booked stock and of the cash at once, and its share of the
///   rest (the short's value, a restock order in transit, a maker order's margin) as a cash debt, paid
///   (`finishInKind`, by anyone) once the short has been cut to match and its margin is back. The fee
///   applies to the cash parts.
///
/// Epochs settle in order: while one is in kind and owes its debt, the next waits. The vault's instant
/// withdrawals cannot take the cash the queue is waiting for.
///
/// **Claims** pay a controller's share of what its settled epochs left, pro rata on what remains (the
/// last claim takes the rounding dust), and are never paused. They pay through `claimRedeem`, not
/// ERC-4626 `redeem`: an in-kind epoch pays two tokens.
library StockQueue {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint8 internal constant OPEN = 0;
    uint8 internal constant UNWINDING = 1;
    uint8 internal constant SETTLED = 2;

    error ZeroShares();
    error ZeroAddress();
    error QueuePaused();
    error NotAuthorized();
    error RedeemTooSmall(uint256 value, uint256 minimum);
    error EarlierRequestUnsettled(uint64 epoch);
    error NothingQueued();
    error UnwindPending(uint64 epoch);
    error QueueNotOverdue(uint256 overdueAt);
    error CashShortForQueue(uint256 needed, uint256 free);
    error NotUnwinding();
    error NothingToClaim();

    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event RedeemsSettled(uint64 indexed epoch, uint256 shares, uint256 cash, uint256 fee);
    event InKindStarted(uint64 indexed epoch, uint256 shares, uint256 stock, uint256 cash, uint256 debt);
    event InKindFinished(uint64 indexed epoch, uint256 debt);
    event RedeemClaimed(
        address indexed controller, address indexed receiver, uint256 shares, uint256 cash, uint256 stock
    );

    // -------------------------------------------------------------------------------------
    // Requests
    // -------------------------------------------------------------------------------------

    /// @notice Queue `shares` of `owner` for `controller`, as ERC-7540 `requestRedeem`. The caller is
    /// the owner, the owner's operator, or spends the owner's allowance.
    function request(StockLayout storage l, uint256 shares, address controller, address owner) external {
        if (shares == 0) revert ZeroShares();
        if (controller == address(0) || owner == address(0)) revert ZeroAddress();
        if (l.state.paused & StockLib.PAUSE_WITHDRAWALS != 0) revert QueuePaused();
        uint256 value = IERC4626(address(this)).convertToAssets(shares);
        if (value < l.config.minRedeem) revert RedeemTooSmall(value, l.config.minRedeem);
        if (l.redeemEpoch == 0) l.redeemEpoch = 1;
        uint64 current = l.redeemEpoch;
        RedeemAccount storage r = l.redeems[controller];
        if (r.shares != 0 && r.epoch != current) {
            if (l.epochs[r.epoch].status != SETTLED) revert EarlierRequestUnsettled(r.epoch);
            _roll(l, r);
        }
        IStockVaultSelf(address(this)).escrowShares(owner, msg.sender, shares);
        RedeemEpoch storage e = l.epochs[current];
        if (e.shares == 0) {
            e.openedAt = uint64(block.timestamp);
            e.feeBps = l.config.exitFeeBps;
        }
        e.shares += shares.toUint128();
        r.epoch = current;
        r.shares += shares.toUint128();
        emit RedeemRequest(controller, owner, 0, msg.sender, shares);
    }

    function setOperator(StockLayout storage l, address operator, bool approved) external {
        l.operators[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    // -------------------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------------------

    /// @notice Settle the open epoch in cash, at the share price less the exit fee. Anyone, once the
    /// cash is there.
    function settleCash(StockLayout storage l) external {
        (uint64 id, RedeemEpoch storage e) = _settleable(l);
        StockConfig storage c = l.config;
        StockState storage s = l.state;
        StockContext memory ctx = l.ctx;
        _priceShares(c, s, ctx);

        uint256 gross = IERC4626(address(this)).convertToAssets(e.shares);
        uint256 cash = gross * (StockLib.BPS - _fee(c, e)) / StockLib.BPS;
        uint256 free = _free(c, s, ctx);
        if (cash > free) revert CashShortForQueue(cash, free);

        IStockVaultSelf(address(this)).burnEscrowed(e.shares);
        s.cashOwed += cash.toUint128();
        e.cash = cash.toUint128();
        e.sharesLeft = e.shares;
        e.status = SETTLED;
        l.redeemEpoch = id + 1;
        _recordSharePrice(s);
        emit RedeemsSettled(id, e.shares, cash, gross - cash);
    }

    /// @notice Settle the open epoch in kind: the keeper any time, anyone once it is `queueDeadline`
    /// old. Its share of the booked stock and the cash now; its share of everything else as a debt.
    function startInKind(StockLayout storage l, bool isKeeper) external {
        (uint64 id, RedeemEpoch storage e) = _settleable(l);
        StockConfig storage c = l.config;
        StockState storage s = l.state;
        StockContext memory ctx = l.ctx;
        uint256 overdueAt = uint256(e.openedAt) + c.queueDeadline;
        if (!isKeeper && block.timestamp < overdueAt) revert QueueNotOverdue(overdueAt);
        _priceShares(c, s, ctx);

        // The epoch's fraction is its shares over all shares, virtual ones included, as ERC-4626 prices.
        uint256 supply = IERC20(address(this)).totalSupply() + 10 ** StockLib.DECIMALS_OFFSET;
        uint256 booked = Math.min(s.stockBooked, StockLib.ownStock(s, ctx));
        uint256 own = StockLib.ownCash(s, ctx);
        // Everything else the vault is worth: the short, a restock in transit, a maker order's margin.
        uint256 rest = IERC4626(address(this)).totalAssets() - own
            - StockLib.stockToCash(ctx, booked, StockLib.markPrice(ctx), Math.Rounding.Floor);
        uint256 keep = StockLib.BPS - _fee(c, e);
        uint256 stockOut = Math.mulDiv(booked, e.shares, supply);
        uint256 cashNow = Math.mulDiv(own, e.shares, supply) * keep / StockLib.BPS;
        uint256 debt = Math.mulDiv(rest, e.shares, supply) * keep / StockLib.BPS;

        IStockVaultSelf(address(this)).burnEscrowed(e.shares);
        s.stockBooked -= stockOut;
        s.stockOwed += stockOut.toUint128();
        s.cashOwed += cashNow.toUint128();
        s.debtOwed += debt.toUint128();
        (e.stock, e.cash, e.debt) = (stockOut.toUint128(), cashNow.toUint128(), debt.toUint128());
        e.sharesLeft = e.shares;
        if (debt == 0) {
            e.status = SETTLED;
        } else {
            e.status = UNWINDING;
            l.unwinding = id;
        }
        l.redeemEpoch = id + 1;
        _recordSharePrice(s);
        emit InKindStarted(id, e.shares, stockOut, cashNow, debt);
    }

    /// @notice Pay an in-kind epoch's debt once the vault's cash above the reserve covers it. Anyone.
    function finishInKind(StockLayout storage l) external {
        uint64 id = l.unwinding;
        if (id == 0) revert NotUnwinding();
        RedeemEpoch storage e = l.epochs[id];
        StockState storage s = l.state;
        uint256 free = _free(l.config, s, l.ctx);
        if (e.debt > free) revert CashShortForQueue(e.debt, free);
        uint128 debt = e.debt;
        s.debtOwed -= debt;
        s.cashOwed += debt;
        e.cash += debt;
        e.debt = 0;
        e.status = SETTLED;
        l.unwinding = 0;
        emit InKindFinished(id, debt);
    }

    // -------------------------------------------------------------------------------------
    // Claims
    // -------------------------------------------------------------------------------------

    /// @notice Pay `controller`'s settled share to `receiver`: cash, and stock from an in-kind epoch.
    /// The controller or its operator.
    function claim(StockLayout storage l, address controller, address receiver)
        external
        returns (uint256 cash, uint256 stock)
    {
        if (msg.sender != controller && !l.operators[controller][msg.sender]) revert NotAuthorized();
        if (receiver == address(0)) revert ZeroAddress();
        RedeemAccount storage r = l.redeems[controller];
        if (r.shares != 0 && l.epochs[r.epoch].status == SETTLED) _roll(l, r);
        uint256 shares = r.claimShares;
        if (shares == 0) revert NothingToClaim();
        (cash, stock) = (r.claimCash, r.claimStock);
        (r.claimShares, r.claimCash, r.claimStock) = (0, 0, 0);

        StockState storage s = l.state;
        StockContext memory ctx = l.ctx;
        s.cashOwed -= cash.toUint128();
        s.stockOwed -= stock.toUint128();
        _pay(ctx, ctx.cash, receiver, cash);
        _pay(ctx, ctx.stock, receiver, stock);
        emit RedeemClaimed(controller, receiver, shares, cash, stock);
    }

    /// @notice What `controller` can claim now: shares, cash and stock.
    function claimable(StockLayout storage l, address controller)
        internal
        view
        returns (uint256 shares, uint256 cash, uint256 stock)
    {
        RedeemAccount storage r = l.redeems[controller];
        (shares, cash, stock) = (r.claimShares, r.claimCash, r.claimStock);
        RedeemEpoch storage e = l.epochs[r.epoch];
        if (r.shares != 0 && e.status == SETTLED) {
            shares += r.shares;
            cash += Math.mulDiv(r.shares, e.cash, e.sharesLeft);
            stock += Math.mulDiv(r.shares, e.stock, e.sharesLeft);
        }
    }

    /// @notice What `controller` has queued and not yet settled, in shares.
    function pending(StockLayout storage l, address controller) internal view returns (uint256) {
        RedeemAccount storage r = l.redeems[controller];
        return r.shares != 0 && l.epochs[r.epoch].status != SETTLED ? r.shares : 0;
    }

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    /// @dev Move a request whose epoch has settled into what its controller can claim, taking its share
    /// of what the epoch has left.
    function _roll(StockLayout storage l, RedeemAccount storage r) private {
        RedeemEpoch storage e = l.epochs[r.epoch];
        uint256 cash = Math.mulDiv(r.shares, e.cash, e.sharesLeft);
        uint256 stock = Math.mulDiv(r.shares, e.stock, e.sharesLeft);
        e.cash -= cash.toUint128();
        e.stock -= stock.toUint128();
        e.sharesLeft -= r.shares;
        r.claimShares += r.shares;
        r.claimCash += cash.toUint128();
        r.claimStock += stock.toUint128();
        r.shares = 0;
    }

    function _settleable(StockLayout storage l) private view returns (uint64 id, RedeemEpoch storage e) {
        if (l.unwinding != 0) revert UnwindPending(l.unwinding);
        id = l.redeemEpoch;
        e = l.epochs[id];
        if (id == 0 || e.shares == 0) revert NothingQueued();
    }

    /// @dev What a deposit or withdrawal must see first, then a share price within the NAV jump guard.
    function _priceShares(StockConfig storage c, StockState storage s, StockContext memory ctx) private {
        StockOps.beforeNav(c, s, ctx, StockLib.PAUSE_WITHDRAWALS);
        IERC4626 v = IERC4626(address(this));
        StockOps.checkSharePrice(c, s, v.convertToAssets(10 ** v.decimals()));
    }

    /// @dev The exit fee an epoch pays: the lower of the fee when it opened and the fee now.
    function _fee(StockConfig storage c, RedeemEpoch storage e) private view returns (uint256) {
        return Math.min(e.feeBps, c.exitFeeBps);
    }

    /// @dev The exit fee stays with those who stay, so a settlement moves the share price on purpose:
    /// the NAV breaker takes the new price as its last, or the next deposit or withdrawal would trip it.
    function _recordSharePrice(StockState storage s) private {
        IERC4626 v = IERC4626(address(this));
        s.lastSharePrice = v.convertToAssets(10 ** v.decimals());
    }

    function _free(StockConfig storage c, StockState storage s, StockContext memory ctx)
        private
        view
        returns (uint256)
    {
        uint256 own = StockLib.ownCash(s, ctx);
        return own > c.cashReserve ? own - c.cashReserve : 0;
    }

    function _pay(StockContext memory ctx, Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        StockLib.ensureToken(ctx, currency, amount);
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }
}
