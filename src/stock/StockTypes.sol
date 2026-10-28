// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {IStockRatios} from "../interfaces/IStockRatios.sol";
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
    uint32 restockDeadline; // after a restock order's expiry, how long before anyone may close it
    uint32 restockExpiryUnit; // seconds per unit of a restock order's expiry, as the issuer counts it
    uint32 makerTimeout; // how long a maker hedge may rest before anyone may replace it; zero = off
    uint32 queueDeadline; // how long a redeem epoch may wait before anyone may settle it in kind
    uint16 exitFeeBps; // charged on a queued exit's cash, kept by those who stay, to cover the unwind
    bool weekendFills;
    bool overnightLive; // false: the overnight session is priced as closed (a price moved since the 20:00 close must still be fresh)
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
    uint96 minRedeem; // smallest queued redemption, cash value
    // -- the perp market's ticks, 1e18 format
    uint64 qtyTick;
    uint64 priceTick;
    // -- exits
    uint32 depositLock; // how long the shares a deposit mints stay with their receiver; zero = off
    // -- flow and scarcity (last, so every field above keeps its ABI word)
    uint16 scarcityBps; // added to the ask as the stock left falls under `scarcityReserve`, and taken off the bid as free cash does; in full at none left
    uint96 netCap; // the net bucket: stock value out less cash out, draining over `window`; between `maxTrade` and `windowCap`
    uint96 closedNetCap; // net stock value out, either way, over one closed period
    uint96 scarcityReserve; // zero = no scarcity premium
}

/// @notice What a stock vault keeps between calls.
/// @param stockBooked the stock the vault accounts for (token plus claims, less `stockOwed`). A balance above it is
/// a delivery or a windfall not yet booked; one below it means stock left without the vault
/// sending it, and fills stop.
/// @param shortConfirmed the short read back from the position, 1e18 units (positive = short)
/// @param pendingQty the last hedge order's signed size (positive adds to the short), until confirmed
/// @param cashOwed and `stockOwed`: what the vault holds for fixing-lane requesters (inputs in
/// escrow, outputs and refunds not yet claimed). Never the vault's: kept out of its value, its free
/// cash and its stock.
/// @param debtOwed cash an in-kind redeem epoch is owed but not yet paid: out of the vault's value
/// from the moment it is owed
/// @param orderSell the open restock order sells stock; otherwise it buys
/// @param orderCash a buy's cash sent, or a sell's cash asked for (its limit)
/// @param orderStock a buy's stock asked for (its limit), or a sell's stock sent
/// @param orderDeadline past which the owner may write the open order off: its expiry plus `restockDeadline`
/// @param makerHash the resting maker hedge order, empty when there is none
/// @param makerFillable what of it may still fill, 1e18 units, as last read back
/// @param orderWindow the restock-cap window the open order was counted in
/// @param orderCounted the cash it counted against that window's cap
/// @param cashBooked the cash the vault accounts for (token plus claims, less `cashOwed`). The short
/// trades from its own exchange subaccount, so only the vault's own calls move this balance, besides
/// arrivals: one above it is an issuer's payment or refund, a windfall, or the relayer share of the
/// short's own fees (dust, whole units only), not yet booked
/// @param cashDenom the cash's bank denom, which the exchange names it by; fixed at construction
/// @param jumpPrice the price a jump from the anchor was first seen at, with `jumpSince`: a later reading
/// unlike it is a new jump, and its clock starts again
/// @param positionLost the short was found gone with no order of the vault's to explain it (a
/// liquidation, a forced settlement, or a market paused, whose positions the exchange does not list):
/// no share is priced, and no market migration, until the owner has looked and accepted the NAV
/// @param flowAt when the flow buckets were last brought up to date. Each drains its whole cap over
/// `window`, continuously, so no moment resets one (see `StockLib.flowNow`).
/// @param grossUsed the gross bucket's fill, as a share of the gross cap in force (`StockLib.FULL` = full)
/// @param netUsed the net bucket's fill, as a share of `netCap`: buys (stock out) up, sells down
/// @param closedStart the closed period `closedNet` counts in, by its start
/// @param closedNet net stock value out over that period, cash units: buys up, sells down
/// @param fundingUnsettledSince when the short's funding was first refused a settlement, since the last
/// one that went through; zero while it settles (see `StockOps.beforeNav`)
struct StockState {
    string marketId;
    PoolId poolId;
    bool poolRegistered;
    bool stockIsCurrency0;
    bool curveOpen;
    uint8 paused;
    uint128 anchorPrice;
    uint64 jumpSince;
    uint64 wideUntil;
    uint64 widenUntil;
    uint16 widenBps;
    uint64 flowAt;
    uint64 grossUsed;
    int64 netUsed;
    uint256 stockBooked;
    int256 shortConfirmed;
    int256 pendingQty;
    uint64 hedgeBlock;
    uint64 lastHedgeTime;
    bool orderOpen;
    bool orderSell;
    uint64 orderDeadline;
    uint96 orderCash;
    uint128 orderStock;
    uint64 restockWindowStart;
    uint96 restockUsed;
    uint256 lastSharePrice;
    uint128 cashOwed;
    uint128 stockOwed;
    uint128 debtOwed;
    string makerHash;
    bool makerSell;
    uint64 makerPlacedAt;
    uint256 makerFillable;
    uint64 orderWindow;
    uint96 orderCounted;
    uint256 cashBooked;
    string cashDenom;
    uint128 jumpPrice;
    bool positionLost;
    uint64 closedStart;
    int128 closedNet;
    uint64 fundingUnsettledSince;
}

