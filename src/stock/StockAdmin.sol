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
import {StockQuotes} from "./StockQuotes.sol";
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
    event RestockHaltCleared();
    event NavAccepted();
    event Swept(address indexed token, address indexed to, uint256 amount);

    // -------------------------------------------------------------------------------------
    // Keeper
    // -------------------------------------------------------------------------------------

    /// @notice Order `cash` of stock from the issuer, `memo` appended to the transfer (the issuer's
    /// order format), expecting at least `minStockOut` by the deadline. See `StockOps.restock`.
    function restock(uint256 cash, uint256 minStockOut, bytes calldata memo) external onlyKeeper nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockOps.restock(l.config, l.state, l.ctx, l.issuer, _restockOpen(l), cash, minStockOut, memo);
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
        StockLayout storage l = StockStorage.layout();
        if (msg.sender != l.guardian && msg.sender != l.keeper && msg.sender != _owner()) revert NotPauser();
        l.state.paused |= flags;
        emit Paused(flags, msg.sender);
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

    function setRoles(address keeper_, address guardian_, address issuer_) external onlyOwner {
        StockLayout storage l = StockStorage.layout();
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

    function clearRestockHalt() external onlyOwner {
        StockStorage.layout().state.restockHalted = false;
        emit RestockHaltCleared();
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
