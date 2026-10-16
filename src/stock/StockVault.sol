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
import {IStockRatios} from "../interfaces/IStockRatios.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {StockHedge} from "./StockHedge.sol";
import {StockLib} from "./StockLib.sol";
import {StockOps} from "./StockOps.sol";
import {StockPricing} from "./StockPricing.sol";
import {
    DepositLock,
    Fill,
    Reference,
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
/// **One address, several code bodies.** This contract is the hook and the share token. The instant
/// lane's pricing and guards are in `StockPricing`; the short and valuation in `StockHedge`;
/// bookkeeping (what a fill changes, the restock order, the checks before shares are priced) in
/// `StockOps`; the fixing lane in `StockFixing`. Every selector this contract does not know goes
/// through `fallback` to a chain of modules: `StockPublic` (views, permissionless triggers, the fixing
/// lane), then `StockAdmin` (owner, keeper and guardian). All of them run by DELEGATECALL, as this
/// contract, on its storage, which sits at one fixed slot (`StockStorage`). There is no trust boundary
/// inside a vault, and none of them can be swapped out: their addresses are fixed at deployment.
///
/// **What a depositor owns.** Shares of the booked cash, the booked stock at the stored price per token,
/// the hedge subaccount's cash, the short at margin plus PnL, and an open restock order (`totalAssets`);
/// never what the vault holds for fixing-lane requesters and redeemers, nor an arrival not yet booked
/// (`settleRestock`, `syncWindfall`). Deposits and withdrawals
/// are in cash, priced only while the market is open and the price fresh, after settling the
/// short's funding into its margin. Withdrawals are paid from cash on hand above the reserve.
///
/// **Two lanes.** The instant lane is any swap through the pool. The fixing lane (`commitFixing`,
/// `settleFixing`, `claimFixing`, in `StockPublic`) fills larger committed requests at the one signed
/// update stamped at a fixed tick after each boundary; see `StockFixing`.
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
/// **Corporate actions.** Prices are per token: the feed's per-share price divided by the vault's
/// tokens-per-share ratio. A split changes the ratio (announced in `RATIOS`) and the feed together; until
/// the owner accepts the new ratio (`acceptAction`), every price is refused. See `StockPricing.acceptAction`.
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
    /// @notice The first module of the chain every selector this contract does not know reaches.
    address public immutable MODULES;
    uint32 public immutable FEED_ID;
    /// @notice Where tokens-per-share ratio changes are announced; zero when the owner alone sets them.
    IStockRatios public immutable RATIOS;
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
    error NotSelf();
    error SharesLocked(uint256 locked, uint256 until);

    event PoolRegistered(PoolId indexed poolId, bool stockIsCurrency0);
    event FillRefused(Refusal reason);

    struct Init {
        IERC20 cash;
        IERC20 stock;
        ICLPoolManager poolManager;
        IPriceStore store;
        MarketCalendar calendar;
        address modules;
        address registry;
        IStockRatios ratios;
        uint32 feedId;
        string marketId;
        /// @dev The cash's bank denom, as the exchange names it (an MTS token: "erc20:0x…").
        string cashDenom;
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
                || address(init.calendar) == address(0) || init.modules.code.length == 0
                || init.registry.code.length == 0 || bytes(init.marketId).length == 0
                || bytes(init.cashDenom).length == 0
        ) revert ZeroAddress();
        StockOps.checkConfig(config_);
        POOL_MANAGER = init.poolManager;
        VAULT = IProtocolFees(address(init.poolManager)).vault();
        PRICE_STORE = init.store;
        MODULES = init.modules;
        FEED_ID = init.feedId;
        RATIOS = init.ratios;
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
            feedId: init.feedId,
            tokenPerShare: uint56(StockLib.RATIO_ONE),
            actionHalt: false,
            ratios: init.ratios
        });
        l.allowlistOn = true;
        l.registry = init.registry;
        l.state.marketId = init.marketId;
        l.state.cashDenom = init.cashDenom;
        l.config = config_;
    }

    /// @notice Every selector this contract does not define runs in the module chain (`StockPublic`,
    /// then `StockAdmin`), as this contract.
    fallback() external {
        address ext = MODULES;
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

    /// @notice Booked cash, booked stock at the stored price, the hedge subaccount's cash, the short at
    /// margin plus PnL, and an open restock order's stock (see `StockHedge.value`). ⚠️ Accrued funding
    /// is counted only once settled; deposits and
    /// withdrawals settle it first, so the previews (which cannot) are off by the unsettled
    /// funding: when it is owed to the short, a deposit mints a little less than `previewDeposit`.
    /// Read `navReady` before trusting this mid-block.
    function totalAssets() public view override returns (uint256) {
        return StockHedge.value(StockStorage.layout().state, _ctx());
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
        return StockPricing.quote(l.config, l.state, _ctx(), w, hookData);
    }

    /// @notice The short to add (positive) or cover (negative), 1e18 units, against the position as the
    /// exchange has it now: what `syncHedge` would act on, once past the band.
    function hedgeGap() external view returns (int256) {
        StockLayout storage l = StockStorage.layout();
        StockContext memory ctx = _ctx();
        (MarketCalendar.Session session,) = ctx.calendar.sessionAt(block.timestamp);
        bool closed = session == MarketCalendar.Session.Closed
            || (session == MarketCalendar.Session.Overnight && !l.config.overnightLive);
        bool restockOpen = l.issuer != address(0) && l.state.paused & StockLib.PAUSE_RESTOCK == 0;
        return StockHedge.gapNow(l.config, l.state, ctx, restockOpen, closed);
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
        Fill memory f = StockPricing.quote(l.config, l.state, ctx, w, hookData);
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
    // Share escrow, for the redeem queue in the modules
    // -------------------------------------------------------------------------------------

    /// @notice Move `shares` of `owner_` into this contract's escrow for a queued redemption, spending
    /// `spender`'s allowance unless it is the owner or the owner's operator. Callable only by this
    /// contract itself, which is to say by its modules (`StockQueue` runs in them).
    function escrowShares(address owner_, address spender, uint256 shares) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (spender != owner_ && !StockStorage.layout().operators[owner_][spender]) {
            _spendAllowance(owner_, spender, shares);
        }
        _transfer(owner_, address(this), shares);
    }

    /// @notice Burn escrowed shares as their epoch settles. Self only, as above.
    function burnEscrowed(uint256 shares) external {
        if (msg.sender != address(this)) revert NotSelf();
        _burn(address(this), shares);
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

    /// @notice Room under the TVL cap; zero whenever a deposit would be refused now (see `_navOpen`).
    /// The allowlist is not applied: it holds the caller, whom this view does not see, and an outsider
    /// is better told `NotDepositor` than a zero maximum.
    function maxDeposit(address) public view override returns (uint256) {
        StockLayout storage l = StockStorage.layout();
        if (!_navOpen(StockLib.PAUSE_DEPOSITS)) return 0;
        uint256 total = totalAssets();
        return l.config.tvlCap > total ? l.config.tvlCap - total : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @notice Withdrawals are paid from cash on hand above the reserve, never by unwinding stock, and
    /// never from shares a recent deposit locked; zero whenever one would be refused now (see `_navOpen`).
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (!_navOpen(StockLib.PAUSE_WITHDRAWALS)) return 0;
        return Math.min(_convertToAssets(_unlocked(owner_), Math.Rounding.Floor), _freeCash());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (!_navOpen(StockLib.PAUSE_WITHDRAWALS)) return 0;
        return Math.min(_unlocked(owner_), _convertToShares(_freeCash(), Math.Rounding.Floor));
    }

    /// @dev A deposit's shares are locked to their receiver for `depositLock` (see `DepositLock`).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        StockLayout storage l = StockStorage.layout();
        if (l.allowlistOn && !l.isDepositor[caller] && caller != owner()) revert NotDepositor(caller);
        super._deposit(caller, receiver, assets, shares);
        l.state.cashBooked += assets;
        uint256 lock = l.config.depositLock;
        if (lock != 0) {
            DepositLock storage d = l.depositLocks[receiver];
            d.shares = (block.timestamp < d.until ? d.shares : 0) + shares.toUint128();
            d.until = uint64(block.timestamp + lock);
        }
    }

    /// @dev Shares a deposit locked may not leave their holder, by withdrawal, queued redemption or
    /// transfer, until the lock ends: nobody can deposit at the stored price, push a newer signed one and
    /// take the difference straight back out. The vault's own escrow is never locked.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from != address(this) && balanceOf(from) < value + _locked(from)) {
            revert SharesLocked(_locked(from), StockStorage.layout().depositLocks[from].until);
        }
        super._update(from, to, value);
    }

    function _locked(address holder) internal view returns (uint256) {
        DepositLock storage d = StockStorage.layout().depositLocks[holder];
        return block.timestamp < d.until ? d.shares : 0;
    }

    function _unlocked(address holder) internal view returns (uint256) {
        return balanceOf(holder) - _locked(holder);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        StockLib.ensureToken(_ctx(), CASH, assets);
        StockStorage.layout().state.cashBooked -= assets;
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Virtual shares: a first depositor cannot inflate the share price against the next.
    function _decimalsOffset() internal pure override returns (uint8) {
        return StockLib.DECIMALS_OFFSET;
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

    /// @dev Whether `_beforeNav(flag)` would pass now: not paused, no lock open or hedge pending, the
    /// market open and the price fresh, and the share price inside the NAV breaker (judged before the
    /// funding a deposit or withdrawal settles first, which this view cannot). ERC-4626 wants a `max*`
    /// view to answer zero for a call that would revert.
    function _navOpen(uint8 flag) internal view returns (bool) {
        StockLayout storage l = StockStorage.layout();
        StockState storage s = l.state;
        if (s.paused & flag != 0 || VAULT.getLocker() != address(0) || s.hedgeBlock == block.number) return false;
        Reference memory r = StockLib.storedReference(l.config, _ctx());
        if (r.reason != Refusal.None || r.closed) return false;
        uint256 last = s.lastSharePrice;
        return last == 0
            || StockLib.deviationBps(_convertToAssets(10 ** decimals(), Math.Rounding.Floor), last)
                <= l.config.navJumpBps;
    }

    /// @dev Own cash above the reserve and above what the redeem queue is waiting for: the open
    /// epoch's value and an in-kind epoch's unpaid debt. An instant withdrawal never takes cash a
    /// queued one needs.
    function _freeCash() internal view returns (uint256) {
        StockLayout storage l = StockStorage.layout();
        uint256 cash = StockLib.ownCash(l.state, _ctx());
        uint256 held = l.config.cashReserve + l.state.debtOwed
            + _convertToAssets(l.epochs[l.redeemEpoch].shares, Math.Rounding.Ceil);
        return cash > held ? cash - held : 0;
    }

    /// @dev The fixed facts from immutables plus the calendar, the ratio and the action halt, which
    /// share one storage slot: one read on the fill path.
    function _ctx() internal view returns (StockContext memory) {
        StockContext storage stored = StockStorage.layout().ctx;
        return StockContext({
            vault: VAULT,
            cash: CASH,
            stock: STOCK,
            cashDecimals: CASH_DECIMALS,
            stockDecimals: STOCK_DECIMALS,
            store: PRICE_STORE,
            calendar: stored.calendar,
            feedId: FEED_ID,
            tokenPerShare: stored.tokenPerShare,
            actionHalt: stored.actionHalt,
            ratios: RATIOS
        });
    }
}
