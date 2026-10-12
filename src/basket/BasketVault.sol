// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
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

import {AssetConfig, AssetState, BasketContext, BasketLib, FillEnv, Refusal} from "./BasketLib.sol";

/// @title BasketVault
/// @notice A cash vault that sells and buys a basket of issued assets at an oracle price, through
/// Choice pools it is the hook of, and holds a perpetual short against what it owns.
///
/// **What a depositor owns.** Shares of everything the vault holds, valued in its cash token:
/// cash, each issued asset at its oracle price, and each perpetual short at its margin plus
/// unrealised PnL (`totalAssets`). Deposits and withdrawals are in cash only, and a withdrawal is
/// paid from the cash the vault holds.
///
/// **How it trades.** Each asset has one Choice CL pool against the cash token, keyed to this
/// contract as its hook. While the asset's oracle is fresh, `beforeSwap` fills the whole swap
/// itself at the oracle price plus or minus the asset's spread, and returns a delta that leaves
/// the pool's own curve nothing to swap. A swap it will not fill reverts `NotFillable` while the
/// curve is closed (the default), and falls through to the curve once the owner opens it.
///
/// Fills settle entirely in vault claims (ERC6909): the input is minted to this contract and the
/// output is burned from its claims, so the swap path moves no token and never touches the
/// vault's single sync slot.
///
/// ⚠️ **The pool's `Swap` event carries the CURVE's amounts**, which are zero for a filled swap.
/// A fill is recorded by this contract's own `Filled` event.
///
/// **How it stays hedged.** `syncHedge` moves the short in an asset's perpetual market toward the
/// vault's holding of that asset, through the `0x65` exchange precompile from the vault's own
/// default subaccount, whose margin comes straight out of the cash balance. A market order fills
/// in the block's EndBlocker, so the position is read back in a later block; one order per market
/// per block. A fill never calls the precompile: a hedge fault cannot stop the pool.
///
/// **Guards on every fill** (a failed guard is a refusal, never a raw revert): oracle age,
/// a jump breaker against the last price, a per-trade size, a per-window outflow cap, inventory
/// held as claims, a cap on what the vault may hold, the cash it must keep for margin, and a cap
/// on how far holdings may run ahead of the short.
///
/// **Roles.** The owner configures everything and can sweep (this is a proof of concept: only
/// allowlisted depositors may enter). The keeper sets spreads inside owner bounds, orders from
/// the issuer within a daily cap, moves inventory between tokens and claims, and can pause. Either
/// can pause; only the owner resumes. `syncHedge` and `topUpMargin` are permissionless.
contract BasketVault is ERC4626, Ownable2Step, ReentrancyGuardTransient, IHooks, ILockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 internal constant BPS = 10_000;
    uint256 public constant ISSUER_WINDOW = 1 days;

    /// @notice `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap` and the before-swap return delta.
    uint16 public constant BITMAP = (uint16(1) << HOOKS_BEFORE_INITIALIZE_OFFSET)
        | (uint16(1) << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET) | (uint16(1) << HOOKS_BEFORE_SWAP_OFFSET)
        | (uint16(1) << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET);

    ICLPoolManager public immutable POOL_MANAGER;
    IVault public immutable VAULT;
    Currency internal immutable CASH;
    uint8 internal immutable CASH_DECIMALS;

    address public keeper;
    address public issuer;
    bool public paused;
    bool public curveOpen;

    uint256 public depositCap;
    uint256 public cashReserve;
    uint32 public outflowWindow;
    uint256 public issuerDailyCap;
    uint256 public issuerWindowStart;
    uint256 public issuerWindowUsed;
    uint256 public inTransitCash;
    uint256 public lastHedgeBlockAny;

    mapping(address depositor => bool allowed) public isDepositor;
    AssetConfig[] internal _configs;
    mapping(uint256 index => AssetState) public assetState;
    mapping(PoolId poolId => uint256 indexPlusOne) internal _poolAsset;

    error ZeroAddress();
    error NotPoolManager();
    error NotKeeper();
    error NotKeeperOrOwner();
    error UnknownPool(PoolId poolId);
    error UnknownAsset(uint256 index);
    error NotABasketPair(Currency currency0, Currency currency1);
    error PoolAlreadyRegistered(uint256 index);
    error InitializerNotOwner(address sender);
    error WrongPoolManager(address poolManager);
    error CurveClosed();
    error NavNotReady();
    error NotDepositor(address caller);
    error NoIssuer();
    error IssuerCapExceeded(uint256 wanted, uint256 remaining);
    error IssuerTransferFailed();
    error InTransitTooLarge(uint256 amount, uint256 inTransit);
    error UnexpectedLock();
    error NotFillable(Refusal reason);

    event PoolRegistered(uint256 indexed index, PoolId indexed poolId, bool assetIsCurrency0);
    event Filled(
        PoolId indexed poolId, address indexed sender, bool cashIn, uint256 amountIn, uint256 amountOut, uint256 price
    );
    event FillRefused(PoolId indexed poolId, Refusal reason);
    event IssuerOrdered(address indexed token, uint256 amount, uint256 cashValue);
    event InTransitCleared(uint256 amount);
    event SpreadUpdated(uint256 indexed index, uint16 spreadBps);
    event PriceReset(uint256 indexed index, uint256 price);
    event Paused(address indexed by);
    event Unpaused();
    event KeeperUpdated(address keeper);
    event IssuerUpdated(address issuer);
    event DepositorUpdated(address indexed depositor, bool allowed);
    event ParamsUpdated(uint256 depositCap, uint256 cashReserve, uint32 outflowWindow, uint256 issuerDailyCap);
    event CurveOpenUpdated(bool open);
    event Swept(address indexed token, address indexed to, uint256 amount);

    modifier onlyKeeper() {
        _onlyKeeper();
        _;
    }

    modifier onlyKeeperOrOwner() {
        _onlyKeeperOrOwner();
        _;
    }

    /// @param cash the deposit token (6-decimal USDC on mainnet), also the perpetuals' margin
    /// @param poolManager the Choice CL pool manager; the vault is read from it, never passed
    constructor(IERC20 cash, ICLPoolManager poolManager, address owner_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(cash)
        Ownable(owner_)
    {
        if (address(cash) == address(0) || address(poolManager) == address(0)) revert ZeroAddress();
        POOL_MANAGER = poolManager;
        VAULT = IProtocolFees(address(poolManager)).vault();
        CASH = Currency.wrap(address(cash));
        CASH_DECIMALS = IERC20Metadata(address(cash)).decimals();
        outflowWindow = 1 hours;
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return BITMAP;
    }

    function assetCount() external view returns (uint256) {
        return _configs.length;
    }

    function assetConfig(uint256 i) external view returns (AssetConfig memory) {
        return _config(i);
    }

    /// @notice What the vault holds of `currency`: the token itself plus its vault claims.
    function holding(Currency currency) public view returns (uint256) {
        return BasketLib.holding(_ctx(), currency);
    }

    /// @notice The vault's exchange subaccount: its default one, which trades off its bank balance.
    function subaccount() external view returns (string memory) {
        return BasketLib.subaccount();
    }

    /// @notice Cash, plus every asset at its oracle price, plus every short at margin + PnL, plus
    /// what is with the issuer. ⚠️ Funding accrues into a position's margin only when it settles,
    /// so accrued funding is not counted until then.
    function totalAssets() public view override returns (uint256) {
        return holding(CASH) + inTransitCash + BasketLib.basketValue(_configs, assetState, _ctx());
    }

    /// @notice How far asset `i` is from its target inventory, in cash at the oracle price:
    /// positive means buy from the issuer, negative means sell back. Zero with no target.
    function rebalanceGap(uint256 i) external view returns (int256) {
        return BasketLib.rebalanceGap(_config(i), assetState[i], _ctx());
    }

    /// @notice What a fill would do right now, for a planner. Zero amounts with a reason when it would not.
    /// @param cashIn true when the taker pays cash for the asset
    /// @param amountSpecified the input (exact input) or the output (exact output)
    function quoteFill(uint256 i, bool cashIn, uint256 amountSpecified, bool exactInput)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 price, Refusal reason)
    {
        return BasketLib.quote(_config(i), assetState[i], _ctx(), _env(), cashIn, amountSpecified, exactInput, false, 0);
    }

    // -------------------------------------------------------------------------------------
    // Hook
    // -------------------------------------------------------------------------------------

    /// @notice Only the owner may create a pool keyed to this hook, only for a configured asset
    /// paired with the cash token, and only one per asset: an open initializer would let anyone
    /// open a look-alike pool that this vault would then fill.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external returns (bytes4) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (sender != owner()) revert InitializerNotOwner(sender);
        if (address(key.poolManager) != address(POOL_MANAGER)) revert WrongPoolManager(address(key.poolManager));
        (uint256 i, bool assetIsCurrency0) = _resolvePair(key.currency0, key.currency1);
        AssetState storage s = assetState[i];
        if (s.poolRegistered) revert PoolAlreadyRegistered(i);
        PoolId poolId = key.toId();
        s.poolRegistered = true;
        s.assetIsCurrency0 = assetIsCurrency0;
        s.poolId = poolId;
        _poolAsset[poolId] = i + 1;
        emit PoolRegistered(i, poolId, assetIsCurrency0);
        return ICLHooks.beforeInitialize.selector;
    }

    /// @notice The curve takes liquidity only once the owner opens it: until the weekend layer has
    /// a rule for re-pricing a curve the vault has been bypassing, curve LPs would be picked off.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view returns (bytes4) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _poolIndex(key.toId());
        if (!curveOpen) revert CurveClosed();
        return ICLHooks.beforeAddLiquidity.selector;
    }

    /// @notice Fill the whole swap at the oracle price, or leave it to the curve.
    function beforeSwap(address sender, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        PoolId poolId = key.toId();
        uint256 i = _poolIndex(poolId);
        AssetState storage s = assetState[i];

        bool exactInput = params.amountSpecified < 0;
        // forge-lint: disable-next-line(unsafe-typecast) - magnitude of a value whose sign is tested first.
        uint256 amountSpecified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        // currency0 goes in when zeroForOne; the taker pays cash when cash is that currency.
        bool cashIn = s.assetIsCurrency0 != params.zeroForOne;

        AssetConfig storage c = _configs[i];
        (uint256 amountIn, uint256 amountOut, uint256 price, Refusal reason) = BasketLib.quote(
            c, s, _ctx(), _env(), cashIn, amountSpecified, exactInput, params.zeroForOne, params.sqrtPriceLimitX96
        );
        if (reason != Refusal.None) {
            // 🔴 The pool checks a swap's price limit against the curve's price BEFORE it sees that
            // the hook took the whole swap. A refused swap that falls through to an empty curve
            // drives its price to the end of the range, after which every "no limit" swap in that
            // direction reverts, fillable or not. So while the curve is closed a refusal reverts,
            // and quoters and routers drop the pool; only an open curve takes the fall-through.
            if (!curveOpen) revert NotFillable(reason);
            emit FillRefused(poolId, reason);
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (Currency cIn, Currency cOut) = cashIn ? (CASH, Currency.wrap(c.token)) : (Currency.wrap(c.token), CASH);
        // The input becomes this contract's claim and the output is paid from its claims: the
        // returned delta credits the input and debits the output, so this contract nets to zero.
        VAULT.mint(address(this), cIn, amountIn);
        VAULT.burn(address(this), cOut, amountOut);

        s.lastPrice = price.toUint128();
        _spendWindow(
            s, cashIn ? BasketLib.assetToCash(_ctx(), amountOut, price, s.decimals, Math.Rounding.Ceil) : amountOut
        );
        emit Filled(poolId, sender, cashIn, amountIn, amountOut, price);

        // Specified is what the swapper named: their input on exact input, their output on exact
        // output. Consuming it whole leaves the curve a zero amount to swap.
        (int128 specified, int128 unspecified) = exactInput
            ? (amountIn.toInt256().toInt128(), -amountOut.toInt256().toInt128())
            : (-amountOut.toInt256().toInt128(), amountIn.toInt256().toInt128());
        return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecified), 0);
    }

    // -------------------------------------------------------------------------------------
    // Hedge
    // -------------------------------------------------------------------------------------

    /// @notice Move asset `i`'s short toward the vault's holding of it, in one market order.
    /// Permissionless: the target is the vault's own state, the order's worst price is the oracle
    /// price moved by the asset's hedge slippage, and only one order goes out per market per block.
    function syncHedge(uint256 i) external nonReentrant returns (string memory orderHash) {
        orderHash = BasketLib.syncHedge(_config(i), assetState[i], i, _ctx());
        lastHedgeBlockAny = block.number;
    }

    /// @notice Bring asset `i`'s short back to its target leverage once its margin has fallen
    /// below 70% of that. Permissionless: it only ever adds the vault's cash to its own position.
    function topUpMargin(uint256 i) external nonReentrant {
        BasketLib.topUpMargin(_config(i), i, _ctx());
    }

    // -------------------------------------------------------------------------------------
    // ERC4626
    // -------------------------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice Room under the deposit cap; zero while paused.
    function maxDeposit(address) public view override returns (uint256) {
        if (paused) return 0;
        uint256 total = totalAssets();
        return depositCap > total ? depositCap - total : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @notice A withdrawal is paid from the cash the vault holds, never by unwinding inventory.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(_convertToAssets(balanceOf(owner_), Math.Rounding.Floor), holding(CASH));
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return Math.min(balanceOf(owner_), _convertToShares(holding(CASH), Math.Rounding.Floor));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (!isDepositor[caller] && caller != owner()) revert NotDepositor(caller);
        _requireNavReady();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _requireNavReady();
        BasketLib.ensureToken(_ctx(), CASH, assets);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Virtual shares: a first depositor cannot inflate the share price against the next.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // -------------------------------------------------------------------------------------
    // Keeper
    // -------------------------------------------------------------------------------------

    function setSpread(uint256 i, uint16 spreadBps) external onlyKeeperOrOwner {
        AssetConfig storage c = _config(i);
        if (spreadBps < c.minSpreadBps || spreadBps > c.maxSpreadBps) {
            revert BasketLib.SpreadOutOfBounds(spreadBps, c.minSpreadBps, c.maxSpreadBps);
        }
        c.spreadBps = spreadBps;
        emit SpreadUpdated(i, spreadBps);
    }

    /// @notice Re-anchor the jump breaker at the current oracle price, after a person has looked.
    function resetPrice(uint256 i) external onlyKeeperOrOwner {
        AssetConfig storage c = _config(i);
        uint256 price = BasketLib.markPrice(c);
        assetState[i].lastPrice = price.toUint128();
        emit PriceReset(i, price);
    }

    /// @notice An order to the issuer: `amount` of the cash token or an asset, sent with `memo`
    /// appended after the transfer's arguments, which is the issuer's order format. Only to the
    /// owner-set issuer, only cash or a configured asset, and within a daily cap. The value sent
    /// is carried in `inTransitCash` until the keeper clears it.
    function issuerOrder(address token, uint256 amount, bytes calldata memo) external onlyKeeper nonReentrant {
        if (issuer == address(0)) revert NoIssuer();
        uint256 value = BasketLib.cashValue(_configs, assetState, _ctx(), token, amount);
        if (block.timestamp >= issuerWindowStart + ISSUER_WINDOW) {
            issuerWindowStart = block.timestamp;
            issuerWindowUsed = 0;
        }
        uint256 remaining = issuerDailyCap > issuerWindowUsed ? issuerDailyCap - issuerWindowUsed : 0;
        if (value > remaining) revert IssuerCapExceeded(value, remaining);
        issuerWindowUsed += value;
        inTransitCash += value;

        BasketLib.ensureToken(_ctx(), Currency.wrap(token), amount);
        (bool ok, bytes memory ret) =
            token.call(abi.encodePacked(abi.encodeCall(IERC20.transfer, (issuer, amount)), memo));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert IssuerTransferFailed();
        emit IssuerOrdered(token, amount, value);
    }

    /// @notice Take value out of `inTransitCash` once the issuer has delivered (or refunded) it.
    function clearInTransit(uint256 amount) external onlyKeeperOrOwner {
        if (amount > inTransitCash) revert InTransitTooLarge(amount, inTransitCash);
        inTransitCash -= amount;
        emit InTransitCleared(amount);
    }

    /// @notice Move `amount` of the vault's own `currency` from the token into vault claims, which
    /// is what fills pay out of.
    function toClaims(Currency currency, uint256 amount) external onlyKeeperOrOwner nonReentrant {
        BasketLib.lock(_ctx(), BasketLib.OP_TO_CLAIMS, currency, amount);
    }

    /// @notice Move `amount` of the vault's claims back into the token (for margin, the issuer, a withdrawal).
    function fromClaims(Currency currency, uint256 amount) external onlyKeeperOrOwner nonReentrant {
        BasketLib.lock(_ctx(), BasketLib.OP_FROM_CLAIMS, currency, amount);
    }

    function pause() external onlyKeeperOrOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc ILockCallback
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT) || !BasketLib.lockOpen()) revert UnexpectedLock();
        (uint8 op, Currency currency, uint256 amount) = abi.decode(data, (uint8, Currency, uint256));
        if (op == BasketLib.OP_TO_CLAIMS) {
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
    // Owner
    // -------------------------------------------------------------------------------------

    function addAsset(AssetConfig calldata c) external onlyOwner returns (uint256) {
        return BasketLib.setAsset(_configs, assetState, type(uint256).max, c, Currency.unwrap(CASH));
    }

    /// @notice Change an asset's terms. Its token is fixed once its pool exists.
    function updateAsset(uint256 i, AssetConfig calldata c) external onlyOwner {
        _config(i);
        BasketLib.setAsset(_configs, assetState, i, c, Currency.unwrap(CASH));
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    function setIssuer(address issuer_) external onlyOwner {
        issuer = issuer_;
        emit IssuerUpdated(issuer_);
    }

    function setDepositor(address depositor, bool allowed) external onlyOwner {
        isDepositor[depositor] = allowed;
        emit DepositorUpdated(depositor, allowed);
    }

    function setParams(uint256 depositCap_, uint256 cashReserve_, uint32 outflowWindow_, uint256 issuerDailyCap_)
        external
        onlyOwner
    {
        if (outflowWindow_ == 0) revert BasketLib.BadConfig();
        depositCap = depositCap_;
        cashReserve = cashReserve_;
        outflowWindow = outflowWindow_;
        issuerDailyCap = issuerDailyCap_;
        emit ParamsUpdated(depositCap_, cashReserve_, outflowWindow_, issuerDailyCap_);
    }

    function setCurveOpen(bool open) external onlyOwner {
        curveOpen = open;
        emit CurveOpenUpdated(open);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    /// @notice Send the vault's own tokens anywhere. ⚠️ The owner can empty the vault: this is
    /// a proof of concept whose depositors are allowlisted. Never open deposits with it in place.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // -------------------------------------------------------------------------------------
    // Pricing
    // -------------------------------------------------------------------------------------

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    function _requireNavReady() internal view {
        // Mid-lock, claims and deltas are in flight; the block of a hedge order holds margin that
        // is not yet a position; a stale oracle would price shares at a frozen NAV.
        if (VAULT.getLocker() != address(0) || lastHedgeBlockAny == block.number) revert NavNotReady();
        BasketLib.requireFresh(_configs);
    }

    function _spendWindow(AssetState storage s, uint256 value) internal {
        if (block.timestamp >= uint256(s.windowStart) + outflowWindow) {
            s.windowStart = uint64(block.timestamp);
            s.windowUsed = 0;
        }
        s.windowUsed += value.toUint96();
    }

    function _resolvePair(Currency currency0, Currency currency1)
        internal
        view
        returns (uint256 i, bool assetIsCurrency0)
    {
        bool known;
        if (Currency.unwrap(currency1) == Currency.unwrap(CASH)) {
            (known, i) = _indexOf(Currency.unwrap(currency0));
            assetIsCurrency0 = true;
        } else if (Currency.unwrap(currency0) == Currency.unwrap(CASH)) {
            (known, i) = _indexOf(Currency.unwrap(currency1));
        }
        if (!known) revert NotABasketPair(currency0, currency1);
    }

    function _indexOf(address token) internal view returns (bool, uint256) {
        uint256 n = _configs.length;
        for (uint256 i; i < n; ++i) {
            if (_configs[i].token == token) return (true, i);
        }
        return (false, 0);
    }

    function _poolIndex(PoolId poolId) internal view returns (uint256) {
        uint256 j = _poolAsset[poolId];
        if (j == 0) revert UnknownPool(poolId);
        return j - 1;
    }

    function _config(uint256 i) internal view returns (AssetConfig storage) {
        if (i >= _configs.length) revert UnknownAsset(i);
        return _configs[i];
    }

    function _env() internal view returns (FillEnv memory) {
        return FillEnv({paused: paused, outflowWindow: outflowWindow, cashReserve: cashReserve});
    }

    function _ctx() internal view returns (BasketContext memory) {
        return BasketContext({vault: VAULT, cash: CASH, cashDecimals: CASH_DECIMALS});
    }

    function _onlyKeeper() internal view {
        if (msg.sender != keeper) revert NotKeeper();
    }

    function _onlyKeeperOrOwner() internal view {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeperOrOwner();
    }
}
