// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {IStockVaultExtension} from "../src/interfaces/IStockVaultExtension.sol";
import {ChoiceAggregator} from "../src/router/ChoiceAggregator.sol";
import {StockOps} from "../src/stock/StockOps.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockPublic} from "../src/stock/StockPublic.sol";
import {StockAdmin} from "../src/stock/StockAdmin.sol";
import {StockHedge} from "../src/stock/StockHedge.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {StockVault} from "../src/stock/StockVault.sol";
import {Fill, Refusal, StockConfig, StockState} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {MockStockExchange} from "./mocks/StockMocks.sol";
import {MockWINJ} from "./mocks/AggregatorMocks.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// Fills, sessions, the breaker, guards, hedging, NAV, restocking and roles, on the harness.
contract StockVaultTest is StockVaultHarness {
    using CLPoolParametersHelper for bytes32;

    // ── fills ─────────────────────────────────────────────────────────────

    function test_buyExactInputFillsAtTheAsk() public {
        uint256 cashBefore = cash.balanceOf(TRADER);
        (uint160 sqrtBefore,,,) = manager.getSlot0(key.toId());
        uint256 out = Math.mulDiv(300e6, 1e30, _ask(25));
        _swap(true, true, 300e6);
        assertEq(cash.balanceOf(TRADER), cashBefore - 300e6);
        assertEq(stock.balanceOf(TRADER), 1_000 ether + out);
        assertEq(x.state().stockBooked, 30 ether - out);
        (uint160 sqrtAfter,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtAfter, sqrtBefore, "the curve never moves");
    }

    function test_buyExactOutputChargesTheAskRoundedUp() public {
        uint256 cashBefore = cash.balanceOf(TRADER);
        _swap(true, false, 1 ether);
        assertEq(cashBefore - cash.balanceOf(TRADER), Math.mulDiv(1 ether, _ask(25), 1e30, Math.Rounding.Ceil));
    }

    function test_sellExactInputPaysTheBid() public {
        uint256 cashBefore = cash.balanceOf(TRADER);
        _swap(false, true, 1 ether);
        assertEq(cash.balanceOf(TRADER) - cashBefore, Math.mulDiv(1 ether, _bid(25), 1e30));
        assertEq(x.state().stockBooked, 31 ether);
    }

    function test_sellExactOutputTakesTheStockRoundedUp() public {
        uint256 stockBefore = stock.balanceOf(TRADER);
        _swap(false, false, 299e6);
        assertEq(stockBefore - stock.balanceOf(TRADER), Math.mulDiv(299e6, 1e30, _bid(25), Math.Rounding.Ceil));
    }

    function test_fillEmitsFilled() public {
        uint256 out = Math.mulDiv(300e6, 1e30, _ask(25));
        vm.expectEmit(address(sv));
        emit StockOps.Filled(address(router), true, 300e6, out, PRICE, 25, false);
        _swap(true, true, 300e6);
    }

    function test_quoteFillMatchesTheSwap() public {
        Fill memory f = sv.quoteFill(true, 300e6, true, "");
        assertEq(uint256(f.reason), uint256(Refusal.None));
        uint256 before = stock.balanceOf(TRADER);
        _swap(true, true, 300e6);
        assertEq(stock.balanceOf(TRADER) - before, f.amountOut);
    }

    function testFuzz_aRoundTripNeverPaysTheTaker(uint256 spend) public {
        spend = bound(spend, 1e6, 4_000e6);
        uint256 cashBefore = cash.balanceOf(TRADER);
        uint256 stockBefore = stock.balanceOf(TRADER);
        _swap(true, true, spend);
        _swap(false, true, stock.balanceOf(TRADER) - stockBefore);
        assertLe(cash.balanceOf(TRADER), cashBefore);
    }

    function testFuzz_fillsNeverLowerTheSharePrice(uint256[4] memory sizes) public {
        uint256 before = sv.convertToAssets(1e12);
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amount = bound(sizes[i], 1e6, 2_000e6);
            if (i % 2 == 0) _swap(true, true, amount);
            else _swap(false, false, amount);
        }
        assertGe(sv.convertToAssets(1e12), before);
    }

    // ── the spread ────────────────────────────────────────────────────────

    function test_priceAgeWidensTheSpread() public {
        StockConfig memory c = _cfg();
        c.agePerSecondBps = 10;
        _setCfg(c);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(block.timestamp) * 1e6 - 600_000; // 600 ms old
        store.update(_update(f));
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 25 + 6);
    }

    function test_quoteAndConfidenceTerms() public {
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.bestBid = MANTISSA - 15_000; // 10 bp wide: 5 bp each side
        f.bestAsk = MANTISSA + 15_000;
        f.confidence = 6_000; // 2 bp
        store.update(_update(f));
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 25 + 5 + 2);
    }

    function test_missingQuoteAndConfidenceTakeTheirDefaults() public {
        StockConfig memory c = _cfg();
        c.quoteMissingBps = 7;
        c.confidenceMissingBps = 3;
        _setCfg(c);
        // The quote is missing (no bid/ask); confidence is present at zero, so only the quote default applies.
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 25 + 7);
    }

    function test_sizeAndWindowTerms() public {
        StockConfig memory c = _cfg();
        c.sizeBps = 20;
        c.windowBps = 40;
        _setCfg(c);
        // 2,500 of a 5,000 trade cap is 10 bp; 2,500 of a 20,000 window is 5 bp.
        assertEq(sv.quoteFill(true, 2_500e6, true, "").spreadBps, 25 + 10 + 5);
    }

    function test_theOpenWindowWidens() public {
        StockConfig memory c = _cfg();
        c.openBps = 15;
        _setCfg(c);
        vm.warp(WED + 13 hours + 30 minutes + 60); // 09:31 New York
        _price(MANTISSA);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 25 + 15);
        vm.warp(WED + 13 hours + 30 minutes + 901);
        _price(MANTISSA);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 25);
    }

    function test_keeperWidensAndThePastMaxCloses() public {
        vm.prank(KEEPER);
        x.widen(20, 600);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 45);
        vm.prank(KEEPER);
        x.widen(500, 600);
        _expectRefusal(Refusal.Spread);
        _swap(true, true, 300e6);
        vm.warp(block.timestamp + 601);
        _price(MANTISSA);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 25);
    }

    function test_onlyTheKeeperWidens() public {
        vm.expectRevert(StockModule.NotKeeper.selector);
        x.widen(20, 600);
    }

    function test_leanTowardTarget() public {
        StockConfig memory c = _cfg();
        c.targetInventory = 18_000e6; // holding 9,000: half short of target
        c.skewBps = 8;
        _setCfg(c);
        // Short of target the stock costs more (ask + 4 bp) and fetches more (bid + 4 bp).
        uint256 out = sv.quoteFill(true, 300e6, true, "").amountOut;
        assertEq(out, Math.mulDiv(300e6, 1e30, Math.mulDiv(PRICE, 10_029, 10_000, Math.Rounding.Ceil)));
        uint256 paid = sv.quoteFill(false, 1 ether, true, "").amountOut;
        assertEq(paid, Math.mulDiv(1 ether, PRICE * 9_979 / 10_000, 1e30));
    }

    function test_theLeanMustStayInsideTheSpread() public {
        StockConfig memory c = _cfg();
        c.targetInventory = 18_000e6;
        c.skewBps = 10; // == minSpread
        vm.prank(OWNER);
        vm.expectRevert(StockLib.BadConfig.selector);
        x.setConfig(c);
    }

    // ── the price ─────────────────────────────────────────────────────────

    function test_aFresherHookDataUpdateWins() public {
        bytes memory u = _update(_feed(MANTISSA + 300_000)); // 303.00
        Fill memory f = sv.quoteFill(true, 300e6, true, u);
        assertEq(f.price, 303e18);
        uint256 before = stock.balanceOf(TRADER);
        _swapWith(true, true, 300e6, 0, u);
        uint256 ask = Math.mulDiv(303e18, 10_025, 10_000, Math.Rounding.Ceil);
        assertEq(stock.balanceOf(TRADER) - before, Math.mulDiv(300e6, 1e30, ask));
        assertEq(store.latest(FEED).price, MANTISSA, "hook data is used, not stored");
    }

    function test_anOlderHookDataUpdateLoses() public view {
        bytes memory older = LazerBuilder.one(SIGNER_KEY, 1, _feed(MANTISSA + 300_000));
        assertEq(sv.quoteFill(true, 300e6, true, older).price, PRICE);
    }

    function test_aBadHookDataUpdateIsIgnored() public {
        bytes memory forged = LazerBuilder.one(0xBAD, uint64(block.timestamp) * 1e6 + 99, _feed(1));
        assertEq(sv.quoteFill(true, 300e6, true, forged).price, PRICE);
        _swapWith(true, true, 300e6, 0, forged);
        assertEq(sv.quoteFill(true, 300e6, true, hex"deadbeef").price, PRICE);
    }

    function test_aStalePriceInSessionRefuses() public {
        vm.warp(block.timestamp + 2);
        _expectRefusal(Refusal.Stale);
        _swap(true, true, 300e6);
        // A fresh one handed in with the swap revives the lane.
        _swapWith(true, true, 300e6, 0, _update(_feed(MANTISSA)));
    }

    function test_theSignerSayingClosedInHoursIsAHalt() public {
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.session = 4;
        store.update(_update(f));
        _expectRefusal(Refusal.Halted);
        _swap(true, true, 300e6);
    }

    // ── sessions ──────────────────────────────────────────────────────────

    function test_overnightAndPreMarketBases() public {
        vm.warp(WED + 6 hours); // 02:00 New York
        _price(MANTISSA);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 50);
        vm.warp(WED + 10 hours); // 06:00
        _price(MANTISSA);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 40);
        vm.warp(WED + 21 hours); // 17:00
        _price(MANTISSA);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 40);
    }

    /// The weekend: the feed's own time is Friday's close while the batch is fresh.
    function _weekendPrice() internal {
        vm.warp(SAT + 12 hours);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(SAT) * 1e6 - 200_000;
        store.update(_update(f));
    }

    function test_weekendModeFillsAtTheCloseAndTheClosedSpread() public {
        _weekendPrice();
        Fill memory f = sv.quoteFill(true, 300e6, true, "");
        assertEq(uint256(f.reason), uint256(Refusal.None));
        assertTrue(f.closed);
        assertEq(f.spreadBps, 80);
        uint128 anchorBefore = x.state().anchorPrice;
        _swap(true, true, 300e6);
        assertEq(x.state().anchorPrice, anchorBefore, "a frozen price is not an anchor");
    }

    function test_weekendCapsApply() public {
        _weekendPrice();
        _expectRefusal(Refusal.Size);
        _swap(true, true, 1_001e6);
    }

    function test_weekendFillsCanBeOff() public {
        StockConfig memory c = _cfg();
        c.weekendFills = false;
        _setCfg(c);
        _weekendPrice();
        _expectRefusal(Refusal.Closed);
        _swap(true, true, 300e6);
    }

    /// The feed died Friday afternoon: that is an outage carried into the weekend, not a close.
    function test_aPriceFromBeforeTheCloseRefusesAtTheWeekend() public {
        vm.warp(SAT + 12 hours);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(SAT - 2 hours) * 1e6;
        store.update(_update(f));
        _expectRefusal(Refusal.Stale);
        _swap(true, true, 300e6);
    }

    function test_overnightCanBeTreatedAsClosed() public {
        StockConfig memory c = _cfg();
        c.overnightLive = false;
        _setCfg(c);
        vm.warp(WED + 6 hours); // 02:00; the close is Tuesday 20:00 (WED + 0h)
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(WED) * 1e6 - 200_000;
        store.update(_update(f));
        Fill memory q = sv.quoteFill(true, 300e6, true, "");
        assertTrue(q.closed);
        assertEq(q.spreadBps, 80);
    }

    // ── the jump breaker ──────────────────────────────────────────────────

    function test_jumpRefusesThenReanchorsAfterTheDelay() public {
        _swap(true, true, 300e6); // anchors at 300
        _price(MANTISSA * 12 / 10); // 360: a 20% jump
        _expectRefusal(Refusal.Jump);
        _swap(true, true, 300e6);

        x.poke(); // notes the jump
        assertGt(x.state().jumpSince, 0);
        vm.warp(block.timestamp + 299);
        _price(MANTISSA * 12 / 10);
        x.poke();
        assertEq(x.state().anchorPrice, PRICE, "too soon");
        vm.warp(block.timestamp + 1);
        _price(MANTISSA * 12 / 10);
        x.poke();
        assertEq(x.state().anchorPrice, 360e18);
        assertEq(sv.quoteFill(true, 300e6, true, "").spreadBps, 25 + 30, "re-anchored at a wider spread");
        _swap(true, true, 300e6);
    }

    function test_smallMovesFollowTheAnchor() public {
        _swap(true, true, 300e6);
        _price(MANTISSA * 11 / 10);
        x.poke();
        assertEq(x.state().anchorPrice, 330e18);
    }

    // ── guards ────────────────────────────────────────────────────────────

    function test_tradeSizeCap() public {
        _expectRefusal(Refusal.Size);
        _swap(true, true, 5_001e6);
    }

    function test_windowCap() public {
        StockConfig memory c = _cfg();
        c.windowCap = 6_000e6;
        _setCfg(c);
        _swap(true, true, 4_000e6);
        _expectRefusal(Refusal.Window);
        _swap(true, true, 2_100e6);
        vm.warp(block.timestamp + 3600);
        _price(MANTISSA);
        _swap(true, true, 2_100e6);
    }

    function test_onlyClaimsPayFills() public {
        vm.prank(KEEPER);
        x.fromClaims(false, 30 ether);
        _expectRefusal(Refusal.Inventory);
        _swap(true, true, 300e6);
    }

    function test_inventoryCap() public {
        StockConfig memory c = _cfg();
        c.maxInventory = 9_500e6;
        c.restockDailyCap = 9_500e6; // never above the inventory cap
        _setCfg(c);
        _expectRefusal(Refusal.InventoryCap);
        _swap(false, true, 2 ether);
    }

    function test_cashReserveHoldsBackMargin() public {
        StockConfig memory c = _cfg();
        c.cashReserve = 9_900e6;
        _setCfg(c);
        _expectRefusal(Refusal.Reserve);
        _swap(false, true, 1 ether);
    }

    function test_unhedgedCapRefusesWideningOnly() public {
        StockConfig memory c = _cfg();
        c.maxUnhedged = 9_100e6; // holding 30 (9,000) against no short
        _setCfg(c);
        _expectRefusal(Refusal.Unhedged);
        _swap(false, true, 1 ether);
        _swap(true, true, 300e6); // narrows: allowed
    }

    function test_aPendingHedgeCountsBothWays() public {
        _hedge(PRICE); // short 30, flat
        StockConfig memory c = _cfg();
        c.maxUnhedged = 700e6;
        _setCfg(c);
        vm.roll(block.number + 1);
        _swap(false, true, 1 ether); // long 1 (300): within the cap
        vm.prank(KEEPER);
        x.syncHedge(); // sells 1 more: pending until a later block reads it back
        // A buy of 2 leaves short 1 against the confirmed short and short 2 (600) if the pending
        // sell filled: both within 700. One more would be short 3 (900) if it filled.
        _swap(true, false, 2 ether);
        _expectRefusal(Refusal.Unhedged);
        _swap(true, false, 1 ether);
    }

    function test_priceLimitTighterThanTheFillRefuses() public {
        // A limit at the oracle price itself: the ask is worse than that.
        uint160 limit = _sqrtAt(300);
        _expectRefusal(Refusal.PriceLimit);
        _swapWith(true, true, 300e6, limit, "");
    }

    function test_aStockDeficitStopsFills() public {
        vm.prank(KEEPER);
        x.fromClaims(false, 5 ether);
        stock.burn(address(sv), 1 ether); // the issuer's admin burn, say
        _expectRefusal(Refusal.Deficit);
        _swap(true, true, 300e6);
        // Value counts only what is held.
        assertEq(sv.totalAssets(), 10_000e6 + 29 * 300e6);
    }

    // ── pause and roles ───────────────────────────────────────────────────

    function test_pauseFlagsAndOnlyTheOwnerResumes() public {
        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_FILLS);
        _expectRefusal(Refusal.Paused);
        _swap(true, true, 300e6);

        vm.prank(KEEPER);
        vm.expectRevert(StockModule.NotOwner.selector);
        x.unpause(StockLib.PAUSE_FILLS);

        vm.prank(OWNER);
        x.unpause(StockLib.PAUSE_FILLS);
        _swap(true, true, 300e6);

        vm.prank(TRADER);
        vm.expectRevert(StockModule.NotPauser.selector);
        x.pause(1);
    }

    function test_onlyThePoolManagerCallsTheHook() public {
        vm.expectRevert(StockVault.NotPoolManager.selector);
        sv.beforeSwap(
            TRADER, key, ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0}), ""
        );
    }

    function test_onlyTheOwnerCreatesThePoolAndOnlyOnce() public {
        PoolKey memory k2 = key;
        k2.fee = 500;
        vm.prank(TRADER);
        vm.expectRevert();
        manager.initialize(k2, _sqrtAt(300));
        vm.prank(OWNER);
        vm.expectRevert();
        manager.initialize(k2, _sqrtAt(300));
    }

    function test_theCurveTakesNoLiquidityWhileClosed() public {
        vm.expectRevert();
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    function test_theModulesRefuseDirectCalls() public {
        StockPublic pub = StockPublic(sv.MODULES());
        StockAdmin admin = StockAdmin(pub.NEXT());
        vm.expectRevert(StockModule.NotDelegated.selector);
        pub.config();
        // An admin selector sent to the first module is refused there, before its fallback.
        vm.expectRevert(StockModule.NotDelegated.selector);
        IStockVaultExtension(address(pub)).setConfig(_cfg());
        vm.expectRevert(StockModule.NotDelegated.selector);
        admin.setConfig(_cfg());
    }

    function test_onlyTheOwnerSetsConfigAndHardLimitsHold() public {
        vm.prank(KEEPER);
        vm.expectRevert(StockModule.NotOwner.selector);
        x.setConfig(_cfg());

        StockConfig memory c = _cfg();
        c.maxSpread = 501;
        vm.prank(OWNER);
        vm.expectRevert(StockLib.BadConfig.selector);
        x.setConfig(c);

        c = _cfg();
        c.leverageX10 = 60;
        vm.prank(OWNER);
        vm.expectRevert(StockLib.BadConfig.selector);
        x.setConfig(c);

        c = _cfg();
        c.maxAgeMs = 6000;
        vm.prank(OWNER);
        vm.expectRevert(StockLib.BadConfig.selector);
        x.setConfig(c);
    }

    function test_theOwnerCannotSweepWhatDepositorsOwn() public {
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockAdmin.ProtectedToken.selector, address(cash)));
        x.sweep(address(cash), OWNER, 1);
        vm.expectRevert(abi.encodeWithSelector(StockAdmin.ProtectedToken.selector, address(stock)));
        x.sweep(address(stock), OWNER, 1);
        MockERC20 stray = new MockERC20("X", "X", 18);
        stray.mint(address(sv), 5);
        x.sweep(address(stray), OWNER, 5);
        vm.stopPrank();
        assertEq(stray.balanceOf(OWNER), 5);
    }

    // ── hedge ─────────────────────────────────────────────────────────────

    function test_hedgeSellsTheHoldingWithNoTarget() public {
        uint256 navBefore = sv.totalAssets();
        _hedge(PRICE);
        assertEq(x.state().shortConfirmed, 30 ether);
        assertApproxEqAbs(sv.totalAssets(), navBefore, 1, "a hedge at the reference moves no value");
        assertEq(sv.hedgeGap(), 0);
    }

    function test_hedgeTracksTheTargetWhileTheIssuerCanRestock() public {
        _hedge(PRICE); // short 30
        StockConfig memory c = _cfg();
        c.targetInventory = 9_000e6; // 30 at 300
        _setCfg(c);
        vm.roll(block.number + 1);
        _swap(true, false, 10 ether); // a launch buyer takes 10
        assertEq(sv.hedgeGap(), 0, "the restock will close the gap, so the short stays");
        vm.prank(KEEPER);
        assertFalse(x.syncHedge());

        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_RESTOCK);
        assertEq(sv.hedgeGap(), -10 ether, "no restock: the short follows the holding");
        vm.prank(KEEPER);
        assertTrue(x.syncHedge());
        assertEq(exchange.pending(0).quantity, 10 ether);
        assertTrue(exchange.pending(0).isBuy);
        assertEq(exchange.pending(0).margin, 0, "a cover is reduce-only");
    }

    function test_theTargetShortIsCappedByTheUnhedgedLimit() public {
        StockConfig memory c = _cfg();
        c.targetInventory = 30_000e6; // 100 at 300, holding 30
        c.maxUnhedged = 1_500e6;
        _setCfg(c);
        // The restock would close 21,000 of gap; the short runs at most 1,500 (5) ahead of the holding.
        assertEq(sv.hedgeGap(), 35 ether);
    }

    function test_atTheWeekendTheShortFollowsTheHolding() public {
        _hedge(PRICE);
        StockConfig memory c = _cfg();
        c.targetInventory = 9_000e6;
        _setCfg(c);
        vm.roll(block.number + 1);
        _swap(true, false, 10 ether);
        assertEq(sv.hedgeGap(), 0);
        _weekendPrice(); // the issuer does not fill at the weekend
        assertEq(sv.hedgeGap(), -10 ether);
    }

    function test_hedgeIgnoresDriftInsideTheBand() public {
        _hedge(PRICE);
        vm.roll(block.number + 1);
        _swap(true, false, 0.02 ether); // 6 of drift, band 10
        vm.prank(KEEPER);
        assertFalse(x.syncHedge());
    }

    function test_oneHedgeOrderPerBlock() public {
        vm.prank(KEEPER);
        x.syncHedge();
        vm.prank(KEEPER);
        vm.expectRevert(StockHedge.HedgePending.selector);
        x.syncHedge();
    }

    function test_anyoneHedgesAfterTheDelay() public {
        _hedge(PRICE);
        vm.roll(block.number + 1);
        _swap(true, false, 5 ether);
        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_RESTOCK);
        vm.expectPartialRevert(StockHedge.HedgeTooSoon.selector);
        x.syncHedge();
        vm.warp(block.timestamp + 300);
        _price(MANTISSA);
        assertTrue(x.syncHedge());
    }

    function test_hedgeNeedsAUsablePrice() public {
        vm.warp(block.timestamp + 5);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Stale));
        x.syncHedge();
    }

    function test_hedgeWorstPriceAndMargin() public {
        vm.prank(KEEPER);
        x.syncHedge();
        MockStockExchange.Order memory o = exchange.pending(0);
        assertFalse(o.isBuy);
        assertEq(o.quantity, 30 ether);
        assertEq(o.worstPrice, 298.2e18); // 300 less 60 bp, on the 0.01 tick
        // Initial margin at the mark (the higher price), plus the 1.80 a share the order opens under it.
        assertEq(o.margin, Math.mulDiv(30 ether, PRICE, 1e18) * 10 / 30 + Math.mulDiv(30 ether, 1.8e18, 1e18));
    }

    function test_aDroppedHedgeIsReadBackAsNothing() public {
        vm.prank(KEEPER);
        x.syncHedge();
        vm.roll(block.number + 1);
        exchange.endBlock(290e18); // below the worst price: dropped
        x.confirmHedge();
        assertEq(x.state().shortConfirmed, 0);
        assertEq(x.state().pendingQty, 0);
    }

    function test_topUpMargin() public {
        _hedge(PRICE);
        vm.expectRevert(StockHedge.MarginHealthy.selector);
        x.topUpMargin();
        exchange.setMargin(_sub(), MARKET, 1_000e18); // a third of the 3,000 it should be
        x.topUpMargin();
        assertEq(exchange.subaccountPositions(_sub())[0].margin, 3_000e18, "back to notional / leverage");
    }

    // ── deposits and withdrawals ──────────────────────────────────────────

    function test_depositAndWithdraw() public {
        cash.mint(DEPOSITOR, 1_000e6);
        vm.startPrank(DEPOSITOR);
        cash.approve(address(sv), type(uint256).max);
        uint256 shares = sv.deposit(1_000e6, DEPOSITOR);
        assertApproxEqAbs(sv.convertToAssets(shares), 1_000e6, 2);
        sv.redeem(shares, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();
        assertApproxEqAbs(cash.balanceOf(DEPOSITOR), 1_000e6, 2);
    }

    function test_theAllowlistHoldsOutsiders() public {
        cash.mint(TRADER, 1);
        vm.startPrank(TRADER);
        cash.approve(address(sv), 1);
        vm.expectRevert(abi.encodeWithSelector(StockVault.NotDepositor.selector, TRADER));
        sv.deposit(1, TRADER);
        vm.stopPrank();
    }

    function test_depositsClosedWhileTheMarketIsClosed() public {
        _weekendPrice();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Closed));
        sv.deposit(1e6, OWNER);
    }

    function test_depositsClosedOnAStalePrice() public {
        vm.warp(block.timestamp + 5);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.PriceNotUsable.selector, Refusal.Stale));
        sv.deposit(1e6, OWNER);
    }

    function test_aPriceInTheSameMulticallOpensThem() public {
        vm.warp(block.timestamp + 5);
        cash.mint(OWNER, 1e6);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IStockVaultExtension.pushPrice, (_update(_feed(MANTISSA))));
        calls[1] = abi.encodeCall(sv.deposit, (1e6, OWNER));
        vm.prank(OWNER);
        sv.multicall(calls);
    }

    function test_depositsClosedInAHedgeBlock() public {
        vm.prank(KEEPER);
        x.syncHedge();
        assertFalse(sv.navReady());
        vm.prank(OWNER);
        vm.expectRevert(StockOps.NavNotReady.selector);
        sv.deposit(1e6, OWNER);
    }

    function test_fundingIsSettledBeforeSharesArePriced() public {
        _hedge(PRICE);
        exchange.accrueFunding(_sub(), MARKET, 100e18); // 100 of funding owed to the short
        uint256 previewBefore = sv.previewDeposit(1_000e6);
        cash.mint(OWNER, 1_000e6);
        vm.prank(OWNER);
        uint256 shares = sv.deposit(1_000e6, OWNER);
        assertEq(exchange.decreases(), 1);
        assertLt(shares, previewBefore, "the funding is in the price the deposit paid");
    }

    /// A refused funding settlement (a short under its initial margin ratio refuses any decrease) must not
    /// freeze deposits and exits: the value is read with funding unsettled.
    function test_aFailedFundingSettlementDoesNotStopDeposits() public {
        _hedge(PRICE);
        exchange.setFailDecrease(true);
        cash.mint(OWNER, 1e6);
        vm.prank(OWNER);
        sv.deposit(1e6, OWNER);
        vm.prank(OWNER);
        sv.withdraw(1e6, OWNER, OWNER);
    }

    function test_aNavJumpStopsDepositsUntilAccepted() public {
        _hedge(PRICE);
        vm.prank(OWNER);
        sv.deposit(0, OWNER); // records the share price
        exchange.accrueFunding(_sub(), MARKET, 2_000e18); // +10.5% of value
        vm.roll(block.number + 1);
        vm.prank(OWNER);
        vm.expectPartialRevert(StockOps.NavJump.selector);
        sv.deposit(1e6, OWNER);
        vm.prank(OWNER);
        x.acceptNav();
        cash.mint(OWNER, 1e6);
        vm.prank(OWNER);
        sv.deposit(1e6, OWNER);
    }

    function test_withdrawalsOnlyFromFreeCash() public {
        StockConfig memory c = _cfg();
        c.cashReserve = 9_000e6;
        _setCfg(c);
        assertEq(sv.maxWithdraw(OWNER), 1_000e6);
        vm.prank(OWNER);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxWithdraw.selector);
        sv.withdraw(1_001e6, OWNER, OWNER);
        vm.prank(OWNER);
        sv.withdraw(1_000e6, OWNER, OWNER);
    }

    // ── a stock-quoted launch, routed through the vault ──────────────────

    /// USDC to MEME in one aggregator transaction: the stock vault's pool for the stock, then a
    /// hookless MEME/STOCK pool like a graduation. The stored price is stale, so the fill happens
    /// only because the route carries a signed update to the hook as its `hookData`.
    function test_aggregatorRoutesCashToMemeWithTheUpdateInHookData() public {
        MockWINJ winj = new MockWINJ();
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
        IVault[] memory vaults = new IVault[](1);
        vaults[0] = vault;
        ChoiceAggregator agg = new ChoiceAggregator(OWNER, permit2, IWETH9(address(winj)), vaults);

        MockERC20 meme = new MockERC20("MEME", "MEME", 18);
        bool memeIs0 = address(meme) < address(stock);
        PoolKey memory memeKey = PoolKey({
            currency0: Currency.wrap(memeIs0 ? address(meme) : address(stock)),
            currency1: Currency.wrap(memeIs0 ? address(stock) : address(meme)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(manager)),
            fee: 10_000,
            parameters: bytes32(0).setTickSpacing(200)
        });
        uint160 one = 79_228_162_514_264_337_593_543_950_336;
        manager.initialize(memeKey, memeIs0 ? one / 1000 : one * 1000); // 1 STOCK = 1,000,000 MEME
        meme.mint(address(this), 1e30);
        stock.mint(address(this), 1e30);
        meme.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        router.modifyPosition(
            memeKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -887_200, tickUpper: 887_200, liquidityDelta: 1e24, salt: 0
            }),
            ""
        );

        vm.startPrank(TRADER);
        cash.approve(address(permit2), type(uint256).max);
        permit2.approve(address(cash), address(agg), type(uint160).max, type(uint48).max);
        meme.approve(address(permit2), type(uint256).max);
        permit2.approve(address(meme), address(agg), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.warp(block.timestamp + 3); // the stored price is now too old to fill on
        bytes memory signed = _update(_feed(MANTISSA));
        uint256 claimsBefore = _claims(stock);
        vm.prank(TRADER);
        uint256 memeOut = agg.execute(_route(address(cash), address(meme), 300e6, memeKey, signed));
        assertGt(memeOut, 0, "USDC bought MEME in one transaction");
        assertEq(meme.balanceOf(TRADER), memeOut);
        assertLt(_claims(stock), claimsBefore, "the stock leg came out of the vault");

        // Without the update the same route is refused.
        vm.prank(TRADER);
        vm.expectRevert();
        agg.execute(_route(address(meme), address(cash), memeOut, memeKey, ""));

        uint256 cashBefore = cash.balanceOf(TRADER);
        vm.prank(TRADER);
        uint256 cashOut = agg.execute(_route(address(meme), address(cash), memeOut, memeKey, signed));
        assertEq(cash.balanceOf(TRADER) - cashBefore, cashOut);
        assertLt(cashOut, 300e6, "two spreads and two pool fees lighter");
        assertGt(cashOut, 290e6);
    }

    function _route(address tokenIn, address tokenOut, uint256 amountIn, PoolKey memory memeKey, bytes memory signed)
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
            hookData: fromCash ? signed : bytes("")
        });
        hops[1] = ChoiceAggregator.Hop({
            key: second,
            zeroForOne: Currency.unwrap(second.currency0) == address(stock),
            bin: false,
            entryBps: 0,
            hookData: fromCash ? bytes("") : signed
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
}
