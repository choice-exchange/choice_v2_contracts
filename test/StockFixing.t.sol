// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StockFixing} from "../src/stock/StockFixing.sol";
import {StockModule} from "../src/stock/StockModule.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {FixingBatch, FixingConfig, FixingRequest, Refusal, StockConfig} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The fixing lane on the stock vault harness: 10,000 cash and 30 STOCK at 300, Tuesday 15:00Z
/// (regular hours), hourly boundaries with the tick 2 s after each.
contract StockFixingTest is StockVaultHarness {
    address internal constant BUYER = address(0xB111);
    address internal constant BUYER2 = address(0xB222);
    address internal constant BUYER3 = address(0xB333);
    address internal constant SELLER = address(0x5E11);

    // forge-lint: disable-next-line(unsafe-typecast) - a 2026 timestamp.
    uint64 internal constant BOUNDARY = uint64(TUE + 16 hours); // 12:00 New York
    uint64 internal constant TICK_US = (BOUNDARY * 1000 + 2000) * 1000;

    function setUp() public override {
        super.setUp();
        vm.prank(OWNER);
        x.setFixingConfig(_fixCfg());
        address[4] memory who = [BUYER, BUYER2, BUYER3, SELLER];
        for (uint256 k; k < who.length; ++k) {
            cash.mint(who[k], 1_000_000e6);
            stock.mint(who[k], 1_000 ether);
            vm.startPrank(who[k]);
            cash.approve(address(sv), type(uint256).max);
            stock.approve(address(sv), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _fixCfg() internal pure returns (FixingConfig memory) {
        return FixingConfig({
            interval: 3600,
            delayMs: 2000,
            settleWindow: 30,
            spreadBps: 10,
            sizeBps: 0,
            maxSpreadBps: 100,
            minRequest: 10e6,
            maxSide: 100_000e6,
            maxNet: 50_000e6
        });
    }

    function _setFix(FixingConfig memory fc) internal {
        vm.prank(OWNER);
        x.setFixingConfig(fc);
    }

    function _commit(address who, bool cashIn, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return x.commitFixing(BOUNDARY, cashIn, amount, who);
    }

    /// The update stamped at `tsUs`, its feed current at that time.
    function _at(uint64 tsUs, int64 mantissa) internal pure returns (bytes memory) {
        LazerBuilder.Feed memory f = _feed(mantissa);
        f.feedTimestampUs = tsUs;
        return LazerBuilder.one(SIGNER_KEY, tsUs, f);
    }

    function _settle(int64 mantissa) internal {
        vm.warp(BOUNDARY + 3);
        x.settleFixing(BOUNDARY, _at(TICK_US, mantissa));
    }

    function _askAt(uint256 price, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(price, 10_000 + bps, 10_000, Math.Rounding.Ceil);
    }

    function _bidAt(uint256 price, uint256 bps) internal pure returns (uint256) {
        return price * (10_000 - bps) / 10_000;
    }

    function _expectRefused(Refusal r) internal {
        vm.expectRevert(abi.encodeWithSelector(StockFixing.FixingRefused.selector, r));
    }

    // ── fills ─────────────────────────────────────────────────────────────

    function test_aBuyFillsAtTheTickPricePlusTheSpread() public {
        uint256 id = _commit(BUYER, true, 3_000e6);
        assertEq(x.state().cashOwed, 3_000e6, "escrow is owed");
        _settle(31_000_000); // 310

        uint256 out = Math.mulDiv(3_000e6, 1e30, _askAt(310e18, 10));
        FixingBatch memory b = x.fixingBatch(BOUNDARY);
        assertTrue(b.settled);
        assertEq(b.price, 310e18);
        assertEq(b.spreadBps, 10);
        assertEq(b.buy.out, out);
        assertEq(x.state().stockBooked, 30 ether - out);
        assertEq(x.state().anchorPrice, 310e18, "a fixing is a fresh anchor");

        uint256 before = stock.balanceOf(BUYER);
        (uint256 got, uint256 refund) = x.claimFixing(id);
        assertEq(got, out);
        assertEq(refund, 0);
        assertEq(stock.balanceOf(BUYER) - before, out);
        assertEq(x.state().cashOwed, 0);
        assertEq(x.state().stockOwed, 0);
    }

    function test_bothSidesCrossAtOnePrice() public {
        uint256 buyId = _commit(BUYER, true, 3_000e6);
        uint256 sellId = _commit(SELLER, false, 5 ether);
        _settle(MANTISSA);

        uint256 stockOut = Math.mulDiv(3_000e6, 1e30, _askAt(PRICE, 10));
        uint256 cashOut = Math.mulDiv(5 ether, _bidAt(PRICE, 10), 1e30);
        assertEq(x.state().stockBooked, 30 ether + 5 ether - stockOut, "the vault carries only the net");

        uint256 sellerCash = cash.balanceOf(SELLER);
        x.claimFixing(buyId);
        x.claimFixing(sellId);
        assertEq(stock.balanceOf(BUYER), 1_000 ether + stockOut);
        assertEq(cash.balanceOf(SELLER) - sellerCash, cashOut);
        assertEq(x.state().cashOwed, 0);
        assertEq(x.state().stockOwed, 0);
    }

    function test_aCutSideFillsProRataAndTheLastClaimTakesTheDust() public {
        FixingConfig memory fc = _fixCfg();
        fc.maxNet = 1_500e6; // 5 STOCK at 300
        _setFix(fc);
        uint256 a = _commit(BUYER, true, 1_000e6);
        uint256 b = _commit(BUYER2, true, 1_000e6);
        uint256 c = _commit(BUYER3, true, 1_001e6);
        _settle(MANTISSA);

        FixingBatch memory batch = x.fixingBatch(BOUNDARY);
        assertEq(batch.buy.out, 5 ether, "the net is held to maxNet");
        uint256 filled = Math.mulDiv(5 ether, _askAt(PRICE, 10), 1e30, Math.Rounding.Ceil);
        assertEq(batch.buy.filled, filled);

        uint256 outs;
        uint256 refunds;
        uint256[3] memory ids = [a, b, c];
        for (uint256 k; k < 3; ++k) {
            (uint256 o, uint256 r) = x.claimFixing(ids[k]);
            outs += o;
            refunds += r;
        }
        assertEq(outs, 5 ether, "every unit paid out");
        assertEq(refunds, 3_001e6 - filled, "every unfilled unit refunded");
        assertEq(x.state().cashOwed, 0);
        assertEq(x.state().stockOwed, 0);
        batch = x.fixingBatch(BOUNDARY);
        assertEq(batch.buy.amountIn, 0);
        assertEq(batch.buy.out, 0);
    }

    function test_theBuySideIsCutToTheBookedStock() public {
        uint256 id = _commit(BUYER, true, 12_000e6); // 40 STOCK, 30 booked
        _settle(MANTISSA);
        (uint256 out, uint256 refund) = x.claimFixing(id);
        assertEq(out, 30 ether);
        assertEq(refund, 12_000e6 - Math.mulDiv(30 ether, _askAt(PRICE, 10), 1e30, Math.Rounding.Ceil));
        assertEq(x.state().stockBooked, 0);
    }

    function test_theSellSideIsCutToCashAboveTheReserveAndTheHedgeMargin() public {
        // 10,000 cash, 3x: at most 7,500 of stock comes in, leaving 2,500 to margin its short.
        uint256 id = _commit(SELLER, false, 40 ether);
        _settle(MANTISSA);
        (uint256 out, uint256 refund) = x.claimFixing(id);
        assertEq(refund, 15 ether);
        assertEq(out, Math.mulDiv(25 ether, _bidAt(PRICE, 10), 1e30));
        assertEq(x.state().stockBooked, 55 ether);
        assertGe(cash.balanceOf(address(sv)) + _claims(cash), 2_500e6);
    }

    function test_theSellSideIsCutToTheInventoryCap() public {
        StockConfig memory c = _cfg();
        c.maxInventory = 12_000e6; // 9,000 held: room for 10 more
        _setCfg(c);
        uint256 id = _commit(SELLER, false, 20 ether);
        _settle(MANTISSA);
        (, uint256 refund) = x.claimFixing(id);
        assertEq(refund, 10 ether);
    }

    // ── the one price ─────────────────────────────────────────────────────

    function test_onlyTheUpdateStampedAtTheTickSettles() public {
        _commit(BUYER, true, 3_000e6);
        vm.warp(BOUNDARY + 3);
        uint64[2] memory wrong = [TICK_US + 200_000, TICK_US - 200_000];
        for (uint256 k; k < 2; ++k) {
            vm.expectRevert(abi.encodeWithSelector(StockFixing.WrongTick.selector, wrong[k], TICK_US));
            x.settleFixing(BOUNDARY, _at(wrong[k], MANTISSA));
        }
        x.settleFixing(BOUNDARY, _at(TICK_US, MANTISSA));
        vm.expectRevert(StockFixing.AlreadySettled.selector);
        x.settleFixing(BOUNDARY, _at(TICK_US, MANTISSA));
    }

    function test_aCommitMustNameTheNextBoundary() public {
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(StockFixing.WrongBoundary.selector, BOUNDARY));
        x.commitFixing(BOUNDARY + 3600, true, 1_000e6, BUYER);
        vm.warp(BOUNDARY);
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(StockFixing.WrongBoundary.selector, BOUNDARY + 3600));
        x.commitFixing(BOUNDARY, true, 1_000e6, BUYER);
    }

    function test_aStaleFeedAtTheTickIsRefused() public {
        _commit(BUYER, true, 3_000e6);
        vm.warp(BOUNDARY + 3);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = TICK_US - 1_501_000; // older than maxAge at the tick
        bytes memory u = LazerBuilder.one(SIGNER_KEY, TICK_US, f);
        _expectRefused(Refusal.Stale);
        x.settleFixing(BOUNDARY, u);
    }

    function test_aJumpFromTheAnchorIsRefused() public {
        x.poke(); // anchor at 300
        _commit(BUYER, true, 3_000e6);
        vm.warp(BOUNDARY + 3);
        bytes memory u = _at(TICK_US, 40_000_000);
        _expectRefused(Refusal.Jump);
        x.settleFixing(BOUNDARY, u);
    }

    function test_theSignerReportingTheMarketShutIsAHalt() public {
        _commit(BUYER, true, 3_000e6);
        vm.warp(BOUNDARY + 3);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = TICK_US;
        f.session = 4;
        bytes memory u = LazerBuilder.one(SIGNER_KEY, TICK_US, f);
        _expectRefused(Refusal.Halted);
        x.settleFixing(BOUNDARY, u);
    }

    function test_aSpreadOverTheMaximumIsRefused() public {
        _commit(BUYER, true, 3_000e6);
        vm.prank(KEEPER);
        x.widen(95, 2 hours);
        vm.warp(BOUNDARY + 3);
        bytes memory u = _at(TICK_US, MANTISSA);
        _expectRefused(Refusal.Spread);
        x.settleFixing(BOUNDARY, u);
    }

    function test_theSpreadAddsConfidenceAndTheMarketSpread() public {
        _commit(BUYER, true, 3_000e6);
        vm.warp(BOUNDARY + 3);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = TICK_US;
        f.confidence = 6_000; // 2 bps of 30,000,000
        f.bestBid = 29_988_000;
        f.bestAsk = 30_012_000; // 4 bps half-width
        x.settleFixing(BOUNDARY, LazerBuilder.one(SIGNER_KEY, TICK_US, f));
        assertEq(x.fixingBatch(BOUNDARY).spreadBps, 16);
    }

    function test_theSizeTermReadsTheNet() public {
        FixingConfig memory fc = _fixCfg();
        fc.sizeBps = 20;
        fc.maxNet = 6_000e6;
        _setFix(fc);
        _commit(BUYER, true, 6_000e6);
        _commit(SELLER, false, 10 ether); // 3,000 crosses: the net is 3,000
        _settle(MANTISSA);
        assertEq(x.fixingBatch(BOUNDARY).spreadBps, 20);
    }

    // ── sessions ──────────────────────────────────────────────────────────

    function test_noCommitForATickInAClosedMarket() public {
        vm.warp(SAT + 12 hours);
        // forge-lint: disable-next-line(unsafe-typecast) - a 2026 timestamp.
        uint64 next = uint64(SAT + 13 hours);
        vm.prank(BUYER);
        vm.expectRevert(StockFixing.SessionClosed.selector);
        x.commitFixing(next, true, 1_000e6, BUYER);
    }

    function test_overnightTicksOnlyWhenOvernightIsLive() public {
        StockConfig memory c = _cfg();
        c.overnightLive = false;
        _setCfg(c);
        vm.warp(WED + 2 hours); // 22:00 New York
        // forge-lint: disable-next-line(unsafe-typecast) - a 2026 timestamp.
        uint64 next = uint64(WED + 3 hours);
        vm.prank(BUYER);
        vm.expectRevert(StockFixing.SessionClosed.selector);
        x.commitFixing(next, true, 1_000e6, BUYER);
    }

    // ── escrow, lapse, pause ──────────────────────────────────────────────

    function test_nothingIsClaimableUntilSettledOrLapsed() public {
        uint256 id = _commit(BUYER, true, 3_000e6);
        vm.warp(BOUNDARY + 3);
        vm.expectRevert(abi.encodeWithSelector(StockFixing.NotYetSettled.selector, BOUNDARY + 32));
        x.claimFixing(id);
    }

    function test_aBatchNotSettledInItsWindowLapsesAndRefundsInFull() public {
        uint256 id = _commit(BUYER, true, 3_000e6);
        uint256 sellId = _commit(SELLER, false, 5 ether);
        vm.warp(BOUNDARY + 33);
        bytes memory u = _at(TICK_US, MANTISSA);
        vm.expectRevert(abi.encodeWithSelector(StockFixing.SettleWindowClosed.selector, BOUNDARY + 32));
        x.settleFixing(BOUNDARY, u);

        (uint256 out, uint256 refund) = x.claimFixing(id);
        assertEq(out, 0);
        assertEq(refund, 3_000e6);
        x.claimFixing(sellId);
        assertEq(cash.balanceOf(BUYER), 1_000_000e6);
        assertEq(stock.balanceOf(SELLER), 1_000 ether);
        assertEq(x.state().cashOwed, 0);
        assertEq(x.state().stockOwed, 0);
    }

    function test_aPauseStopsCommitsAndSettlementButNeverClaims() public {
        uint256 id = _commit(BUYER, true, 3_000e6);
        vm.prank(GUARDIAN);
        x.pause(StockLib.PAUSE_FIXING);
        vm.prank(BUYER2);
        vm.expectRevert(StockFixing.FixingPaused.selector);
        x.commitFixing(BOUNDARY, true, 1_000e6, BUYER2);
        vm.warp(BOUNDARY + 3);
        bytes memory u = _at(TICK_US, MANTISSA);
        vm.expectRevert(StockFixing.FixingPaused.selector);
        x.settleFixing(BOUNDARY, u);
        vm.warp(BOUNDARY + 33);
        (, uint256 refund) = x.claimFixing(id);
        assertEq(refund, 3_000e6);
    }

    function test_escrowIsNotTheVaults() public {
        uint256 navBefore = sv.totalAssets();
        uint256 freeBefore = sv.maxWithdraw(OWNER);
        _commit(BUYER, true, 5_000e6);
        _commit(SELLER, false, 5 ether);
        assertEq(sv.totalAssets(), navBefore, "escrow adds no value");
        assertEq(sv.maxWithdraw(OWNER), freeBefore, "nor free cash");
        x.syncWindfall();
        assertEq(x.state().stockBooked, 30 ether, "nor stock");
    }

    function test_anInstantFillCannotTakeStockHeldForRequesters() public {
        _commit(BUYER, true, 8_700e6); // 29 STOCK, unclaimed after settlement
        _settle(MANTISSA);
        assertLt(x.state().stockBooked, 1.1 ether);
        _price(MANTISSA);
        _expectRefusal(Refusal.Inventory);
        _swap(true, false, 2 ether);
    }

    function test_theHedgeCannotSpendCashHeldForRequesters() public {
        // Sell the vault's cash away through the fixing, then try to margin the stock it took on.
        StockConfig memory c = _cfg();
        c.leverageX10 = 10;
        _setCfg(c);
        _commit(BUYER, true, 50_000e6);
        vm.prank(OWNER);
        sv.withdraw(9_000e6, OWNER, OWNER);
        // 1,000 of its own cash left against 30 STOCK to hedge at 1x: 9,000 of margin at the mark
        // plus 54 for the order opening 1.80 under it, plus 1% for the fee.
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(StockLib.CashShort.selector, 9_144_540_001, 1_000e6));
        x.syncHedge();
        assertEq(x.state().cashOwed, 50_000e6);
    }

    function test_settlementMovesValueOnlyByTheSpread() public {
        _commit(BUYER, true, 3_000e6);
        _commit(SELLER, false, 4 ether);
        uint256 navBefore = sv.totalAssets();
        _settle(MANTISSA); // the stored price is the same 300
        uint256 navAfter = sv.totalAssets();
        uint256 buySpread = 3_000e6 - Math.mulDiv(Math.mulDiv(3_000e6, 1e30, _askAt(PRICE, 10)), PRICE, 1e30);
        uint256 sellSpread = 1_200e6 - Math.mulDiv(4 ether, _bidAt(PRICE, 10), 1e30);
        assertApproxEqAbs(navAfter - navBefore, buySpread + sellSpread, 2);
    }

    // ── config ────────────────────────────────────────────────────────────

    function test_fixingConfigLimits() public {
        FixingConfig[5] memory bad;
        for (uint256 k; k < 5; ++k) {
            bad[k] = _fixCfg();
        }
        bad[0].delayMs = 1800; // under 2 s
        bad[1].delayMs = 2100; // off the grid
        bad[2].settleWindow = 4;
        bad[3].maxSpreadBps = 501;
        bad[4].sizeBps = 95; // base + size over the maximum
        for (uint256 k; k < 5; ++k) {
            vm.prank(OWNER);
            vm.expectRevert(StockFixing.BadFixingConfig.selector);
            x.setFixingConfig(bad[k]);
        }
        vm.prank(KEEPER);
        vm.expectRevert(StockModule.NotOwner.selector);
        x.setFixingConfig(_fixCfg());
    }

    function test_aClosedLaneTakesNoCommits() public {
        FixingConfig memory fc = _fixCfg();
        fc.interval = 0;
        _setFix(fc);
        vm.prank(BUYER);
        vm.expectRevert(StockFixing.FixingClosed.selector);
        x.commitFixing(BOUNDARY, true, 1_000e6, BUYER);
    }

    function test_aConfigChangeDoesNotMoveACommittedBatch() public {
        _commit(BUYER, true, 3_000e6);
        FixingConfig memory fc = _fixCfg();
        fc.delayMs = 4000;
        fc.settleWindow = 5;
        _setFix(fc);
        FixingBatch memory b = x.fixingBatch(BOUNDARY);
        assertEq(b.tickMs, TICK_US / 1000);
        assertEq(b.deadline, BOUNDARY + 32);
        _settle(MANTISSA);
    }

    function test_requestSizeLimits() public {
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(StockFixing.RequestTooSmall.selector, 9e6, 10e6));
        x.commitFixing(BOUNDARY, true, 9e6, BUYER);
        FixingConfig memory fc = _fixCfg();
        fc.maxSide = 5_000e6;
        _setFix(fc);
        _commit(BUYER, true, 4_000e6);
        vm.prank(BUYER2);
        vm.expectRevert(abi.encodeWithSelector(StockFixing.SideFull.selector, 2_000e6, 1_000e6));
        x.commitFixing(BOUNDARY, true, 2_000e6, BUYER2);
        // Stock is valued at the stored price: 20 STOCK is 6,000.
        vm.prank(SELLER);
        vm.expectRevert(abi.encodeWithSelector(StockFixing.SideFull.selector, 6_000e6, 5_000e6));
        x.commitFixing(BOUNDARY, false, 20 ether, SELLER);
    }

    // ── permissionless ────────────────────────────────────────────────────

    function test_anyoneClaimsButOnlyTheRecipientIsPaid() public {
        vm.prank(BUYER);
        uint256 id = x.commitFixing(BOUNDARY, true, 3_000e6, BUYER2);
        _settle(MANTISSA);
        FixingRequest memory r = x.fixingRequest(id);
        assertEq(r.recipient, BUYER2);
        vm.prank(address(0xDEAD));
        (uint256 out,) = x.claimFixing(id);
        assertEq(stock.balanceOf(BUYER2), 1_000 ether + out);
        vm.expectRevert(StockFixing.NoRequest.selector);
        x.claimFixing(id);
    }

    function test_settlementGasDoesNotGrowWithRequests() public {
        x.poke(); // both settlements then rewrite the same anchor
        _commit(BUYER, true, 1_000e6);
        vm.warp(BOUNDARY + 3);
        uint256 g = gasleft();
        x.settleFixing(BOUNDARY, _at(TICK_US, MANTISSA));
        uint256 one = g - gasleft();

        uint64 next = BOUNDARY + 3600;
        for (uint256 k; k < 40; ++k) {
            vm.prank(BUYER);
            x.commitFixing(next, true, 20e6, BUYER);
        }
        vm.warp(next + 3);
        bytes memory u = _at((next * 1000 + 2000) * 1000, MANTISSA);
        g = gasleft();
        x.settleFixing(next, u);
        uint256 forty = g - gasleft();
        assertLt(forty, one + 25_000, "one total per side, whatever the count");
    }

    // ── fuzz ──────────────────────────────────────────────────────────────

    /// Whatever the two sides, at a fixing equal to the stored price: every unit is accounted for,
    /// nothing stays owed once all claim, and the vault's value never falls.
    function testFuzz_aBatchConservesAndNeverCostsTheVault(uint256 buy1, uint256 buy2, uint256 sell1) public {
        buy1 = bound(buy1, 10e6, 40_000e6);
        buy2 = bound(buy2, 0, 40_000e6);
        sell1 = bound(sell1, 0, 300 ether);
        uint256[3] memory ids;
        ids[0] = _commit(BUYER, true, buy1);
        if (buy2 >= 10e6) ids[1] = _commit(BUYER2, true, buy2);
        if (sell1 >= 0.034 ether) ids[2] = _commit(SELLER, false, sell1);

        uint256 navBefore = sv.totalAssets();
        uint256 cashHeld = cash.balanceOf(address(sv)) + _claims(cash);
        uint256 stockHeld = stock.balanceOf(address(sv)) + _claims(stock);
        _settle(MANTISSA);
        uint256 cashPaid;
        uint256 stockPaid;
        for (uint256 k; k < 3; ++k) {
            if (ids[k] == 0) continue;
            (uint256 o, uint256 r) = x.claimFixing(ids[k]);
            if (k < 2) {
                stockPaid += o;
                cashPaid += r;
            } else {
                cashPaid += o;
                stockPaid += r;
            }
        }
        assertEq(x.state().cashOwed, 0);
        assertEq(x.state().stockOwed, 0);
        assertEq(cash.balanceOf(address(sv)) + _claims(cash), cashHeld - cashPaid);
        assertEq(stock.balanceOf(address(sv)) + _claims(stock), stockHeld - stockPaid);
        assertEq(x.state().stockBooked, stock.balanceOf(address(sv)) + _claims(stock), "booked is what is held");
        assertGe(sv.totalAssets(), navBefore);
    }
}
