// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {IStockVaultExtension} from "../../src/interfaces/IStockVaultExtension.sol";
import {SubaccountLib} from "../../src/libraries/SubaccountLib.sol";
import {MarketCalendar} from "../../src/stock/MarketCalendar.sol";
import {PriceStore} from "../../src/stock/PriceStore.sol";
import {StockPublic} from "../../src/stock/StockPublic.sol";
import {StockAdmin} from "../../src/stock/StockAdmin.sol";
import {StockRatios} from "../../src/stock/StockRatios.sol";
import {StockRegistry} from "../../src/stock/StockRegistry.sol";
import {StockVault} from "../../src/stock/StockVault.sol";
import {Refusal, StockConfig} from "../../src/stock/StockTypes.sol";
import {LazerBuilder} from "./LazerBuilder.sol";
import {MockStockExchange} from "../mocks/StockMocks.sol";

/// The real `Vault` + `CLPoolManager`, one 6-decimal CASH / 18-decimal STOCK pool keyed to the
/// stock vault as its hook, a real `PriceStore` fed updates signed by a test key, a real
/// `MarketCalendar`, and the exchange precompile mocked at its address.
abstract contract StockVaultHarness is Test, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;

    address internal constant OWNER = address(0x0A11);
    address internal constant KEEPER = address(0x0B22);
    address internal constant GUARDIAN = address(0x6A4D);
    address internal constant ISSUER = address(0x155E);
    address internal constant TRADER = address(0x7AD3);
    address internal constant DEPOSITOR = address(0xDE90);
    address internal constant UPDATER = address(0x9A70);
    address internal constant EXCHANGE = 0x0000000000000000000000000000000000000065;
    uint256 internal constant SIGNER_KEY = 0x5161;
    uint32 internal constant FEED = 7;
    string internal constant MARKET = "0x00000000000000000000000000000000000000000000000000000000000000aa";
    string internal constant CASH_DENOM = "erc20:cash";
    int64 internal constant MANTISSA = 30_000_000; // 300.00000, exponent -5
    uint256 internal constant PRICE = 300e18;

    // 2026-10-13, a Tuesday. 15:00Z is 11:00 New York, regular hours, 90 minutes after the open.
    uint256 internal constant TUE = 1_791_849_600;
    uint256 internal constant T_REGULAR = TUE + 15 hours;
    uint256 internal constant WED = TUE + 1 days;
    uint256 internal constant SAT = TUE + 4 days; // 2026-10-17 00:00Z = Friday 20:00 New York

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal router;
    PriceStore internal store;
    MarketCalendar internal calendar;
    StockRegistry internal registry;
    StockRatios internal ratios;
    StockVault internal sv;
    IStockVaultExtension internal x;
    MockERC20 internal cash;
    MockERC20 internal stock;
    MockStockExchange internal exchange;
    PoolKey internal key;
    bool internal cashIs0;
    uint64 internal nonce;

    function setUp() public virtual {
        vm.warp(T_REGULAR);
        vault = new Vault();
        manager = new CLPoolManager(vault);
        vault.registerApp(address(manager));
        router = new CLPoolManagerRouter(vault, manager);

        cash = new MockERC20("CASH", "CASH", 6);
        stock = new MockERC20("STOCK", "STOCK", 18);
        cashIs0 = address(cash) < address(stock);

        vm.etch(EXCHANGE, address(new MockStockExchange()).code);
        exchange = MockStockExchange(EXCHANGE);
        exchange.setCash(cash, CASH_DENOM);

        store = _newStore();
        calendar = new MarketCalendar(OWNER, GUARDIAN);
        registry = new StockRegistry(OWNER);
        ratios = new StockRatios(OWNER, UPDATER);
        sv = new StockVault(
            StockVault.Init({
                cash: IERC20(address(cash)),
                stock: IERC20(address(stock)),
                poolManager: ICLPoolManager(address(manager)),
                store: store,
                calendar: calendar,
                modules: address(new StockPublic(address(new StockAdmin()))),
                registry: address(registry),
                ratios: ratios,
                feedId: FEED,
                cashFeedId: _cashFeed(),
                marketId: MARKET,
                cashDenom: CASH_DENOM,
                owner: OWNER,
                name: "Stock vault",
                symbol: "SV"
            }),
            _cfg()
        );
        x = IStockVaultExtension(address(sv));
        _price(MANTISSA);

        vm.startPrank(OWNER);
        registry.setIssuerCap(ISSUER, 1_000_000e6);
        registry.register(address(sv), address(stock), ISSUER, _cfg().maxInventory);
        x.setRoles(KEEPER, GUARDIAN, ISSUER);
        x.setDepositor(DEPOSITOR, true);
        key = PoolKey({
            currency0: Currency.wrap(cashIs0 ? address(cash) : address(stock)),
            currency1: Currency.wrap(cashIs0 ? address(stock) : address(cash)),
            hooks: IHooks(address(sv)),
            poolManager: IPoolManager(address(manager)),
            fee: 3000,
            parameters: bytes32(uint256(sv.BITMAP())).setTickSpacing(60)
        });
        manager.initialize(key, _sqrtAt(300));

        // 10,000 cash deposited and 30 STOCK booked (19,000 of value), all of both as claims: what the
        // vault books lands there on its own.
        cash.mint(OWNER, 10_000e6);
        cash.approve(address(sv), type(uint256).max);
        sv.deposit(10_000e6, OWNER);
        vm.stopPrank();
        stock.mint(address(sv), 30 ether);
        vm.prank(KEEPER);
        x.syncWindfall();
        vm.prank(OWNER);
        x.acceptNav(); // the booked stock nearly doubled the share price

        cash.mint(TRADER, 1_000_000e6);
        stock.mint(TRADER, 1_000 ether);
        vm.startPrank(TRADER);
        cash.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// The cash's own USD feed; none (the cash taken as exactly one USD) unless a suite names one.
    function _cashFeed() internal view virtual returns (uint32) {
        return 0;
    }

    /// The price store every vault in the suite reads; a suite may swap in another kind.
    function _newStore() internal virtual returns (PriceStore) {
        return new PriceStore(OWNER, vm.addr(SIGNER_KEY), type(uint64).max);
    }

    function _cfg() internal pure virtual returns (StockConfig memory) {
        return StockConfig({
            spreadRegular: 25,
            spreadExtended: 40,
            spreadOvernight: 50,
            spreadClosed: 80,
            minSpread: 10,
            maxSpread: 200,
            agePerSecondBps: 0,
            quoteMissingBps: 0,
            confidenceMissingBps: 0,
            sizeBps: 0,
            windowBps: 0,
            skewBps: 0,
            openBps: 0,
            reanchorBps: 30,
            maxJumpBps: 1500,
            hedgeSlippageBps: 60,
            leverageX10: 30,
            navJumpBps: 500,
            restockSlippageBps: 300,
            maxAgeMs: 1500,
            closeTolerance: 300,
            openWindow: 900,
            reanchorDelay: 300,
            reanchorWide: 900,
            window: 3600,
            publicHedgeDelay: 300,
            restockDeadline: 3600,
            restockExpiryUnit: 1 days,
            makerTimeout: 0,
            queueDeadline: 2 days,
            exitFeeBps: 20,
            weekendFills: true,
            overnightLive: true,
            maxTrade: 5_000e6,
            maxTradeClosed: 1_000e6,
            windowCap: 20_000e6,
            windowCapClosed: 3_000e6,
            maxInventory: 50_000e6,
            targetInventory: 0,
            maxUnhedged: 20_000e6,
            hedgeBand: 10e6,
            minHedge: 1e6,
            cashReserve: 0,
            tvlCap: 1_000_000e6,
            restockDailyCap: 10_000e6,
            minRedeem: 10e6,
            qtyTick: 1e15,
            priceTick: 1e16,
            depositLock: 0,
            scarcityBps: 0,
            netCap: 20_000e6,
            closedNetCap: 3_000e6,
            scarcityReserve: 0
        });
    }

    /// Set `maxUnhedged`, lowering the trade caps with it so a full trade from inside the band still fits
    /// (`StockOps.checkConfig`).
    function _unhedgedCap(StockConfig memory c, uint96 maxUnhedged) internal pure {
        c.maxUnhedged = maxUnhedged;
        if (c.maxTrade + c.hedgeBand > maxUnhedged) c.maxTrade = maxUnhedged - c.hedgeBand;
        if (c.maxTradeClosed > c.maxTrade) c.maxTradeClosed = c.maxTrade;
    }

    function _setCfg(StockConfig memory c) internal {
        vm.prank(OWNER);
        x.setConfig(c);
    }

    /// The curve's price at `usd` per stock: currency1 per currency0 in raw units, as sqrt Q96.
    function _sqrtAt(uint256 usd) internal view returns (uint160) {
        uint256 priceX192 = cashIs0 ? (uint256(1e18) << 192) / (usd * 1e6) : (usd * 1e6 << 192) / 1e18;
        return uint160(Math.sqrt(priceX192));
    }

    /// A signed update, stamped now (plus a microsecond per call, so each is newer than the last).
    function _update(LazerBuilder.Feed memory f) internal returns (bytes memory) {
        uint64 ts = uint64(block.timestamp) * 1e6 + ++nonce;
        if (f.feedTimestampUs == 0) f.feedTimestampUs = ts;
        return LazerBuilder.one(SIGNER_KEY, ts, f);
    }

    function _feed(int64 mantissa) internal pure returns (LazerBuilder.Feed memory) {
        return LazerBuilder.Feed(FEED, mantissa, -5, 0, 0, 0, 0, -1);
    }

    function _price(int64 mantissa) internal {
        store.update(_update(_feed(mantissa)));
    }

    function _swap(bool cashIn, bool exactInput, uint256 amount) internal {
        _swapWith(cashIn, exactInput, amount, 0, "");
    }

    function _swapWith(bool cashIn, bool exactInput, uint256 amount, uint160 limit, bytes memory hookData) internal {
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
            hookData
        );
    }

    function _ask(uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(PRICE, 10_000 + bps, 10_000, Math.Rounding.Ceil);
    }

    function _bid(uint256 bps) internal pure returns (uint256) {
        return PRICE * (10_000 - bps) / 10_000;
    }

    function _expectRefusal(Refusal r) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(sv),
                ICLHooks.beforeSwap.selector,
                abi.encodeWithSelector(StockVault.NotFillable.selector, r),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _sub() internal view returns (string memory) {
        return SubaccountLib.subaccount(address(sv), 1);
    }

    function _claims(MockERC20 t) internal view returns (uint256) {
        return vault.balanceOf(address(sv), Currency.wrap(address(t)));
    }

    /// Put the hedge on: sell the short the gap asks for, fill it, read it back.
    function _hedge(uint256 fillPrice) internal {
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        vm.roll(block.number + 1);
        exchange.endBlock(fillPrice);
        x.confirmHedge();
    }
}
