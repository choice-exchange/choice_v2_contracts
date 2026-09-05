// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {IGraduationSettler} from "../interfaces/IGraduationSettler.sol";
import {ILaunchpadCore} from "../interfaces/ILaunchpadCore.sol";
import {LaunchPoolGuardHook} from "./LaunchPoolGuardHook.sol";
import {PositionLocker} from "./PositionLocker.sol";

/// @title InfinitySettler
/// @notice Graduates a SHROOM launchpad launch onto a Choice v2 concentrated-liquidity pool,
/// in the same transaction that fills the curve (plan M4 / D14).
///
/// `LaunchpadCore.triggerGraduation` moves both legs here and calls `settle`. This contract
/// initialises the pool at exactly `realPair / poolTokenAmount`, mints ONE full-range
/// position with both legs to `PositionLocker`, and calls `CORE.onSettled` - all before
/// `triggerGraduation` returns.
///
/// **Why this one can call back and `Phase3Settler` cannot.** The CosmWasm settler forwards
/// into a sink in another VM and the EVM cannot see whether the seed landed, so it leaves the
/// launch in `PendingSettlement` for a keeper to confirm. A CL mint is an EVM call: it either
/// happened in this transaction or the transaction does not exist. So graduation is atomic
/// here, `confirmGraduated` and the keeper crank drop out, and there is no window in which a
/// launch is filled but not tradable.
///
/// **Full range at the curve's own ratio is the whole price policy.** Both legs are consumed
/// entirely (`getLiquidityForAmounts` at `P = amount1/amount0` returns
/// `sqrt(amount0*amount1)` from either side), which is exactly v1's XYK sink: no surplus, no
/// leftover to sweep, and no opening price to choose - that stays a `CurveRegistry` preset
/// concern on the launchpad side.
///
/// **Failure is a revert, never a bad pool.** Anything unexpected - a griefer's pre-initialised
/// pool at an absurd price, a tier misconfiguration, a token that cannot be pulled - reverts
/// `settle`, which reverts `triggerGraduation`, which leaves the launch in `CurveFilled` with
/// every token still in the core. Retry after the owner fixes the cause; the launchpad's
/// `adminForceFail` remains the escape hatch if it cannot be fixed.
contract InfinitySettler is IGraduationSettler, Ownable2Step {
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;
    using Planner for Plan;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------------------
    // `LaunchpadCore` storage layout
    //
    // The deployed core's whole view surface is `ILaunchpadCore` plus `extsload`; `creator`
    // and `creatorFeeShareBps` live in the `internal` `launches` mapping and are reachable
    // only as raw words. These offsets mirror `LaunchpadViews.getLaunch`, which is the
    // launchpad's own decoder for the same layout. The core is not upgradeable, so the layout
    // is frozen at its deploy - and `_readLaunchSplit` checks three canaries anyway, so a
    // core with a different layout fails closed instead of paying a decoded-from-garbage
    // address.
    // -------------------------------------------------------------------------------------

    /// @dev Slot of `mapping(uint256 => Launch) launches` in `LaunchpadCore`.
    uint256 internal constant LAUNCHES_SLOT = 12;
    /// @dev word 0: `state` (uint8) then `creator` (address), packed.
    uint256 internal constant WORD_STATE_CREATOR = 0;
    /// @dev word 7: `settler`.
    uint256 internal constant WORD_SETTLER = 7;
    /// @dev word 21: `tradeFeeBps` (uint16), `creatorFeeShareBps` (uint16), `curveId` (uint16).
    uint256 internal constant WORD_FEE_BPS = 21;

    ILaunchpadCore public immutable CORE;
    ICLPoolManager public immutable CL_POOL_MANAGER;
    ICLPositionManager public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    PositionLocker public immutable LOCKER;

    /// @notice LP fee of the tier launches graduate onto, in pips.
    ///
    /// @dev This is the LP leg, not the tier: 6722 is what the deployed `ChoiceFeeController`
    /// returns from `getLPFeeFromTotalFee(10_000)`, i.e. the 1.00% tier of plan §4 once the
    /// 33% protocol share is taken off the input first. Putting the tier number here instead
    /// would silently overcharge every graduated pool.
    uint24 public lpFee = 6722;

    /// @notice Tick spacing of that tier.
    int24 public tickSpacing = 200;

    /// @notice The hook every graduation pool is keyed to.
    ///
    /// @dev `LaunchPoolGuardHook` permissions `beforeInitialize` to this settler, which is
    /// what makes the pool un-campable - see that contract for the attack. It is configuration
    /// rather than an immutable because `lpFee`, `tickSpacing` and `hooks` jointly ARE the
    /// pool key, and a future `LaunchFeeHook` (plan D11) has to be reachable without
    /// redeploying this. Changing it only affects launches that graduate afterwards; a pool
    /// already created keeps the hook in its identity forever.
    IHooks public hooks;

    /// @notice How far a pre-existing pool's sqrt price may sit from the curve's ratio before
    /// this contract refuses to seed it, in bps of the target sqrt price.
    ///
    /// @dev Initialising an Infinity pool is permissionless and free, and a launch token's
    /// address is public from `bindLaunchToken` onward, so anyone can camp the pool this
    /// contract is going to use and set its price first. Seeding into that pool at the
    /// attacker's price hands them the difference through the first arb. The band means a
    /// pool someone opened at approximately the right price is used as-is, and one opened at
    /// a wrong price reverts the graduation instead. Recovery is `setTier` to a tier the
    /// griefer has not camped, then retry `triggerGraduation` - the launch never left
    /// `CurveFilled` and no funds moved.
    uint16 public priceToleranceBps = 100;

    error NotCore();
    error ZeroAddress();
    error ZeroSeed();
    error AmountTooLarge();
    error IdenticalCurrencies(address token);
    error PoolPriceOutOfBand(uint160 existing, uint160 target);
    error PriceOutOfRange(uint256 sqrtPriceX96);
    error ZeroLiquidity();
    error InvalidTier(uint24 lpFee, int24 tickSpacing);
    error HookHasNoCode(address hooks);
    error InvalidToleranceBps(uint16 bps);
    error LayoutMismatch(bytes32 word);

    event LaunchGraduated(
        uint256 indexed launchId,
        PoolId indexed poolId,
        uint256 indexed tokenId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 residue0,
        uint256 residue1
    );
    event PoolConfigUpdated(
        uint24 oldLpFee, int24 oldTickSpacing, IHooks oldHooks, uint24 newLpFee, int24 newTickSpacing, IHooks newHooks
    );
    event PriceToleranceUpdated(uint16 oldBps, uint16 newBps);
    event TokenSwept(Currency indexed currency, address indexed to, uint256 amount);

    constructor(
        ILaunchpadCore _core,
        ICLPoolManager _clPoolManager,
        ICLPositionManager _positionManager,
        IAllowanceTransfer _permit2,
        PositionLocker _locker,
        LaunchPoolGuardHook _hooks,
        address _owner
    ) Ownable(_owner) {
        if (
            address(_core) == address(0) || address(_clPoolManager) == address(0)
                || address(_positionManager) == address(0) || address(_permit2) == address(0)
                || address(_locker) == address(0) || address(_hooks) == address(0) || _owner == address(0)
        ) revert ZeroAddress();

        CORE = _core;
        CL_POOL_MANAGER = _clPoolManager;
        POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        LOCKER = _locker;
        hooks = _hooks;
    }

    // -------------------------------------------------------------------------------------
    // Graduation
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IGraduationSettler
    function settle(uint256 launchId, uint256 poolTokenAmount) external override {
        if (msg.sender != address(CORE)) revert NotCore();

        address token = CORE.getLaunchToken(launchId);
        address pair = address(CORE.getLaunchPairAsset(launchId));
        uint256 realPair = CORE.getLaunchRealPair(launchId);
        if (token == pair) revert IdenticalCurrencies(token);
        // Both legs must be real. A zero seed would mint nothing and graduate a launch onto
        // an empty pool; the core has already moved the tokens by this point, so refusing
        // here is what sends them back with the reverted transaction.
        if (poolTokenAmount == 0 || realPair == 0) revert ZeroSeed();

        // Use exactly what the core transferred: `poolTokenAmount` as passed (the launchpad's
        // S-L2) and `realPair` as recorded, never this contract's own balance. Residue from
        // an earlier graduation, or a donation, must not end up in a later launch's pool.
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = token < pair
            ? (Currency.wrap(token), Currency.wrap(pair), poolTokenAmount, realPair)
            : (Currency.wrap(pair), Currency.wrap(token), realPair, poolTokenAmount);
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert AmountTooLarge();

        int24 spacing = tickSpacing;
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hooks,
            poolManager: IPoolManager(address(CL_POOL_MANAGER)),
            fee: lpFee,
            parameters: poolParameters()
        });

        uint160 sqrtPriceX96 = _initializePool(key, amount0, amount1);

        // Full range, aligned inward to the tier's spacing. Solidity's division truncates
        // toward zero, which moves both bounds *into* the representable range - the divide
        // before the multiply is the alignment, not a precision slip.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 tickUpper = (TickMath.MAX_TICK / spacing) * spacing;
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower || sqrtPriceX96 >= sqrtUpper) revert PriceOutOfRange(sqrtPriceX96);

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, amount0, amount1);
        if (liquidity == 0) revert ZeroLiquidity();

        // Read the split - and with it the three layout canaries - before anything moves, so
        // a core this contract cannot decode fails on a view call rather than after a mint.
        (address creator, uint16 creatorBps) = _readLaunchSplit(launchId);

        uint256 tokenId = POSITION_MANAGER.nextTokenId();
        (uint256 spent0, uint256 spent1) = _mintLockedPosition(key, tickLower, tickUpper, liquidity, amount0, amount1);

        LOCKER.register(launchId, tokenId, creator, creatorBps, key);

        CORE.onSettled(launchId);

        emit LaunchGraduated(
            launchId, key.toId(), tokenId, sqrtPriceX96, liquidity, spent0, spent1, amount0 - spent0, amount1 - spent1
        );
    }

    /// @dev Initialise the pool at the curve's ratio, or validate the price of one that
    /// already exists. Returns the price the mint will actually execute against.
    function _initializePool(PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
        returns (uint160 sqrtPriceX96)
    {
        uint160 target = _targetSqrtPriceX96(amount0, amount1);
        (uint160 existing,,,) = CL_POOL_MANAGER.getSlot0(key.toId());

        if (existing == 0) {
            // 🔴 Directly, NOT through `CLPositionManager.initializePool`. The guard hook is
            // handed `msg.sender` of `CLPoolManager.initialize`, so routing through the
            // position manager would present IT as the caller and the guard would reject us.
            CL_POOL_MANAGER.initialize(key, target);
            return target;
        }

        uint256 diff = existing > target ? existing - target : target - existing;
        if (diff * BPS_DENOMINATOR > uint256(target) * priceToleranceBps) {
            revert PoolPriceOutOfBand(existing, target);
        }
        // Mint against the pool's own price, not the target: liquidity computed at a price
        // the pool does not hold would leave one leg short and the other stranded.
        return existing;
    }

    /// @dev `sqrt(amount1 / amount0) * 2**96`.
    ///
    /// Taken in one step wherever `amount1 * 2**192 / amount0` fits in a word, which is every
    /// realistic launch: that keeps the full 96 bits of precision. Above a raw-unit price of
    /// 2**64 the intermediate overflows, so the fixed point is halved before the square root
    /// and the other 48 bits are shifted back on after it.
    function _targetSqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 sqrtRatio = amount1 < (amount0 << 64)
            ? Math.sqrt(FullMath.mulDiv(amount1, uint256(1) << 192, amount0))
            : Math.sqrt(FullMath.mulDiv(amount1, FixedPoint96.Q96, amount0)) << 48;

        if (sqrtRatio < TickMath.MIN_SQRT_RATIO || sqrtRatio >= TickMath.MAX_SQRT_RATIO) {
            revert PriceOutOfRange(sqrtRatio);
        }
        // The bound above is `MAX_SQRT_RATIO`, which is itself a uint160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtRatio);
    }

    /// @dev Mint the seed position to the locker and report what the pool actually took.
    ///
    /// The caps are the seed amounts themselves, so the mint can never pull more than the
    /// core handed over. It cannot want more either: `getLiquidityForAmounts` floors the
    /// liquidity from each leg, and the pool's own `getAmount{0,1}Delta` rounding-up of that
    /// floored liquidity is bounded by the amount it was derived from - so the requirement is
    /// at most the input on both sides, and the residue is dust.
    function _mintLockedPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 spent0, uint256 spent1) {
        _approvePosm(key.currency0, amount0);
        _approvePosm(key.currency1, amount1);

        uint256 before0 = key.currency0.balanceOfSelf();
        uint256 before1 = key.currency1.balanceOfSelf();

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                tickLower,
                tickUpper,
                uint256(liquidity),
                SafeCast.toUint128(amount0),
                SafeCast.toUint128(amount1),
                address(LOCKER),
                bytes("")
            )
        );
        POSITION_MANAGER.modifyLiquidities(plan.finalizeModifyLiquidityWithSettlePair(key), block.timestamp);

        spent0 = before0 - key.currency0.balanceOfSelf();
        spent1 = before1 - key.currency1.balanceOfSelf();
    }

    /// @dev Infinity's periphery pulls through Permit2, so funding the mint takes two
    /// allowances: the ERC20 one to Permit2, and Permit2's own record of which spender may
    /// use it. Approving the position manager on the ERC20 alone looks right and moves
    /// nothing. Both are set to the maximum and only refreshed when they no longer cover the
    /// seed, so the common graduation pays for neither.
    function _approvePosm(Currency currency, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        if (IERC20(token).allowance(address(this), address(PERMIT2)) < amount) {
            SafeERC20.forceApprove(IERC20(token), address(PERMIT2), type(uint256).max);
        }
        (uint160 allowed,,) = PERMIT2.allowance(address(this), token, address(POSITION_MANAGER));
        if (allowed < amount) {
            PERMIT2.approve(token, address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        }
    }

    /// @dev Read `creator` and `creatorFeeShareBps` out of the core's `launches` mapping.
    ///
    /// Three canaries make a layout mismatch impossible to miss, and all three are free: the
    /// state in word 0 must read `PendingSettlement` (the core sets it immediately before
    /// calling `settle`), the settler in word 7 must be this contract (the core dispatched
    /// through that field to get here), and the creator share must be a legal bps. A core
    /// whose layout differs would have to satisfy all three by accident to get past this.
    function _readLaunchSplit(uint256 launchId) internal view returns (address creator, uint16 creatorBps) {
        bytes32 base = keccak256(abi.encode(launchId, LAUNCHES_SLOT));

        bytes32 stateAndCreator = _word(base, WORD_STATE_CREATOR);
        if (uint8(uint256(stateAndCreator)) != uint8(ILaunchpadCore.LaunchState.PendingSettlement)) {
            revert LayoutMismatch(stateAndCreator);
        }
        creator = address(uint160(uint256(stateAndCreator) >> 8));

        bytes32 settlerWord = _word(base, WORD_SETTLER);
        if (address(uint160(uint256(settlerWord))) != address(this)) revert LayoutMismatch(settlerWord);

        bytes32 feeWord = _word(base, WORD_FEE_BPS);
        creatorBps = uint16(uint256(feeWord) >> 16);
        if (creatorBps > BPS_DENOMINATOR) revert LayoutMismatch(feeWord);
    }

    function _word(bytes32 base, uint256 offset) internal view returns (bytes32) {
        return CORE.extsload(bytes32(uint256(base) + offset), 1)[0];
    }

    // -------------------------------------------------------------------------------------
    // Owner
    // -------------------------------------------------------------------------------------

    /// @notice The `parameters` word of the pool key: the hook's own registration bitmap in
    /// the low 16 bits, the tick spacing above it.
    /// @dev Read from the hook rather than stored, so the key can never claim a permission set
    /// the hook does not actually implement - `Hooks.validateHookConfig` rejects that pool
    /// anyway, and a mismatch would surface as an unexplained revert inside a graduation.
    function poolParameters() public view returns (bytes32) {
        IHooks _hooks = hooks;
        uint16 bitmap = address(_hooks) == address(0) ? 0 : _hooks.getHooksRegistrationBitmap();
        return bytes32(uint256(bitmap)).setTickSpacing(tickSpacing);
    }

    /// @notice Point graduations at a different pool: fee tier, spacing, hook.
    ///
    /// @dev These three fields ARE the pool key, so they move together. Takes the LP leg in
    /// pips, not the tier - ask the fee controller for `getLPFeeFromTotalFee(tier)`. Passing
    /// `address(0)` for the hook is allowed but removes the camping guard, so it is only for
    /// a deployment that has some other protection; the normal move is a new hook.
    function setPoolConfig(uint24 newLpFee, int24 newTickSpacing, IHooks newHooks) external onlyOwner {
        // Upstream's own bounds: an LP fee above 100% is unrepresentable and a non-positive
        // spacing bricks the full-range alignment.
        if (newLpFee > 1_000_000 || newTickSpacing <= 0 || newTickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTier(newLpFee, newTickSpacing);
        }
        // A hook with no code answers `getHooksRegistrationBitmap` with empty returndata,
        // which decodes as 0 and would silently key every future pool to a bitmap the pool
        // manager then rejects. Fail here instead, where the error says what is wrong.
        if (address(newHooks) != address(0) && address(newHooks).code.length == 0) {
            revert HookHasNoCode(address(newHooks));
        }
        emit PoolConfigUpdated(lpFee, tickSpacing, hooks, newLpFee, newTickSpacing, newHooks);
        lpFee = newLpFee;
        tickSpacing = newTickSpacing;
        hooks = newHooks;
    }

    function setPriceToleranceBps(uint16 newBps) external onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert InvalidToleranceBps(newBps);
        emit PriceToleranceUpdated(priceToleranceBps, newBps);
        priceToleranceBps = newBps;
    }

    /// @notice Recover dust and donations.
    /// @dev Nothing that belongs to a launch is ever at rest here: `settle` runs inside
    /// `triggerGraduation` and either mints the whole seed or reverts with it. What this
    /// reaches is the rounding residue of past graduations and anything sent here by mistake.
    function sweep(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = currency.balanceOfSelf();
        if (amount > 0) currency.transfer(to, amount);
        emit TokenSwept(currency, to, amount);
    }
}
