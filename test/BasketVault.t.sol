// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";

import {BasketVault} from "../src/basket/BasketVault.sol";
import {AssetConfig, BasketLib, Refusal} from "../src/basket/BasketLib.sol";
import {ChoiceAggregator} from "../src/router/ChoiceAggregator.sol";
import {SubaccountLib} from "../src/libraries/SubaccountLib.sol";
import {MockOraclePrecompile, MockExchangePrecompile} from "./mocks/BasketMocks.sol";
import {MockWINJ} from "./mocks/AggregatorMocks.sol";

/// The real `Vault` + `CLPoolManager`, one USDC-like CASH (6 decimals) / ASSET (18) pool keyed to
/// the basket as its hook, and the oracle and exchange precompiles mocked at their addresses.
contract BasketVaultTest is Test, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;

    address internal constant OWNER = address(0x0A11);
    address internal constant KEEPER = address(0x0B22);
    address internal constant ISSUER = address(0x155E);
    address internal constant TRADER = address(0x7AD3);
    address internal constant DEPOSITOR = address(0xDE90);
    address internal constant ORACLE = 0x0000000000000000000000000000000000000067;
    address internal constant EXCHANGE = 0x0000000000000000000000000000000000000065;
    string internal constant FEED = "7";
    string internal constant MARKET = "0x00000000000000000000000000000000000000000000000000000000000000aa";
    uint256 internal constant PRICE = 300e18;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal router;
    BasketVault internal basket;
    MockERC20 internal cash;
    MockERC20 internal asset;
    PoolKey internal key;
    PoolId internal poolId;
    bool internal cashIs0;

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new Vault();
        manager = new CLPoolManager(vault);
        vault.registerApp(address(manager));
        router = new CLPoolManagerRouter(vault, manager);

        cash = new MockERC20("CASH", "CASH", 6);
        asset = new MockERC20("ASSET", "ASSET", 18);
        cashIs0 = address(cash) < address(asset);

        vm.etch(ORACLE, address(new MockOraclePrecompile()).code);
        vm.etch(EXCHANGE, address(new MockExchangePrecompile()).code);
        MockExchangePrecompile(EXCHANGE).setCash(cash);
        _price(PRICE);

        basket = new BasketVault(IERC20(address(cash)), ICLPoolManager(address(manager)), OWNER, "Basket", "BSK");
        vm.startPrank(OWNER);
        basket.addAsset(_config());
        basket.setKeeper(KEEPER);
        basket.setIssuer(ISSUER);
        basket.setParams(1_000_000e6, 0, 1 hours, 10_000e6);
        basket.setDepositor(DEPOSITOR, true);
        key = _key(address(basket), 3000);
        poolId = key.toId();
        manager.initialize(key, _oracleSqrtPrice());
        vm.stopPrank();

        // 10,000 cash deposited, 30 ASSET delivered by the issuer, most of both turned into claims.
        cash.mint(OWNER, 10_000e6);
        vm.startPrank(OWNER);
        cash.approve(address(basket), type(uint256).max);
        basket.deposit(10_000e6, OWNER);
        vm.stopPrank();
        asset.mint(address(basket), 30 ether);
        vm.startPrank(KEEPER);
        basket.toClaims(Currency.wrap(address(cash)), 9_000e6);
        basket.toClaims(Currency.wrap(address(asset)), 30 ether);
        vm.stopPrank();

        cash.mint(TRADER, 1_000_000e6);
        asset.mint(TRADER, 1_000 ether);
        vm.startPrank(TRADER);
        cash.approve(address(router), type(uint256).max);
        asset.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _config() internal view returns (AssetConfig memory) {
        return AssetConfig({
            token: address(asset),
            oracleType: 14,
            enabled: true,
            spreadBps: 25,
            minSpreadBps: 5,
            maxSpreadBps: 200,
            leverageX10: 30,
            maxJumpBps: 1500,
            hedgeSlippageBps: 60,
            maxAge: 60,
            qtyTick: 1e15,
            priceTick: 1e16,
            maxTradeCash: 5_000e6,
            maxInventoryCash: 50_000e6,
            maxUnhedgedCash: 20_000e6,
            windowCap: 20_000e6,
            minHedgeCash: 1e6,
            targetCash: 0,
            skewBps: 0,
            feedId: FEED,
            marketId: MARKET
        });
    }

    function _key(address hooks, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(cashIs0 ? address(cash) : address(asset)),
            currency1: Currency.wrap(cashIs0 ? address(asset) : address(cash)),
            hooks: IHooks(hooks),
            poolManager: IPoolManager(address(manager)),
            fee: fee,
            parameters: bytes32(uint256(basket.BITMAP())).setTickSpacing(60)
        });
    }

    /// The curve's starting price at the oracle: currency1 per currency0, in raw units.
    function _oracleSqrtPrice() internal view returns (uint160) {
        uint256 priceX192 = cashIs0 ? (uint256(1e18) << 192) / 300e6 : (uint256(300e6) << 192) / 1e18;
        return uint160(Math.sqrt(priceX192));
    }

    function _price(uint256 price) internal {
        MockOraclePrecompile(ORACLE).set(FEED, price, uint64(block.timestamp));
    }

    function _swap(bool cashIn, bool exactInput, uint256 amount) internal {
        _swapLimit(cashIn, exactInput, amount, 0);
    }

    function _swapLimit(bool cashIn, bool exactInput, uint256 amount, uint160 limit) internal {
        bool zeroForOne = cashIn == cashIs0;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        vm.prank(TRADER);
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: limit
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    function _ask() internal pure returns (uint256) {
        return Math.mulDiv(PRICE, 10_025, 10_000, Math.Rounding.Ceil);
    }

    function _bid() internal pure returns (uint256) {
        return PRICE * 9_975 / 10_000;
    }

    function _claims(MockERC20 t) internal view returns (uint256) {
        return vault.balanceOf(address(basket), Currency.wrap(address(t)));
    }

    /// While the curve is closed a refusal reverts, wrapped by the pool manager's hook call.
    function _expectRefusal(Refusal r) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(basket),
                ICLHooks.beforeSwap.selector,
                abi.encodeWithSelector(BasketVault.NotFillable.selector, r),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _sub() internal view returns (string memory) {
        return SubaccountLib.defaultSubaccount(address(basket));
    }

    // ── fills ─────────────────────────────────────────────────────────────

    function test_buyExactInputFillsAtTheAsk() public {
        uint256 cashBefore = cash.balanceOf(TRADER);
        (uint160 sqrtBefore,,,) = manager.getSlot0(poolId);
        uint256 out = Math.mulDiv(300e6, 1e30, _ask());

        _swap(true, true, 300e6);

        assertEq(cashBefore - cash.balanceOf(TRADER), 300e6, "paid");
        assertEq(asset.balanceOf(TRADER), 1_000 ether + out, "received");
        assertEq(_claims(cash), 9_300e6, "cash claim");
        assertEq(_claims(asset), 30 ether - out, "asset claim");
        (uint160 sqrtAfter,,,) = manager.getSlot0(poolId);
        assertEq(sqrtAfter, sqrtBefore, "the curve never moved");
        assertEq(vault.getUnsettledDeltasCount(), 0);
    }

    function test_buyExactOutputChargesTheAskRoundedUp() public {
        uint256 cashBefore = cash.balanceOf(TRADER);
        _swap(true, false, 1 ether);
        assertEq(asset.balanceOf(TRADER), 1_001 ether);
        assertEq(cashBefore - cash.balanceOf(TRADER), Math.mulDiv(1 ether, _ask(), 1e30, Math.Rounding.Ceil));
    }

    function test_sellExactInputPaysTheBid() public {
        uint256 cashBefore = cash.balanceOf(TRADER);
        _swap(false, true, 2 ether);
        assertEq(cash.balanceOf(TRADER) - cashBefore, Math.mulDiv(2 ether, _bid(), 1e30));
        assertEq(_claims(asset), 32 ether);
    }

    function test_sellExactOutputTakesTheAssetRoundedUp() public {
        uint256 assetBefore = asset.balanceOf(TRADER);
        _swap(false, false, 500e6);
        assertEq(assetBefore - asset.balanceOf(TRADER), Math.mulDiv(500e6, 1e30, _bid(), Math.Rounding.Ceil));
    }

    function test_fillEmitsFilled() public {
        uint256 out = Math.mulDiv(300e6, 1e30, _ask());
        vm.expectEmit(true, true, false, true, address(basket));
        emit BasketVault.Filled(poolId, address(router), true, 300e6, out, PRICE);
        _swap(true, true, 300e6);
    }

    function testFuzz_aRoundTripNeverPaysTheTaker(uint256 spend) public {
        spend = bound(spend, 1e6, 5_000e6);
        uint256 cashBefore = cash.balanceOf(TRADER);
        uint256 assetBefore = asset.balanceOf(TRADER);
        _swap(true, true, spend);
        _swap(false, true, asset.balanceOf(TRADER) - assetBefore);
        assertLe(cash.balanceOf(TRADER), cashBefore, "no free money at a fixed oracle");
    }

    function testFuzz_fillsNeverLowerTheSharePrice(uint256[6] memory sizes) public {
        uint256 navBefore = basket.totalAssets();
        for (uint256 k; k < sizes.length; ++k) {
            uint256 amt = bound(sizes[k], 1e6, 2_000e6);
            if (k % 2 == 0) _swap(true, true, amt);
            else _swap(false, false, amt);
            vm.warp(block.timestamp + 1);
            _price(PRICE);
        }
        assertGe(basket.totalAssets(), navBefore);
    }

    // ── weighting: targets and the lean toward them ───────────────────────

    function _target(uint96 targetCash, uint16 skewBps) internal {
        AssetConfig memory c = _config();
        c.targetCash = targetCash;
        c.skewBps = skewBps;
        c.minSpreadBps = skewBps + 1; // the keeper may never narrow the spread under the lean
        vm.prank(OWNER);
        basket.updateAsset(0, c);
    }

    function test_belowTargetTheAssetCostsMoreAndFetchesMore() public {
        _target(18_000e6, 20); // holding 9,000: half the target, so the lean is +10bp
        uint256 ask = Math.mulDiv(PRICE, 10_035, 10_000, Math.Rounding.Ceil);
        uint256 bid = PRICE * 9_985 / 10_000;
        (, uint256 out,,) = basket.quoteFill(0, true, 300e6, true);
        assertEq(out, Math.mulDiv(300e6, 1e30, ask), "ask leans up");
        (, uint256 paid,,) = basket.quoteFill(0, false, 1 ether, true);
        assertEq(paid, Math.mulDiv(1 ether, bid, 1e30), "bid leans up");
        assertEq(basket.rebalanceGap(0), int256(9_000e6), "buy 9,000 more from the issuer");
    }

    function test_aboveTargetTheAssetIsCheaperToTake() public {
        _target(4_500e6, 20); // holding twice the target: the full -20bp
        uint256 ask = Math.mulDiv(PRICE, 10_005, 10_000, Math.Rounding.Ceil);
        (, uint256 out,,) = basket.quoteFill(0, true, 300e6, true);
        assertEq(out, Math.mulDiv(300e6, 1e30, ask));
        assertEq(basket.rebalanceGap(0), -int256(4_500e6));
    }

    function test_onTargetThereIsNoLean() public {
        _target(9_000e6, 20);
        (, uint256 out,,) = basket.quoteFill(0, true, 300e6, true);
        assertEq(out, Math.mulDiv(300e6, 1e30, _ask()));
        assertEq(basket.rebalanceGap(0), 0);
    }

    function test_theLeanMustStayInsideTheSpread() public {
        AssetConfig memory c = _config();
        c.targetCash = 9_000e6;
        c.skewBps = 5; // = minSpreadBps: a full lean would put one side on the oracle
        vm.prank(OWNER);
        vm.expectRevert(BasketLib.BadConfig.selector);
        basket.updateAsset(0, c);
        c.skewBps = 4;
        c.targetCash = 0; // a lean needs a target
        vm.prank(OWNER);
        vm.expectRevert(BasketLib.BadConfig.selector);
        basket.updateAsset(0, c);
    }

    function testFuzz_aRoundTripNeverPaysTheTakerWithALean(uint256 spend, uint96 target) public {
        target = uint96(bound(target, 1_000e6, 50_000e6));
        _target(target, 20);
        spend = bound(spend, 1e6, 5_000e6);
        uint256 cashBefore = cash.balanceOf(TRADER);
        uint256 assetBefore = asset.balanceOf(TRADER);
        _swap(true, true, spend);
        _swap(false, true, asset.balanceOf(TRADER) - assetBefore);
        assertLe(cash.balanceOf(TRADER), cashBefore);
    }

    // ── refusals fall through to the curve ────────────────────────────────

    function test_staleOracleRefuses() public {
        vm.warp(block.timestamp + 61);
        _expectRefusal(Refusal.Stale);
        _swap(true, true, 300e6);
    }

    /// The regression: a refusal must not move the curve. The pool checks a swap's price limit
    /// against the curve before it knows the hook took the swap, so an empty curve pushed to the
    /// end of its range would make every later "no limit" swap in that direction revert.
    function test_aRefusalNeverMovesTheCurve() public {
        (uint160 sqrtBefore,,,) = manager.getSlot0(poolId);
        vm.warp(block.timestamp + 61);
        _expectRefusal(Refusal.Stale);
        _swap(true, true, 300e6);
        (uint160 sqrtAfter,,,) = manager.getSlot0(poolId);
        assertEq(sqrtAfter, sqrtBefore);
        _price(PRICE);
        uint256 before = asset.balanceOf(TRADER);
        _swap(true, true, 300e6);
        assertGt(asset.balanceOf(TRADER), before, "the next no-limit swap still fills");
    }

    function test_anOpenCurveTakesWhatTheVaultRefuses() public {
        vm.prank(OWNER);
        basket.setCurveOpen(true);
        (, int24 tick,,) = manager.getSlot0(poolId);
        int24 lo = (tick / 60 - 100) * 60;
        vm.prank(TRADER);
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: lo + 12_000, liquidityDelta: 1e15, salt: 0
            }),
            ""
        );
        vm.warp(block.timestamp + 61);
        uint256 claimsBefore = _claims(asset);
        uint256 before = asset.balanceOf(TRADER);
        vm.expectEmit(true, false, false, true, address(basket));
        emit BasketVault.FillRefused(poolId, Refusal.Stale);
        _swap(true, true, 1e6);
        assertGt(asset.balanceOf(TRADER), before, "the curve filled it");
        assertEq(_claims(asset), claimsBefore, "the vault did not");
    }

    function test_missingOracleRefusesCleanly() public {
        AssetConfig memory c = _config();
        c.feedId = "missing";
        vm.prank(OWNER);
        basket.updateAsset(0, c);
        _expectRefusal(Refusal.Stale);
        _swap(true, true, 300e6);
    }

    function test_jumpBreakerHoldsUntilReset() public {
        _swap(true, true, 300e6); // anchors lastPrice
        _price(PRICE * 12 / 10);
        _expectRefusal(Refusal.Jump);
        _swap(true, true, 300e6);
        vm.prank(KEEPER);
        basket.resetPrice(0);
        uint256 before = asset.balanceOf(TRADER);
        _swap(true, true, 300e6);
        assertGt(asset.balanceOf(TRADER), before);
    }

    function test_tradeSizeCap() public {
        _expectRefusal(Refusal.Size);
        _swap(true, true, 5_001e6);
    }

    function test_outflowWindowCap() public {
        AssetConfig memory c = _config();
        c.windowCap = 1_000e6;
        vm.prank(OWNER);
        basket.updateAsset(0, c);
        _swap(true, true, 900e6);
        _expectRefusal(Refusal.Window);
        _swap(true, true, 200e6);
        vm.warp(block.timestamp + 1 hours);
        _price(PRICE);
        uint256 before = asset.balanceOf(TRADER);
        _swap(true, true, 200e6);
        assertGt(asset.balanceOf(TRADER), before, "the window rolls");
    }

    function test_onlyClaimsPayFills() public {
        vm.prank(KEEPER);
        basket.fromClaims(Currency.wrap(address(asset)), 30 ether);
        _expectRefusal(Refusal.Inventory);
        _swap(true, true, 300e6);
    }

    function test_inventoryCap() public {
        AssetConfig memory c = _config();
        c.maxInventoryCash = 9_100e6;
        vm.prank(OWNER);
        basket.updateAsset(0, c);
        _expectRefusal(Refusal.InventoryCap);
        _swap(false, true, 1 ether);
    }

    function test_cashReserveHoldsBackMargin() public {
        vm.prank(OWNER);
        basket.setParams(1_000_000e6, 9_800e6, 1 hours, 10_000e6);
        _expectRefusal(Refusal.Reserve);
        _swap(false, true, 1 ether);
    }

    function test_unhedgedCapRefusesWideningOnly() public {
        AssetConfig memory c = _config();
        c.maxUnhedgedCash = 9_000e6; // 30 ASSET at 300 is exactly at the cap, unhedged
        vm.prank(OWNER);
        basket.updateAsset(0, c);
        _expectRefusal(Refusal.Unhedged);
        _swap(false, true, 1 ether); // the vault buys: widens
        uint256 before = asset.balanceOf(TRADER);
        _swap(true, true, 300e6); // the vault sells: narrows, allowed
        assertGt(asset.balanceOf(TRADER), before);
    }

    function test_priceLimitTighterThanTheFillFallsThrough() public {
        // A buyer of ASSET whose limit sits 10bp past the mid can't be filled at the ask (25bp).
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        bool zeroForOne = cashIs0;
        uint160 limit = zeroForOne ? uint160(uint256(sqrtP) * 9995 / 10_000) : uint160(uint256(sqrtP) * 10_005 / 10_000);
        uint256 before = asset.balanceOf(TRADER);
        _expectRefusal(Refusal.PriceLimit);
        _swapLimit(true, true, 300e6, limit);
        assertEq(asset.balanceOf(TRADER), before);

        // A limit past the ask fills.
        limit = zeroForOne ? uint160(uint256(sqrtP) * 9980 / 10_000) : uint160(uint256(sqrtP) * 10_020 / 10_000);
        _swapLimit(true, true, 300e6, limit);
        assertGt(asset.balanceOf(TRADER), before);
    }

    function test_disabledAssetFallsThrough() public {
        AssetConfig memory c = _config();
        c.enabled = false;
        vm.prank(OWNER);
        basket.updateAsset(0, c);
        _expectRefusal(Refusal.Disabled);
        _swap(true, true, 300e6);
    }

    function test_pauseStopsFillsAndOnlyTheOwnerResumes() public {
        vm.prank(KEEPER);
        basket.pause();
        _expectRefusal(Refusal.Paused);
        _swap(true, true, 300e6);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, KEEPER));
        basket.unpause();
        vm.prank(OWNER);
        basket.unpause();
        uint256 before = asset.balanceOf(TRADER);
        _swap(true, true, 300e6);
        assertGt(asset.balanceOf(TRADER), before);
    }

    // ── the hook's surface ────────────────────────────────────────────────

    function test_onlyThePoolManagerCallsTheHook() public {
        vm.expectRevert(BasketVault.NotPoolManager.selector);
        basket.beforeSwap(
            address(this),
            key,
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0}),
            ""
        );
    }

    function test_aLookAlikePoolCannotBeCreated() public {
        PoolKey memory second = _key(address(basket), 500);
        PoolKey memory stranger = _key(address(basket), 10_000);
        vm.prank(OWNER);
        vm.expectRevert(); // PoolAlreadyRegistered: one pool per asset
        manager.initialize(second, SQRT_1_1);
        vm.expectRevert(); // InitializerNotOwner
        manager.initialize(stranger, SQRT_1_1);
    }

    function test_aPairOutsideTheBasketCannotBeCreated() public {
        MockERC20 stranger = new MockERC20("X", "X", 18);
        (address a, address b) =
            address(stranger) < address(cash) ? (address(stranger), address(cash)) : (address(cash), address(stranger));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            hooks: IHooks(address(basket)),
            poolManager: IPoolManager(address(manager)),
            fee: 3000,
            parameters: bytes32(uint256(basket.BITMAP())).setTickSpacing(60)
        });
        vm.prank(OWNER);
        vm.expectRevert();
        manager.initialize(k, SQRT_1_1);
    }

    function test_theCurveTakesNoLiquidityUntilOpened() public {
        ICLPoolManager.ModifyLiquidityParams memory p = ICLPoolManager.ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e12, salt: bytes32(0)
        });
        vm.prank(TRADER);
        vm.expectRevert();
        router.modifyPosition(key, p, "");
        vm.prank(OWNER);
        basket.setCurveOpen(true);
        vm.prank(TRADER);
        router.modifyPosition(key, p, "");
    }

    function test_lockCallbackRefusesStrangers() public {
        vm.prank(address(vault));
        vm.expectRevert(BasketVault.UnexpectedLock.selector);
        basket.lockAcquired(abi.encode(uint8(2), Currency.wrap(address(cash)), uint256(1)));
    }

    // ── the hedge ─────────────────────────────────────────────────────────

    function test_syncHedgeShortsTheHoldingAtLeverage() public {
        basket.syncHedge(0);
        MockExchangePrecompile.Order memory o = MockExchangePrecompile(EXCHANGE).pending(0);
        assertFalse(o.isBuy);
        assertEq(o.quantity, 30 ether, "the whole holding, on the tick");
        assertEq(o.worstPrice, 298.2e18, "oracle less 60bp, on the price tick");
        assertEq(o.margin, Math.mulDiv(30 ether, 298.2e18, 1e18) * 10 / 30, "3x");
        assertEq(keccak256(bytes(o.subaccountID)), keccak256(bytes(_sub())));

        vm.expectRevert(abi.encodeWithSelector(BasketLib.HedgePending.selector, 0));
        basket.syncHedge(0);

        vm.roll(block.number + 1);
        MockExchangePrecompile(EXCHANGE).endBlock(PRICE);
        vm.expectRevert(abi.encodeWithSelector(BasketLib.NothingToHedge.selector, 0, int256(0)));
        basket.syncHedge(0);
    }

    function test_navCountsTheShortAndIsFlatAtEntry() public {
        uint256 navBefore = basket.totalAssets();
        basket.syncHedge(0);
        vm.roll(block.number + 1);
        MockExchangePrecompile(EXCHANGE).endBlock(PRICE);
        assertEq(basket.totalAssets(), navBefore, "margin moved into the position, nothing lost");

        // The asset up 10%: it gains what the short loses.
        vm.warp(block.timestamp + 1);
        _price(330e18);
        assertApproxEqAbs(basket.totalAssets(), navBefore, 1, "hedged");
    }

    function test_aBuyFillThenSyncReducesTheShortReduceOnly() public {
        basket.syncHedge(0);
        vm.roll(block.number + 1);
        MockExchangePrecompile(EXCHANGE).endBlock(PRICE);

        _swap(true, true, 3_000e6); // the vault sells ~9.975 ASSET
        basket.syncHedge(0);
        MockExchangePrecompile.Order memory o = MockExchangePrecompile(EXCHANGE).pending(0);
        assertTrue(o.isBuy);
        assertEq(o.margin, 0, "reduce-only");
        uint256 held = asset.balanceOf(address(basket)) + _claims(asset);
        assertEq(o.quantity, 30 ether - held / 1e15 * 1e15);
    }

    function test_hedgeDrawsMarginOutOfClaims() public {
        uint256 claimsBefore = _claims(cash);
        basket.syncHedge(0);
        assertLt(_claims(cash), claimsBefore, "margin came out of claims");
    }

    function test_hedgeNeedsAFreshOracle() public {
        vm.warp(block.timestamp + 61);
        vm.expectRevert(abi.encodeWithSelector(BasketLib.StaleOracle.selector, 0));
        basket.syncHedge(0);
    }

    function test_topUpMarginRestoresLeverage() public {
        basket.syncHedge(0);
        vm.roll(block.number + 1);
        MockExchangePrecompile(EXCHANGE).endBlock(PRICE);
        vm.expectRevert(abi.encodeWithSelector(BasketLib.MarginHealthy.selector, 0));
        basket.topUpMargin(0);

        MockExchangePrecompile(EXCHANGE).setMargin(_sub(), MARKET, 1_000e18);
        basket.topUpMargin(0);
        IExchangeDerivatives_Position memory p = _position();
        assertEq(p.margin, Math.mulDiv(30 ether, PRICE, 1e18) * 10 / 30);
    }

    // ── shares ────────────────────────────────────────────────────────────

    function test_depositAndWithdrawAtNav() public {
        cash.mint(DEPOSITOR, 1_000e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(basket), type(uint256).max);
        uint256 shares = basket.deposit(1_000e6, DEPOSITOR);
        assertApproxEqAbs(basket.convertToAssets(shares), 1_000e6, 2, "priced at NAV");
        assertLe(basket.convertToAssets(shares), 1_000e6, "rounded the vault's way");
        basket.withdraw(500e6, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();
        assertEq(cash.balanceOf(DEPOSITOR), 500e6);
    }

    function test_onlyDepositorsDeposit() public {
        cash.mint(TRADER, 1e6);
        vm.startPrank(TRADER);
        cash.approve(address(basket), 1e6);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.NotDepositor.selector, TRADER));
        basket.deposit(1e6, TRADER);
        vm.stopPrank();
    }

    function test_noDepositAtAStaleNav() public {
        vm.warp(block.timestamp + 61);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BasketLib.StaleOracle.selector, 0));
        basket.deposit(1e6, OWNER);
    }

    function test_noDepositInTheBlockOfAHedgeOrder() public {
        basket.syncHedge(0);
        cash.mint(OWNER, 1e6);
        vm.prank(OWNER);
        vm.expectRevert(BasketVault.NavNotReady.selector);
        basket.deposit(1e6, OWNER);
    }

    function test_pausedVaultTakesNoDeposits() public {
        vm.prank(KEEPER);
        basket.pause();
        cash.mint(OWNER, 1e6);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, OWNER, 1e6, 0));
        basket.deposit(1e6, OWNER);
    }

    function test_withdrawalsArePaidFromCashOnly() public view {
        assertEq(basket.maxWithdraw(OWNER), 10_000e6, "the cash held, not the ASSET");
    }

    // ── the issuer ────────────────────────────────────────────────────────

    function test_issuerOrderAppendsTheMemoAndCarriesValueInTransit() public {
        bytes memory memo = bytes('{"type":"MARKET"}');
        uint256 nav = basket.totalAssets();
        vm.expectCall(address(cash), abi.encodePacked(abi.encodeCall(IERC20.transfer, (ISSUER, 100e6)), memo));
        vm.prank(KEEPER);
        basket.issuerOrder(address(cash), 100e6, memo);
        assertEq(cash.balanceOf(ISSUER), 100e6);
        assertEq(basket.inTransitCash(), 100e6);
        assertEq(basket.totalAssets(), nav, "still counted while with the issuer");
        vm.prank(KEEPER);
        basket.clearInTransit(100e6);
        assertEq(basket.inTransitCash(), 0);
    }

    function test_issuerOrderIsCappedPerDay() public {
        vm.startPrank(KEEPER);
        basket.issuerOrder(address(cash), 1_000e6, "");
        vm.expectRevert(abi.encodeWithSelector(BasketVault.IssuerCapExceeded.selector, 9_001e6, 9_000e6));
        basket.issuerOrder(address(cash), 9_001e6, "");
        vm.stopPrank();
    }

    function test_onlyTheKeeperOrdersAndOnlyBasketTokens() public {
        vm.expectRevert(BasketVault.NotKeeper.selector);
        basket.issuerOrder(address(cash), 1e6, "");
        MockERC20 stranger = new MockERC20("X", "X", 18);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(BasketLib.NotIssuable.selector, address(stranger)));
        basket.issuerOrder(address(stranger), 1, "");
    }

    function test_spreadStaysInsideOwnerBounds() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(BasketLib.SpreadOutOfBounds.selector, 201, 5, 200));
        basket.setSpread(0, 201);
        vm.prank(KEEPER);
        basket.setSpread(0, 40);
        assertEq(basket.assetConfig(0).spreadBps, 40);
    }

    // ── a stock-quoted launch, routed through the basket ─────────────────

    function test_aggregatorRoutesCashToMemeThroughTheBasketAndBack() public {
        MockWINJ winj = new MockWINJ();
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
        IVault[] memory vaults = new IVault[](1);
        vaults[0] = vault;
        ChoiceAggregator agg = new ChoiceAggregator(OWNER, permit2, IWETH9(address(winj)), vaults);

        // MEME/ASSET: a hookless full-range pool, like a graduation: 1 ASSET = 1,000,000 MEME.
        MockERC20 meme = new MockERC20("MEME", "MEME", 18);
        PoolKey memory memeKey = PoolKey({
            currency0: Currency.wrap(address(meme) < address(asset) ? address(meme) : address(asset)),
            currency1: Currency.wrap(address(meme) < address(asset) ? address(asset) : address(meme)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: 10_000,
            parameters: bytes32(0).setTickSpacing(200)
        });
        {
            bool memeIs0 = address(meme) < address(asset);
            // price = currency1 per currency0
            uint160 sqrtP = memeIs0 ? uint160(SQRT_1_1 / 1000) : uint160(SQRT_1_1 * 1000);
            manager.initialize(memeKey, sqrtP);
            meme.mint(address(this), 1e30);
            asset.mint(address(this), 1e30);
            meme.approve(address(router), type(uint256).max);
            asset.approve(address(router), type(uint256).max);
            router.modifyPosition(
                memeKey,
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: -887200, tickUpper: 887200, liquidityDelta: 1e24, salt: bytes32(0)
                }),
                ""
            );
        }

        vm.startPrank(TRADER);
        cash.approve(address(permit2), type(uint256).max);
        permit2.approve(address(cash), address(agg), type(uint160).max, type(uint48).max);
        meme.approve(address(permit2), type(uint256).max);
        permit2.approve(address(meme), address(agg), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        uint256 claimsBefore = _claims(asset);
        vm.prank(TRADER);
        uint256 memeOut = agg.execute(_route(agg, address(cash), address(meme), 300e6, memeKey));
        assertGt(memeOut, 0, "USDC bought MEME in one transaction");
        assertEq(meme.balanceOf(TRADER), memeOut);
        assertLt(_claims(asset), claimsBefore, "the ASSET leg came out of the basket");

        uint256 cashBefore = cash.balanceOf(TRADER);
        vm.prank(TRADER);
        uint256 cashOut = agg.execute(_route(agg, address(meme), address(cash), memeOut, memeKey));
        assertGt(cashOut, 0, "and MEME sold back to USDC");
        assertEq(cash.balanceOf(TRADER) - cashBefore, cashOut);
        assertLt(cashOut, 300e6, "two spreads and two pool fees lighter");
    }

    function _route(ChoiceAggregator, address tokenIn, address tokenOut, uint256 amountIn, PoolKey memory memeKey)
        internal
        view
        returns (ChoiceAggregator.RouteParams memory)
    {
        bool fromCash = tokenIn == address(cash);
        ChoiceAggregator.Hop[] memory hops = new ChoiceAggregator.Hop[](2);
        PoolKey memory first = fromCash ? key : memeKey;
        PoolKey memory second = fromCash ? memeKey : key;
        hops[0] = ChoiceAggregator.Hop({
            key: first,
            zeroForOne: Currency.unwrap(first.currency0) == tokenIn,
            bin: false,
            entryBps: 10_000,
            hookData: ""
        });
        hops[1] = ChoiceAggregator.Hop({
            key: second,
            zeroForOne: Currency.unwrap(second.currency0) == address(asset),
            bin: false,
            entryBps: 0,
            hookData: ""
        });
        ChoiceAggregator.Step[] memory steps = new ChoiceAggregator.Step[](1);
        steps[0] = ChoiceAggregator.Step({
            kind: ChoiceAggregator.Kind.Infinity,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            shareBps: 10_000,
            data: abi.encode(ChoiceAggregator.InfinityStage({vault: vault, hops: hops}))
        });
        return ChoiceAggregator.RouteParams({
            currencyIn: tokenIn,
            currencyOut: tokenOut,
            amountIn: amountIn,
            minimumReceive: 1,
            recipient: TRADER,
            deadline: block.timestamp + 1,
            feeBps: 0,
            feeRecipient: address(0),
            steps: steps
        });
    }

    // ── position read-back ────────────────────────────────────────────────

    struct IExchangeDerivatives_Position {
        bool isLong;
        uint256 quantity;
        uint256 entryPrice;
        uint256 margin;
    }

    function _position() internal view returns (IExchangeDerivatives_Position memory out) {
        (bool ok, bytes memory ret) =
            EXCHANGE.staticcall(abi.encodeWithSignature("subaccountPositions(string)", _sub()));
        require(ok);
        (BasketPositions[] memory ps) = abi.decode(ret, (BasketPositions[]));
        out = IExchangeDerivatives_Position(ps[0].isLong, ps[0].quantity, ps[0].entryPrice, ps[0].margin);
    }

    struct BasketPositions {
        string subaccountID;
        string marketID;
        bool isLong;
        uint256 quantity;
        uint256 entryPrice;
        uint256 margin;
        uint256 cumulativeFundingEntry;
    }
}
