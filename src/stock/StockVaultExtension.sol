// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {MarketCalendar} from "./MarketCalendar.sol";
import {StockFixing} from "./StockFixing.sol";
import {StockLib} from "./StockLib.sol";
import {StockOps} from "./StockOps.sol";
import {FixingConfig, StockConfig, StockContext, StockLayout, StockState, StockStorage} from "./StockTypes.sol";

/// @title StockVaultExtension
/// @notice The cold half of every `StockVault`: settings, keeper actions, the hedge triggers and the
/// views. A vault reaches it through its fallback by DELEGATECALL, so every function here runs as
/// that vault, on its storage (`StockStorage`). One deployment serves every vault; called directly
/// it refuses everything, so its own (empty) storage can never matter.
///
/// The owner is the vault's own `owner()`, read back from the vault: there is one owner record, in
/// the vault's `Ownable2Step`.
contract StockVaultExtension is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address private immutable SELF;

    error NotDelegated();
    error NotOwner();
    error NotKeeper();
    error NotPauser();
    error ZeroAddress();
    error SpreadWidenTooLarge();
    error ProtectedToken(address token);

    event Widened(uint16 bps, uint64 until);
    event Paused(uint8 flags, address indexed by);
    event Unpaused(uint8 flags);
    event ConfigUpdated();
    event FixingConfigUpdated();
    event RolesUpdated(address keeper, address guardian, address issuer);
    event CalendarUpdated(address calendar);
    event DepositorUpdated(address indexed depositor, bool allowed);
    event AllowlistUpdated(bool on);
    event CurveOpenUpdated(bool open);
    event RestockHaltCleared();
    event NavAccepted();
    event Swept(address indexed token, address indexed to, uint256 amount);

    constructor() {
        SELF = address(this);
    }

    modifier delegated() {
        _delegated();
        _;
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier onlyKeeper() {
        _onlyKeeper();
        _;
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    function config() external view delegated returns (StockConfig memory) {
        return StockStorage.layout().config;
    }

    function state() external view delegated returns (StockState memory) {
        return StockStorage.layout().state;
    }

    function context() external view delegated returns (StockContext memory) {
        return StockStorage.layout().ctx;
    }

    function roles() external view delegated returns (address keeper, address guardian, address issuer) {
        StockLayout storage l = StockStorage.layout();
        return (l.keeper, l.guardian, l.issuer);
    }

    function isDepositor(address depositor) external view delegated returns (bool) {
        StockLayout storage l = StockStorage.layout();
        return !l.allowlistOn || l.isDepositor[depositor];
    }

    function stock() external view delegated returns (address) {
        return Currency.unwrap(StockStorage.layout().ctx.stock);
    }

    // -------------------------------------------------------------------------------------
    // Permissionless
    // -------------------------------------------------------------------------------------

    /// @notice Store a signed update, so the calls after it in a `multicall` see it.
    function pushPrice(bytes calldata update) external delegated returns (uint256) {
        return StockStorage.layout().ctx.store.update(update);
    }

    function poke() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockLib.poke(l.config, l.state, l.ctx);
    }

    function confirmHedge() external delegated nonReentrant {
        StockLib.confirmHedge(StockStorage.layout().state);
    }

    function syncHedge() external delegated nonReentrant returns (bool) {
        StockLayout storage l = StockStorage.layout();
        return StockLib.syncHedge(l.config, l.state, l.ctx, _restockOpen(l), msg.sender == l.keeper);
    }

    function topUpMargin() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockLib.topUpMargin(l.config, l.state, l.ctx);
    }

    /// @notice Book the open restock order's delivery, or expire it past its deadline.
    function settleRestock() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockOps.settleRestock(l.state, l.ctx);
    }

    /// @notice Book stock that arrived with no order open.
    function syncWindfall() external delegated nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockOps.syncWindfall(l.state, l.ctx);
    }

    // -------------------------------------------------------------------------------------
    // Keeper
    // -------------------------------------------------------------------------------------

    /// @notice Order `cash` of stock from the issuer, `memo` appended to the transfer (the issuer's
    /// order format), expecting at least `minStockOut` by the deadline. See `StockOps.restock`.
    function restock(uint256 cash, uint256 minStockOut, bytes calldata memo) external onlyKeeper nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockOps.restock(l.config, l.state, l.ctx, l.issuer, _restockOpen(l), cash, minStockOut, memo);
    }

    /// @notice Add `bps` to every fill's spread for `duration` seconds (earnings, the open, news).
    /// The keeper can only widen: a widen past `maxSpread` closes the lane until it expires.
    function widen(uint16 bps, uint32 duration) external onlyKeeper {
        if (duration > 1 days) revert SpreadWidenTooLarge();
        StockState storage s = StockStorage.layout().state;
        s.widenBps = bps;
        s.widenUntil = uint64(block.timestamp + duration);
        emit Widened(bps, s.widenUntil);
    }

    /// @notice Move the vault's own cash or stock between the token and Choice vault claims, which
    /// is what fills pay out of. Changes nothing the vault is worth.
    function toClaims(bool isCash, uint256 amount) external delegated nonReentrant {
        _keeperOrOwner();
        StockContext memory ctx = StockStorage.layout().ctx;
        StockLib.lock(ctx, StockLib.OP_TO_CLAIMS, isCash ? ctx.cash : ctx.stock, amount);
    }

    function fromClaims(bool isCash, uint256 amount) external delegated nonReentrant {
        _keeperOrOwner();
        StockContext memory ctx = StockStorage.layout().ctx;
        StockLib.lock(ctx, StockLib.OP_FROM_CLAIMS, isCash ? ctx.cash : ctx.stock, amount);
    }

    /// @notice Pause `flags` (fills 1, deposits 2, withdrawals 4, restock 8, fixing 16). Guardian,
    /// keeper or owner. A fixing batch that cannot settle while paused lapses and is refunded.
    function pause(uint8 flags) external delegated {
        StockLayout storage l = StockStorage.layout();
        if (msg.sender != l.guardian && msg.sender != l.keeper && msg.sender != IOwnerOf(address(this)).owner()) {
            revert NotPauser();
        }
        l.state.paused |= flags;
        emit Paused(flags, msg.sender);
    }

    // -------------------------------------------------------------------------------------
    // Owner
    // -------------------------------------------------------------------------------------

    function setConfig(StockConfig calldata config_) external onlyOwner {
        StockLib.checkConfig(config_);
        StockStorage.layout().config = config_;
        emit ConfigUpdated();
    }

    /// @notice Open (a nonzero `interval`), tune or close the fixing lane. A batch already opened
    /// keeps its tick and deadline.
    function setFixingConfig(FixingConfig calldata fixing_) external onlyOwner {
        StockFixing.checkConfig(fixing_);
        StockStorage.layout().fixing = fixing_;
        emit FixingConfigUpdated();
    }

    function setRoles(address keeper_, address guardian_, address issuer_) external onlyOwner {
        StockLayout storage l = StockStorage.layout();
        (l.keeper, l.guardian, l.issuer) = (keeper_, guardian_, issuer_);
        emit RolesUpdated(keeper_, guardian_, issuer_);
    }

    function setCalendar(MarketCalendar calendar_) external onlyOwner {
        if (address(calendar_) == address(0)) revert ZeroAddress();
        StockStorage.layout().ctx.calendar = calendar_;
        emit CalendarUpdated(address(calendar_));
    }

    function setAllowlist(bool on) external onlyOwner {
        StockStorage.layout().allowlistOn = on;
        emit AllowlistUpdated(on);
    }

    function setDepositor(address depositor, bool allowed) external onlyOwner {
        StockStorage.layout().isDepositor[depositor] = allowed;
        emit DepositorUpdated(depositor, allowed);
    }

    function setCurveOpen(bool open) external onlyOwner {
        StockStorage.layout().state.curveOpen = open;
        emit CurveOpenUpdated(open);
    }

    function unpause(uint8 flags) external onlyOwner {
        StockStorage.layout().state.paused &= ~flags;
        emit Unpaused(flags);
    }

    function clearRestockHalt() external onlyOwner {
        StockStorage.layout().state.restockHalted = false;
        emit RestockHaltCleared();
    }

    /// @notice Accept the current share price after a person has looked at a NAV jump.
    function acceptNav() external onlyOwner {
        StockStorage.layout().state.lastSharePrice = 0;
        emit NavAccepted();
    }

    /// @notice Recover a token sent here by mistake. Never the cash or the stock: the owner cannot
    /// take what depositors own.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        StockContext storage ctx = StockStorage.layout().ctx;
        if (token == Currency.unwrap(ctx.cash) || token == Currency.unwrap(ctx.stock)) revert ProtectedToken(token);
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    function _restockOpen(StockLayout storage l) internal view returns (bool) {
        return l.issuer != address(0) && !l.state.restockHalted && l.state.paused & StockLib.PAUSE_RESTOCK == 0;
    }

    function _delegated() internal view {
        if (address(this) == SELF) revert NotDelegated();
    }

    function _onlyOwner() internal view {
        _delegated();
        if (msg.sender != IOwnerOf(address(this)).owner()) revert NotOwner();
    }

    function _onlyKeeper() internal view {
        _delegated();
        if (msg.sender != StockStorage.layout().keeper) revert NotKeeper();
    }

    function _keeperOrOwner() internal view {
        if (msg.sender != StockStorage.layout().keeper && msg.sender != IOwnerOf(address(this)).owner()) {
            revert NotKeeper();
        }
    }
}

interface IOwnerOf {
    function owner() external view returns (address);
}
