// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {MarketCalendar} from "./MarketCalendar.sol";

/// @notice A stock vault's tunables. The owner sets them inside hard limits that `StockLib`
/// enforces (`checkConfig`). Spreads in bps, times in seconds unless named otherwise, caps and
/// amounts in cash units.
struct StockConfig {
    // -- spread: a session base, plus terms, floored at `minSpread`; over `maxSpread` is refused
    uint16 spreadRegular;
    uint16 spreadExtended; // pre-market and post-market
    uint16 spreadOvernight;
    uint16 spreadClosed; // weekend mode
    uint16 minSpread;
    uint16 maxSpread;
    uint16 agePerSecondBps; // per second of the price's age (not charged when closed)
    uint16 quoteMissingBps; // the market-spread term when the update carries no bid/ask
    uint16 confidenceMissingBps; // the confidence term when the update carries none
    uint16 sizeBps; // at a full per-trade cap
    uint16 windowBps; // at a fully used window
    uint16 skewBps; // inventory lean at a full deviation from target; below `minSpread`
    uint16 openBps; // for `openWindow` after the regular open
    uint16 reanchorBps; // for `reanchorWide` after a re-anchor
    // -- guards
    uint16 maxJumpBps; // from the anchor
    uint16 hedgeSlippageBps; // a hedge order's worst price, from the reference
    uint16 leverageX10; // hedge margin = notional * 10 / leverageX10
    uint16 navJumpBps; // share price move that stops deposits and withdrawals
    uint16 restockSlippageBps; // how far below the reference a restock's minimum may sit
    uint32 maxAgeMs; // in session, milliseconds
    uint32 closeTolerance; // a closed market's price may be stamped this long before the close
    uint32 openWindow;
    uint32 reanchorDelay;
    uint32 reanchorWide;
    uint32 window; // the fill window the window caps apply to
    uint32 publicHedgeDelay; // how long after a hedge anyone, not only the keeper, may hedge
    uint32 restockDeadline;
    bool weekendFills;
    bool overnightLive; // false: the overnight session is treated as closed, priced at the 20:00 close
    // -- caps
    uint96 maxTrade;
    uint96 maxTradeClosed;
    uint96 windowCap;
    uint96 windowCapClosed;
    uint96 maxInventory;
    uint96 targetInventory;
    uint96 maxUnhedged;
    uint96 hedgeBand;
    uint96 minHedge;
    uint96 cashReserve;
    uint96 tvlCap;
    uint96 restockDailyCap;
    // -- the perp market's ticks, 1e18 format
    uint64 qtyTick;
    uint64 priceTick;
}

/// @notice What a stock vault keeps between calls.
/// @param stockBooked the stock the vault accounts for (token plus claims). A balance above it is
/// a delivery or a windfall not yet booked; one below it means stock left without the vault
/// sending it, and fills stop.
/// @param shortConfirmed the short read back from the position, 1e18 units (positive = short)
/// @param pendingQty the last hedge order's signed size (positive adds to the short), until confirmed
struct StockState {
    string marketId;
    PoolId poolId;
    bool poolRegistered;
    bool stockIsCurrency0;
    bool curveOpen;
    bool restockHalted;
    uint8 paused;
    uint128 anchorPrice;
    uint64 jumpSince;
    uint64 wideUntil;
    uint64 widenUntil;
    uint16 widenBps;
    uint64 windowStart;
    uint96 windowUsed;
    uint256 stockBooked;
    int256 shortConfirmed;
    int256 pendingQty;
    uint64 hedgeBlock;
    uint64 lastHedgeTime;
    bool orderOpen;
    uint64 orderDeadline;
    uint96 orderCash;
    uint128 orderMinOut;
    uint64 restockWindowStart;
    uint96 restockUsed;
    uint256 lastSharePrice;
}

/// @notice What `StockLib` needs of the vault it runs inside.
struct StockContext {
    IVault vault;
    Currency cash;
    Currency stock;
    uint8 cashDecimals;
    uint8 stockDecimals;
    IPriceStore store;
    MarketCalendar calendar;
    uint32 feedId;
}

/// @notice The price a call may act on, and whether it may.
/// @param price 1e18 cash per whole stock unit
/// @param closed the market is closed for this vault (weekend mode)
/// @param sessionStart when the current session began; for a closed market, the close
struct Reference {
    uint256 price;
    uint256 ageMs;
    uint256 quoteBps;
    uint256 confidenceBps;
    bool hasQuote;
    bool hasConfidence;
    bool closed;
    MarketCalendar.Session session;
    uint256 sessionStart;
    Refusal reason;
}

/// @notice One swap as the hook sees it.
/// @param cashIn the taker pays cash for stock
/// @param amount the input on exact input, the output on exact output
struct SwapRequest {
    bool cashIn;
    bool exactInput;
    bool zeroForOne;
    uint160 sqrtPriceLimitX96;
    uint256 amount;
}

struct Fill {
    uint256 amountIn;
    uint256 amountOut;
    uint256 price;
    uint256 spreadBps;
    bool closed;
    Refusal reason;
}

/// @notice Why a swap was not filled.
enum Refusal {
    None,
    Paused,
    Disabled,
    Stale,
    Halted,
    Closed,
    Jump,
    Spread,
    Size,
    Window,
    Inventory,
    InventoryCap,
    Reserve,
    Unhedged,
    Deficit,
    PriceLimit
}

/// @notice Everything a stock vault stores besides its share token and owner, at one fixed slot,
/// so the vault and its extension (`StockVaultExtension`, reached through the vault's fallback by
/// DELEGATECALL) read the same storage without sharing an inheritance chain.
/// @param ctx the vault's fixed facts, copied from its immutables at construction for the
/// extension's use; only `ctx.calendar` ever changes (`setCalendar`)
struct StockLayout {
    StockContext ctx;
    address keeper;
    address guardian;
    address issuer;
    bool allowlistOn;
    mapping(address depositor => bool allowed) isDepositor;
    StockConfig config;
    StockState state;
}

library StockStorage {
    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("choice.stock-vault.layout")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x6d27b7a79d5dd008efcd9972ebf118eccbe15446a45f5b17d3091f277f10db00;

    function layout() internal pure returns (StockLayout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
