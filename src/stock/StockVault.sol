// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {
    ICLHooks,
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {IPriceStore} from "../interfaces/IPriceStore.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {StockFixing} from "./StockFixing.sol";
import {StockLib} from "./StockLib.sol";
import {StockOps} from "./StockOps.sol";
import {
    Fill,
    FixingBatch,
    FixingConfig,
    FixingRequest,
    Refusal,
    StockConfig,
    StockContext,
    StockLayout,
    StockState,
    StockStorage,
    SwapRequest
} from "./StockTypes.sol";

/// @title StockVault
/// @notice A cash vault for one stock: it sells and buys the stock token at a signed Pyth Pro price
/// plus a spread, through the one Choice pool it is the hook of, and holds a perp short against its
/// stock so a depositor's return is the spread and the funding, not the stock's moves.
///
/// **One address, five code bodies.** This contract is the hook, the share token and the entry to
/// both fill lanes. Pricing, guards, hedging and valuation are in `StockLib`; bookkeeping (what a
/// fill changes, the restock order, the checks before shares are priced) in `StockOps`; the fixing
/// lane in `StockFixing`; settings, keeper actions, the hedge triggers and the views in
/// `StockVaultExtension`, which every selector this contract does not know reaches through
/// `fallback`. All four run by DELEGATECALL, as this contract, on its storage, which sits at one
/// fixed slot (`StockStorage`). There is no trust boundary inside a vault, and none of the four can
/// be swapped out: their addresses are fixed at deployment.
///
/// **What a depositor owns.** Shares of the cash, the booked stock at the stored price, the short at
/// margin plus PnL, and the cash of an open restock order (`totalAssets`); never what the vault
/// holds for fixing-lane requesters. Deposits and withdrawals
/// are in cash, priced only while the market is open and the price fresh, after settling the
/// short's funding into its margin. Withdrawals are paid from cash on hand above the reserve.
///
/// **Two lanes.** The instant lane is any swap through the pool. The fixing lane (`commitFixing`,
/// `settleFixing`, `claimFixing`) fills larger committed requests at the one signed update stamped
/// at a fixed tick after each boundary; see `StockFixing`.
///
/// **How it fills.** `beforeSwap` takes the newer of the stored price and a signed update handed in
/// as `hookData`, prices the whole swap off it, and returns a delta that leaves the pool's curve
/// nothing to swap. Fills settle in Choice vault claims (ERC6909): the input is minted to this
/// contract and the output burned from its claims, so a swap moves no token and never touches the
/// Choice vault's single sync slot. A swap it will not fill reverts `NotFillable` while the curve is
/// closed. ⚠️ The pool's `Swap` event carries the curve's amounts, zero for a fill: read `Filled`.
///
/// **Weekend mode.** Only when the `MarketCalendar` says the market is shut AND the stored price is
/// stamped at the close does the vault fill on a frozen price, at `spreadClosed` and the closed caps.
/// A stale price in scheduled hours is an outage, and the vault refuses.
///
/// **How it stays hedged.** `syncHedge` moves the short toward the target inventory while the
/// issuer can restock, and toward the holding when it cannot, once exposure leaves a band; a fill
/// never touches the perp. Orders fill in the block's EndBlocker, so a short is confirmed from the
/// position a block later and counts as unhedged until then.
///
/// **Roles.** The owner (a Safe behind a timelock) sets the tunables inside hard limits in
/// `StockLib`, the roles and the issuer; it cannot sweep the cash or the stock, and the token, feed,
/// market and pool are fixed. The keeper widens the spread, restocks within a daily cap and hedges
/// any time. The guardian and the keeper pause; only the owner unpauses.
contract StockVault is ERC4626, Ownable2Step, ReentrancyGuardTransient, Multicall, IHooks, ILockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap` and the before-swap return delta.
    uint16 public constant BITMAP = (uint16(1) << HOOKS_BEFORE_INITIALIZE_OFFSET)
        | (uint16(1) << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET) | (uint16(1) << HOOKS_BEFORE_SWAP_OFFSET)
        | (uint16(1) << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET);

    ICLPoolManager public immutable POOL_MANAGER;
    IVault public immutable VAULT;
    IPriceStore public immutable PRICE_STORE;
    address public immutable EXTENSION;
    uint32 public immutable FEED_ID;
    Currency internal immutable CASH;
    Currency internal immutable STOCK;
    uint8 internal immutable CASH_DECIMALS;
    uint8 internal immutable STOCK_DECIMALS;

    error ZeroAddress();
    error NotPoolManager();
    error WrongPool();
    error PoolAlreadyRegistered();
    error InitializerNotOwner(address sender);
    error CurveClosed();
    error NotFillable(Refusal reason);
    error NotDepositor(address caller);
    error UnexpectedLock();
    error NotKeeper();

    event PoolRegistered(PoolId indexed poolId, bool stockIsCurrency0);
    event FillRefused(Refusal reason);

    struct Init {
        IERC20 cash;
        IERC20 stock;
        ICLPoolManager poolManager;
        IPriceStore store;
        MarketCalendar calendar;
        address extension;
        uint32 feedId;
        string marketId;
        address owner;
        string name;
        string symbol;
    }

    constructor(Init memory init, StockConfig memory config_)
        ERC20(init.name, init.symbol)
        ERC4626(init.cash)
        Ownable(init.owner)
    {
        if (
            address(init.cash) == address(0) || address(init.stock) == address(0)
                || address(init.poolManager) == address(0) || address(init.store) == address(0)
                || address(init.calendar) == address(0) || init.extension.code.length == 0
                || bytes(init.marketId).length == 0
        ) revert ZeroAddress();
        StockLib.checkConfig(config_);
        POOL_MANAGER = init.poolManager;
        VAULT = IProtocolFees(address(init.poolManager)).vault();
        PRICE_STORE = init.store;
        EXTENSION = init.extension;
        FEED_ID = init.feedId;
        CASH = Currency.wrap(address(init.cash));
        STOCK = Currency.wrap(address(init.stock));
        CASH_DECIMALS = IERC20Metadata(address(init.cash)).decimals();
        STOCK_DECIMALS = IERC20Metadata(address(init.stock)).decimals();

        StockLayout storage l = StockStorage.layout();
        l.ctx = StockContext({
            vault: VAULT,
            cash: CASH,
            stock: STOCK,
            cashDecimals: CASH_DECIMALS,
            stockDecimals: STOCK_DECIMALS,
            store: init.store,
            calendar: init.calendar,
            feedId: init.feedId
        });
        l.allowlistOn = true;
        l.state.marketId = init.marketId;
        l.config = config_;
    }

    /// @notice Every selector this contract does not define runs in `StockVaultExtension`, as this
    /// contract: settings, keeper actions, hedge triggers and views.
    fallback() external {
        address ext = EXTENSION;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return BITMAP;
    }

    /// @notice Cash, booked stock at the stored price, the short at margin plus PnL, and an open
    /// restock order's cash. ⚠️ Accrued funding is counted only once settled; deposits and
    /// withdrawals settle it first, so the previews (which cannot) are off by the unsettled
    /// funding: when it is owed to the short, a deposit mints a little less than `previewDeposit`.
    /// Read `navReady` before trusting this mid-block.
    function totalAssets() public view override returns (uint256) {
        return StockLib.value(StockStorage.layout().state, _ctx());
    }

    /// @notice Whether `totalAssets` is exact right now: no hedge order pending in this block and
    /// no Choice vault lock open.
    function navReady() external view returns (bool) {
        return VAULT.getLocker() == address(0) && StockStorage.layout().state.hedgeBlock != block.number;
    }

    /// @notice What a fill would do now, for a planner; zero amounts and a reason when it would not.
    /// The swap's own price limit is not applied.
    function quoteFill(bool cashIn, uint256 amountSpecified, bool exactInput, bytes calldata hookData)
        external
        view
        returns (Fill memory)
    {
        StockLayout storage l = StockStorage.layout();
        SwapRequest memory w = SwapRequest({
            cashIn: cashIn, exactInput: exactInput, zeroForOne: false, sqrtPriceLimitX96: 0, amount: amountSpecified
        });
        return StockLib.quote(l.config, l.state, _ctx(), w, hookData);
    }

    /// @notice The short to add (positive) or cover (negative) to reach the target, 1e18 units,
    /// against the confirmed short: what `syncHedge` would act on now.
    function hedgeGap() external view returns (int256) {
        StockLayout storage l = StockStorage.layout();
        StockContext memory ctx = _ctx();
        (MarketCalendar.Session session,) = ctx.calendar.sessionAt(block.timestamp);
        bool closed = session == MarketCalendar.Session.Closed
            || (session == MarketCalendar.Session.Overnight && !l.config.overnightLive);
        bool restockOpen =
            !closed && l.issuer != address(0) && !l.state.restockHalted && l.state.paused & StockLib.PAUSE_RESTOCK == 0;
        return StockLib.hedgeGap(l.config, l.state, ctx, StockLib.markPrice(ctx), restockOpen);
    }

    // -------------------------------------------------------------------------------------
    // Hook
    // -------------------------------------------------------------------------------------

    /// @notice Only the owner may create the pool keyed to this hook, only stock against cash, and
    /// only once: an open initializer would let anyone open a look-alike pool this vault would fill.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external returns (bytes4) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (sender != owner()) revert InitializerNotOwner(sender);
        if (address(key.poolManager) != address(POOL_MANAGER)) revert WrongPool();
        bool stockIs0 = key.currency0 == STOCK && key.currency1 == CASH;
        if (!stockIs0 && !(key.currency0 == CASH && key.currency1 == STOCK)) revert WrongPool();
        StockState storage s = StockStorage.layout().state;
        if (s.poolRegistered) revert PoolAlreadyRegistered();
        s.poolRegistered = true;
        s.stockIsCurrency0 = stockIs0;
        s.poolId = key.toId();
        emit PoolRegistered(s.poolId, stockIs0);
        return ICLHooks.beforeInitialize.selector;
    }

    /// @notice The curve takes liquidity only once the owner opens it: curve LPs would otherwise be
    /// priced by a curve the vault bypasses.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view returns (bytes4) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        StockState storage s = StockStorage.layout().state;
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(s.poolId)) revert WrongPool();
        if (!s.curveOpen) revert CurveClosed();
        return ICLHooks.beforeAddLiquidity.selector;
    }

    /// @notice Fill the whole swap at the reference price plus the spread, or refuse it.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        StockLayout storage l = StockStorage.layout();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(l.state.poolId)) revert WrongPool();

        bool exactInput = params.amountSpecified < 0;
        SwapRequest memory w = SwapRequest({
            // currency0 goes in when zeroForOne; the taker pays cash when cash is that currency.
            cashIn: l.state.stockIsCurrency0 != params.zeroForOne,
            exactInput: exactInput,
            zeroForOne: params.zeroForOne,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a value whose sign is tested first.
            amount: exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified)
        });
        StockContext memory ctx = _ctx();
        Fill memory f = StockLib.quote(l.config, l.state, ctx, w, hookData);
        if (f.reason != Refusal.None) {
            // 🔴 The pool checks a swap's price limit against the CURVE's price before it sees that
            // the hook took the whole swap. A refused swap that fell through to an empty curve would
            // drive its price to the end of the range and brick every later "no limit" swap in that
            // direction. So while the curve is closed, a refusal reverts.
            if (!l.state.curveOpen) revert NotFillable(f.reason);
            emit FillRefused(f.reason);
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // The input becomes this contract's claim and the output is paid from its claims: the
        // returned delta credits the input and debits the output, so this contract nets to zero.
        StockOps.applyFill(l.config, l.state, ctx, sender, w, f);

        // Specified is what the swapper named: their input on exact input, their output on exact
        // output. Consuming it whole leaves the curve a zero amount to swap.
        (int128 specified, int128 unspecified) = exactInput
            ? (f.amountIn.toInt256().toInt128(), -f.amountOut.toInt256().toInt128())
            : (-f.amountOut.toInt256().toInt128(), f.amountIn.toInt256().toInt128());
        return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecified), 0);
    }

    // -------------------------------------------------------------------------------------
    // Maker hedging (see `StockLib.placeMaker`)
    // -------------------------------------------------------------------------------------

    /// @notice Rest a post-only hedge order at `price` for the gap `syncHedge` would cross the book
    /// for, replacing any resting one. Keeper only.
    /// @return placed whether an order went out (false inside the band)
    function placeMaker(uint256 price) external nonReentrant returns (bool placed) {
        StockLayout storage l = StockStorage.layout();
        if (msg.sender != l.keeper) revert NotKeeper();
        bool restockOpen =
            l.issuer != address(0) && !l.state.restockHalted && l.state.paused & StockLib.PAUSE_RESTOCK == 0;
        return StockLib.placeMaker(l.config, l.state, _ctx(), restockOpen, price);
    }

    /// @notice Cancel the resting maker hedge: the keeper any time, anyone once it has rested
    /// `makerTimeout`.
    function cancelMaker() external nonReentrant {
        StockLayout storage l = StockStorage.layout();
        StockLib.cancelMaker(l.config, l.state, msg.sender == l.keeper);
    }

    // -------------------------------------------------------------------------------------
    // Fixing lane (see `StockFixing`)
    // -------------------------------------------------------------------------------------

    /// @notice Commit `amountIn` (cash when `cashIn`, else stock) to the next boundary's fixing;
    /// `boundary` must be that next one. The input is taken now and held until `claimFixing`.
    /// @return id the request
    function commitFixing(uint64 boundary, bool cashIn, uint256 amountIn, address recipient)
        external
        nonReentrant
        returns (uint256 id)
    {
        return StockFixing.commit(StockStorage.layout(), boundary, cashIn, amountIn, recipient);
    }

    /// @notice Fill the batch for `boundary` at the signed update stamped exactly at its tick.
    function settleFixing(uint64 boundary, bytes calldata update) external nonReentrant {
        StockFixing.settle(StockStorage.layout(), boundary, update);
    }

    /// @notice Pay request `id` to its recipient, once its batch has settled or lapsed.
    function claimFixing(uint256 id) external nonReentrant returns (uint256 out, uint256 refund) {
        return StockFixing.claim(StockStorage.layout(), id);
    }

    function fixingConfig() external view returns (FixingConfig memory) {
        return StockStorage.layout().fixing;
    }

    function fixingBatch(uint64 boundary) external view returns (FixingBatch memory) {
        return StockStorage.layout().batches[boundary];
    }

    function fixingRequest(uint256 id) external view returns (FixingRequest memory) {
        return StockStorage.layout().requests[id];
    }

    /// @inheritdoc ILockCallback
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT) || !StockLib.lockOpen()) revert UnexpectedLock();
        (uint8 op, Currency currency, uint256 amount) = abi.decode(data, (uint8, Currency, uint256));
        if (op == StockLib.OP_TO_CLAIMS) {
            VAULT.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(VAULT), amount);
            VAULT.settle();
            VAULT.mint(address(this), currency, amount);
        } else {
            VAULT.burn(address(this), currency, amount);
            VAULT.take(currency, address(this), amount);
        }
        return "";
    }

    // -------------------------------------------------------------------------------------
    // ERC4626
    // -------------------------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _beforeNav(StockLib.PAUSE_DEPOSITS);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _beforeNav(StockLib.PAUSE_DEPOSITS);
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _beforeNav(StockLib.PAUSE_WITHDRAWALS);
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _beforeNav(StockLib.PAUSE_WITHDRAWALS);
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice Room under the TVL cap; zero while deposits are paused.
    function maxDeposit(address) public view override returns (uint256) {
        StockLayout storage l = StockStorage.layout();
        if (l.state.paused & StockLib.PAUSE_DEPOSITS != 0) return 0;
        uint256 total = totalAssets();
        return l.config.tvlCap > total ? l.config.tvlCap - total : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @notice Withdrawals are paid from cash on hand above the reserve, never by unwinding stock.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (StockStorage.layout().state.paused & StockLib.PAUSE_WITHDRAWALS != 0) return 0;
        return Math.min(_convertToAssets(balanceOf(owner_), Math.Rounding.Floor), _freeCash());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (StockStorage.layout().state.paused & StockLib.PAUSE_WITHDRAWALS != 0) return 0;
        return Math.min(balanceOf(owner_), _convertToShares(_freeCash(), Math.Rounding.Floor));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        StockLayout storage l = StockStorage.layout();
        if (l.allowlistOn && !l.isDepositor[caller] && caller != owner()) revert NotDepositor(caller);
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        StockLib.ensureToken(_ctx(), CASH, assets);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Virtual shares: a first depositor cannot inflate the share price against the next.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    /// @dev Everything a deposit or withdrawal must see before it prices shares (`StockOps.beforeNav`),
    /// then a share price within `navJumpBps` of the last one priced.
    function _beforeNav(uint8 flag) internal {
        StockLayout storage l = StockStorage.layout();
        StockOps.beforeNav(l.config, l.state, _ctx(), flag);
        StockOps.checkSharePrice(l.config, l.state, _convertToAssets(10 ** decimals(), Math.Rounding.Floor));
    }

    function _freeCash() internal view returns (uint256) {
        StockLayout storage l = StockStorage.layout();
        uint256 cash = StockLib.ownCash(l.state, _ctx());
        uint256 reserve = l.config.cashReserve;
        return cash > reserve ? cash - reserve : 0;
    }

    /// @dev The fixed facts from immutables (no storage reads on the fill path) plus the calendar.
    function _ctx() internal view returns (StockContext memory) {
        return StockContext({
            vault: VAULT,
            cash: CASH,
            stock: STOCK,
            cashDecimals: CASH_DECIMALS,
            stockDecimals: STOCK_DECIMALS,
            store: PRICE_STORE,
            calendar: StockStorage.layout().ctx.calendar,
            feedId: FEED_ID
        });
    }
}