/// @notice The shares deposits minted to one holder that may not leave it before `until`. A deposit
/// adds its shares and restarts the clock while earlier ones are still held, so each deposit is held
/// the whole `depositLock`; shares the holder had before are free.
struct DepositLock {
    uint64 until;
    uint128 shares;
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

/// @notice A quote the issuer signs (EIP-712, domain = the vault) for one atomic restock.
/// @param vaultBuys the vault pays `cash` for `stock`; otherwise it sells `stock` for `cash`
struct IssuerQuote {
    bool vaultBuys;
    uint256 stock;
    uint256 cash;
    uint256 nonce;
    uint64 expiry;
}

/// @notice One redeem epoch: every request queued while it was open, settled together.
/// @param shares escrowed when the epoch closed; `sharesLeft` is what is still to claim
/// @param cash and `stock`: what is left to claim, paid pro rata on what remains (the last claim
/// takes the dust); `debt` is cash owed to an in-kind epoch until the short is cut
/// @param status 0 open, 1 in kind and waiting for its debt, 2 settled
/// @param feeBps the exit fee when the epoch opened: a queued request cannot be cancelled, so a later
/// raise never applies to it
struct RedeemEpoch {
    uint128 shares;
    uint128 sharesLeft;
    uint128 cash;
    uint128 stock;
    uint128 debt;
    uint64 openedAt;
    uint8 status;
    uint16 feeBps;
}

/// @notice A controller's place in the queue: its latest request, and what earlier settled ones left
/// it to claim.
struct RedeemAccount {
    uint64 epoch;
    uint128 shares;
    uint128 claimShares;
    uint128 claimCash;
    uint128 claimStock;
}

struct FixingRequest {
    address recipient;
    uint64 boundary;
    bool cashIn;
    uint128 amountIn;
}

/// @notice What `StockLib` needs of the vault it runs inside.
/// @param tokenPerShare how many stock tokens make one share of the feed and the perp, `StockLib.RATIO_ONE`
/// = one; it changes only when the owner accepts a corporate action
/// @param actionHalt a corporate action is pending: every reference is refused until the owner accepts it
/// @param ratios where ratio changes are announced; zero when the owner alone sets them
struct StockContext {
    IVault vault;
    Currency cash;
    Currency stock;
    uint8 cashDecimals;
    uint8 stockDecimals;
    IPriceStore store;
    MarketCalendar calendar;
    uint32 feedId;
    uint56 tokenPerShare;
    bool actionHalt;
    IStockRatios ratios;
    uint32 cashFeedId;
}

/// @notice The price a call may act on, and whether it may.
/// @param price 1e18 cash per whole stock token
/// @param sharePrice 1e18 cash per share, as the feed and the perp quote it
/// @param closed the market is closed for this vault (weekend mode)
/// @param sessionStart when the current session began; for a closed market, the close
struct Reference {
    uint256 price;
    uint256 sharePrice;
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
    PriceLimit,
    Action,
    Net,
    ClosedNet
}

/// @notice Everything a stock vault stores besides its share token and owner, at one fixed slot,
/// so the vault and its modules (`StockPublic`, `StockAdmin`, reached through the vault's fallback by
/// DELEGATECALL) read the same storage without sharing an inheritance chain.
/// @param ctx the vault's fixed facts, copied from its immutables at construction for the
/// modules' use; only the calendar, the ratio and the action halt ever change
/// @param restockMemo the issuer's order memo with three placeholder bytes, 0x01 the amount offered,
/// 0x02 the amount asked for and 0x03 the expiry in units, filled in by the vault on each order
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
    address registry;
    address quoteSigner;
    mapping(uint256 nonce => bool) quoteUsed;
    uint64 redeemEpoch;
    uint64 unwinding;
    mapping(uint64 epoch => RedeemEpoch) epochs;
    mapping(address controller => RedeemAccount) redeems;
    mapping(address controller => mapping(address operator => bool)) operators;
    bytes restockMemo;
    mapping(address holder => DepositLock) depositLocks;
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
