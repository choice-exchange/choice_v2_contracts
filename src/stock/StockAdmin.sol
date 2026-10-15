// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";

import {MarketCalendar} from "./MarketCalendar.sol";
import {StockFixing} from "./StockFixing.sol";
import {StockHedge} from "./StockHedge.sol";
import {StockLib} from "./StockLib.sol";
import {StockModule} from "./StockModule.sol";
import {StockOps} from "./StockOps.sol";
import {StockPricing} from "./StockPricing.sol";
import {StockQuotes} from "./StockQuotes.sol";
import {StockRestock} from "./StockRestock.sol";
import {StockRegistry} from "./StockRegistry.sol";
import {
    FixingConfig,
    IssuerQuote,
    StockConfig,
    StockContext,
    StockLayout,
    StockState,
    StockStorage
} from "./StockTypes.sol";

/// @title StockAdmin
/// @notice The last module in a `StockVault`'s chain: what the owner, the keeper and the guardian do.
/// Reached through `StockPublic`'s fallback, as the vault. One deployment serves every vault.
contract StockAdmin is StockModule {
    using SafeERC20 for IERC20;

    error SpreadWidenTooLarge();
    error ProtectedToken(address token);
    error NotRegistryIssuer(address issuer);

    event Widened(uint16 bps, uint64 until);
    event Paused(uint8 flags, address indexed by);
    event Unpaused(uint8 flags);
    event ConfigUpdated();
    event FixingConfigUpdated();
    event RolesUpdated(address keeper, address guardian, address issuer);
    event QuoteSignerUpdated(address signer);
    event CalendarUpdated(address calendar);
    event DepositorUpdated(address indexed depositor, bool allowed);
    event AllowlistUpdated(bool on);
    event CurveOpenUpdated(bool open);
    event ActionAccepted(uint256 tokenPerShare);
    event MarketMigrated(string marketId);
    event RestockMemoSet(bytes memo);
    event NavAccepted();
    event Swept(address indexed token, address indexed to, uint256 amount);

    // -------------------------------------------------------------------------------------
    // Keeper
    // -------------------------------------------------------------------------------------

    /// @notice Send the issuer a LIMIT order: `amountIn` of cash for at least `limitOut` stock, or
    /// (`sell`) `amountIn` of stock for at least `limitOut` cash, open `expiryUnits` of the issuer's
    /// expiry unit. See `StockRestock.order`.
    function restock(bool sell, uint256 amountIn, uint256 limitOut, uint16 expiryUnits)
        external
        onlyKeeper
        nonReentrant
    {
        StockLayout storage l = StockStorage.layout();
        StockRestock.order(l, _restockOpen(l), sell, amountIn, limitOut, expiryUnits);
    }

    /// @notice Rest a post-only hedge order at `price` for the gap `syncHedge` would cross the book
    /// for, replacing any resting one. See `StockHedge.placeMaker`.
    /// @return placed whether an order went out (false inside the band)
    function placeMaker(uint256 price) external onlyKeeper nonReentrant returns (bool placed) {
        StockLayout storage l = StockStorage.layout();
        return StockHedge.placeMaker(l.config, l.state, l.ctx, _restockOpen(l), price);
    }

    /// @notice Fill a quote the issuer signed, both legs in this transaction. See `StockQuotes`.
    function fillQuote(IssuerQuote calldata q, bytes calldata sig) external onlyKeeper nonReentrant {
        StockQuotes.fill(StockStorage.layout(), q, sig);
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
        _pauser();
        StockStorage.layout().state.paused |= flags;
        emit Paused(flags, msg.sender);
    }

    /// @notice Halt the vault for a corporate action (a split, a merger, a delisting): every price is
    /// refused until the owner accepts it. Guardian, keeper or owner.
    function haltAction() external delegated {
        _pauser();
        StockStorage.layout().ctx.actionHalt = true;
        emit ActionHalted(msg.sender);
    }

    // -------------------------------------------------------------------------------------
    // Owner
    // -------------------------------------------------------------------------------------

    /// @notice Set the tunables, inside the hard limits. The inventory cap is this vault's allocation
    /// under its issuer, and the registry refuses one that would pass the issuer's cap.
    function setConfig(StockConfig calldata config_) external onlyOwner {
        StockOps.checkConfig(config_);
        StockLayout storage l = StockStorage.layout();
        StockRegistry(l.registry).allocate(config_.maxInventory);
        l.config = config_;
        emit ConfigUpdated();
    }

    /// @notice Open (a nonzero `interval`), tune or close the fixing lane. A batch already opened
    /// keeps its tick and deadline.
    function setFixingConfig(FixingConfig calldata fixing_) external onlyOwner {
        StockFixing.checkConfig(fixing_);
        StockStorage.layout().fixing = fixing_;
        emit FixingConfigUpdated();
    }

    /// @notice The keeper, the guardian and the issuer. The issuer is the one the registry fixed for this
    /// vault (or none, which stops memo restocking): restock orders send it the vault's cash and stock.
    function setRoles(address keeper_, address guardian_, address issuer_) external onlyOwner {
        StockLayout storage l = StockStorage.layout();
        if (issuer_ != address(0) && issuer_ != StockRegistry(l.registry).issuerOf(address(this))) {
            revert NotRegistryIssuer(issuer_);
        }
        (l.keeper, l.guardian, l.issuer) = (keeper_, guardian_, issuer_);
        emit RolesUpdated(keeper_, guardian_, issuer_);
    }

    /// @notice Who signs issuer quotes. Replacing it voids every quote outstanding.
    function setQuoteSigner(address signer) external onlyOwner {
        StockStorage.layout().quoteSigner = signer;
        emit QuoteSignerUpdated(signer);
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

    /// @notice End a corporate-action halt at `ratio` tokens per share (1e12 = one), the anchor moved to
    /// the stored price at it in the same call. With a registry, `ratio` must be the one it announces;
    /// the price per token may have moved at most `maxMoveBps` from the anchor (see `StockPricing`).
    function acceptAction(uint56 ratio, uint16 maxMoveBps) external onlyOwner nonReentrant {
        _accept(ratio, maxMoveBps, 0);
    }

    /// @notice `acceptAction` checked against the per-token price the owner expects (1e18) instead of
    /// the pre-halt anchor: for a halt the market has moved more than `MAX_ACTION_MOVE` across.
    function acceptActionAt(uint56 ratio, uint16 maxMoveBps, uint256 expectedPrice) external onlyOwner nonReentrant {
        if (expectedPrice == 0) revert StockLib.BadConfig();
        _accept(ratio, maxMoveBps, expectedPrice);
    }

    function _accept(uint56 ratio, uint16 maxMoveBps, uint256 expectedPrice) private {
        StockLayout storage l = StockStorage.layout();
        StockPricing.acceptAction(l.config, l.state, l.ctx, ratio, maxMoveBps, expectedPrice);
        emit ActionAccepted(ratio);
    }

    /// @notice Move the short to a new perp market, as when the old one is settled ahead of a split.
    /// Only while halted, and with no position, pending hedge or maker order on the old one.
    function migrateMarket(string calldata marketId_) external onlyOwner nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockHedge.migrateMarket(l.state, l.ctx, marketId_);
        emit MarketMigrated(marketId_);
    }

    /// @notice The issuer's order memo, with placeholder bytes 0x01 (amount offered), 0x02 (amount
    /// asked for) and 0x03 (expiry in units), each exactly once. Empty stops memo restocking.
    function setRestockMemo(bytes calldata memo) external onlyOwner {
        if (memo.length != 0) StockRestock.checkMemo(memo);
        StockStorage.layout().restockMemo = memo;
        emit RestockMemoSet(memo);
    }

    /// @notice Accept the current share price after a person has looked at a NAV jump.
    function acceptNav() external onlyOwner {
        StockStorage.layout().state.lastSharePrice = 0;
        emit NavAccepted();
    }

    /// @notice Recover a token sent here by mistake. Never the cash, the stock or the vault's own
    /// shares (queued redemptions sit here in escrow): the owner cannot take what depositors own.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        StockContext storage ctx = StockStorage.layout().ctx;
        if (token == Currency.unwrap(ctx.cash) || token == Currency.unwrap(ctx.stock) || token == address(this)) {
            revert ProtectedToken(token);
        }
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }
}
