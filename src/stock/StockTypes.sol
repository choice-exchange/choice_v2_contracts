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
    uint32 makerTimeout; // how long a maker hedge may rest before anyone may replace it; zero = off
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
/// @param cashOwed and `stockOwed`: what the vault holds for fixing-lane requesters (inputs in
/// escrow, outputs and refunds not yet claimed). Never the vault's: kept out of its value, its free
/// cash and its stock.
/// @param makerHash the resting maker hedge order, empty when there is none
/// @param makerFillable what of it may still fill, 1e18 units, as last read back
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
    uint128 cashOwed;
    uint128 stockOwed;
    string makerHash;
    bool makerSell;
    uint64 makerPlacedAt;
    uint256 makerFillable;
}

/// @notice The fixing lane's tunables, set by the owner inside the limits in `StockFixing`. A batch
/// keeps the tick and deadline it was opened with, so a change here never moves a committed one.
/// @param interval seconds between boundaries, aligned to the Unix epoch; zero closes the lane to
/// new requests
/// @param delayMs the fixing tick is this long after the boundary, on the 200 ms grid
/// @param settleWindow seconds after the tick a settlement is accepted; after it the batch lapses
/// @param spreadBps the base spread; the confidence, market-spread and size terms, the keeper widen
/// and the re-anchor widen add to it, with no age term
/// @param sizeBps the size term at a net of `maxNet`
/// @param maxSpreadBps a fixing that would need more is refused (and its batch lapses)
/// @param minRequest smallest request, cash value
/// @param maxSide most one side of a batch may carry, cash value
/// @param maxNet most of a batch's net the vault takes on, cash value; beyond it the larger side
/// fills pro rata. It is also the most exposure one fixing can leave unhedged until the hedge
/// follows, so size it to what the perp book takes in one order.
struct FixingConfig {
    uint32 interval;
    uint32 delayMs;
    uint32 settleWindow;
    uint16 spreadBps;
    uint16 sizeBps;
    uint16 maxSpreadBps;
    uint96 minRequest;
    uint96 maxSide;
    uint96 maxNet;
}

/// @notice One side of a batch. Committed amounts until settlement; after it, what is left to claim:
/// each claim takes its share of what remains, so the last one takes the rounding dust and the side
/// ends at zero.
/// @param amountIn input committed (left to claim, after settlement)
/// @param filled the part of `amountIn` that filled; the rest is refunded
/// @param out the output owed for `filled`
struct FixingSide {
    uint128 amountIn;
    uint128 filled;
    uint128 out;
}

/// @notice Every request committed for one boundary: one total per side, settled at one price.
/// @param buy cash in, stock out
/// @param sell stock in, cash out
/// @param tickMs the fixing tick, Unix milliseconds: the one update a settlement may use
/// @param deadline the last second a settlement is accepted
/// @param price the fixing, 1e18 cash per whole stock unit; zero until settled
struct FixingBatch {
    FixingSide buy;
    FixingSide sell;
    uint64 tickMs;
    uint64 deadline;
    uint128 price;
    uint16 spreadBps;
    bool settled;
}

struct FixingRequest {
    address recipient;
    uint64 boundary;
    bool cashIn;
    uint128 amountIn;
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
    FixingConfig fixing;
    uint256 nextRequestId;
    mapping(uint64 boundary => FixingBatch) batches;
    mapping(uint256 id => FixingRequest) requests;
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
