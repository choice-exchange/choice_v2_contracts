// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StockLib} from "../src/stock/StockLib.sol";
import {Fill, Refusal, StockConfig} from "../src/stock/StockTypes.sol";
import {LazerBuilder} from "./utils/LazerBuilder.sol";
import {StockVaultHarness} from "./utils/StockVaultHarness.sol";

/// The flow caps (a gross and a net bucket that drain continuously, and a net cap over a whole closed
/// period), the scarcity premium, the config invariants and `room`. The vault starts holding 10,000
/// cash and 30 STOCK (9,000) at 300, with no short.
contract StockFlowCapsTest is StockVaultHarness {
    uint256 internal constant FULL = 1e18;

    function _caps(uint96 maxTrade, uint96 netCap, uint96 windowCap) internal returns (StockConfig memory c) {
        c = _cfg();
        c.maxTrade = maxTrade;
        c.netCap = netCap;
        c.windowCap = windowCap;
        if (c.maxTradeClosed > maxTrade) c.maxTradeClosed = maxTrade;
        if (c.windowCapClosed > windowCap) c.windowCapClosed = windowCap;
        _setCfg(c);
    }

    function _room(bool cashIn) internal view returns (uint256 maxCash, Refusal binding) {
        return x.room(cashIn, "");
    }

    // ── the gross bucket ──────────────────────────────────────────────────

    /// Round trips fill the gross bucket, and it gives capacity back at the cap per window, second by
    /// second: there is no reset to wait for, and none to burst across.
    function test_theGrossBucketDrainsContinuously() public {
        _caps(2_000e6, 4_000e6, 4_000e6);
        _swap(false, false, 2_000e6); // sell for 2,000 cash
        _swap(true, true, 2_000e6); // buy with 2,000 cash
        uint256 gross = x.state().grossUsed;
        assertGt(gross, FULL * 99 / 100);
        (uint256 room, Refusal binding) = _room(false);
        assertLt(room, 10e6);
        assertEq(uint256(binding), uint256(Refusal.Window));

        // A quarter of the window gives back a quarter of the cap, no more.
        vm.warp(block.timestamp + 900);
        _price(MANTISSA);
        (room, binding) = _room(false);
        assertApproxEqAbs(room, (FULL - (gross - FULL / 4)) * 4_000e6 / FULL, 1);
        assertEq(uint256(binding), uint256(Refusal.Window));
        _expectRefusal(Refusal.Window);
        _swap(false, false, room + 1);
        _swap(false, false, room);

        // A whole window after the last fill, the bucket is empty again.
        vm.warp(block.timestamp + 3600);
        _price(MANTISSA);
        (room, binding) = _room(false);
        assertEq(room, 2_000e6);
        assertEq(uint256(binding), uint256(Refusal.Size));
    }

    /// Keeping the bucket full means paying its whole `windowBps` on every fill, for as long as it is
    /// kept full.
    function test_aFullBucketChargesTheWholeWindowTerm() public {
        StockConfig memory c = _caps(2_000e6, 4_000e6, 4_000e6);
        c.windowBps = 100;
        _setCfg(c);
        assertEq(sv.quoteFill(true, 1e6, true, "").spreadBps, 25 + 1, "an empty bucket");
        _swap(false, false, 2_000e6);
        (uint256 room,) = _room(true);
        _swap(true, true, room);
        assertEq(sv.quoteFill(true, 1e6, true, "").spreadBps, 25 + 100, "a full one");
        vm.warp(block.timestamp + 1800);
        _price(MANTISSA);
        assertLt(sv.quoteFill(true, 1e6, true, "").spreadBps, 25 + 55, "half drained");
    }

    // ── the net bucket ────────────────────────────────────────────────────

    /// One-way flow stops at `netCap` while the gross cap still has room; flow back the other way always
    /// passes and frees it again.
    function test_theNetBucketCapsOneWayFlow() public {
        _caps(2_000e6, 3_000e6, 13_000e6);
        _swap(false, false, 2_000e6);
        _expectRefusal(Refusal.Net);
        _swap(false, false, 1_001e6);
        _swap(false, false, 990e6);
        (uint256 room, Refusal binding) = _room(false);
        assertApproxEqAbs(room, 10e6, 1); // 3,000 less 2,990
        assertEq(uint256(binding), uint256(Refusal.Net));

        _swap(true, true, 2_000e6); // back the other way
        (room, binding) = _room(false);
        assertGt(room, 1_900e6);
        // Round trips run on until the gross cap.
        for (uint256 k; k < 2; ++k) {
            _swap(false, false, 1_900e6);
            _swap(true, true, 1_900e6);
        }
        (room, binding) = _room(false);
        assertLt(room, 1_000e6);
        assertEq(uint256(binding), uint256(Refusal.Window));
    }

    /// The net count drains toward zero from either side.
    function test_theNetBucketDrainsTowardZero() public {
        _caps(2_000e6, 2_000e6, 8_000e6);
        _swap(true, true, 2_000e6);
        int256 net = x.state().netUsed;
        assertGt(net, int256(FULL * 99 / 100));
        vm.warp(block.timestamp + 1800);
        _price(MANTISSA);
        (uint256 room, Refusal binding) = _room(true);
        assertApproxEqAbs(room, 1_000e6, 10e6);
        assertEq(uint256(binding), uint256(Refusal.Net));
    }

    // ── the closed period ─────────────────────────────────────────────────

    function _weekendPrice() internal {
        vm.warp(SAT + 12 hours);
        LazerBuilder.Feed memory f = _feed(MANTISSA);
        f.feedTimestampUs = uint64(SAT) * 1e6 - 200_000;
        store.update(_update(f));
    }

    /// The hourly buckets drain over a weekend, so on their own they would let it take out a window's cap
    /// every hour. The closed period's net does not drain.
    function test_aWeekendsNetIsCappedWhateverTheHour() public {
        _weekendPrice();
        for (uint256 k; k < 3; ++k) {
            _swap(false, false, 1_000e6);
        }
        _expectRefusal(Refusal.Window);
        _swap(false, false, 1e6);

        vm.warp(block.timestamp + 6 hours);
        _expectRefusal(Refusal.ClosedNet);
        _swap(false, false, 1e6);
        (uint256 room, Refusal binding) = _room(false);
        assertEq(room, 0);
        assertEq(uint256(binding), uint256(Refusal.ClosedNet));
        assertEq(x.state().closedNet, -3_000e6);
        // Back the other way passes, and makes room.
        _swap(true, true, 1_000e6);
        _swap(false, false, 900e6);
    }

    /// A weekend that runs into an overnight priced as closed is one closed period; the next night,
    /// after a day in session, is a new one.
    function test_aClosedPeriodRunsOnIntoAnOvernightPricedAsClosed() public {
        StockConfig memory c = _cfg();
        c.overnightLive = false;
        _setCfg(c);
        _weekendPrice();
        for (uint256 k; k < 3; ++k) {
            _swap(false, false, 1_000e6);
        }
        uint64 weekendStart = x.state().closedStart;

        vm.warp(SAT + 2 days + 2 hours); // Sunday 22:00 New York: the overnight, priced as closed
        _price(MANTISSA);
        assertTrue(sv.quoteFill(false, 1e6, false, "").closed);
        _expectRefusal(Refusal.ClosedNet);
        _swap(false, false, 1e6);

        vm.warp(SAT + 3 days + 2 hours); // Monday 22:00: the next overnight, after Monday's session
        _price(MANTISSA);
        _swap(false, false, 1_000e6);
        assertGt(x.state().closedStart, weekendStart);
        assertEq(x.state().closedNet, -1_000e6);
    }

    // ── scarcity ──────────────────────────────────────────────────────────

    function _scarce(uint96 reserve, uint16 bps) internal {
        StockConfig memory c = _cfg();
        c.scarcityReserve = reserve;
        c.scarcityBps = bps;
        _setCfg(c);
    }

    /// Buying into the reserve pays a premium that rises to `scarcityBps` at the last unit, outside the
    /// spread, so the last unit is dear but still for sale.
    function test_buyingTheReservePaysThePremium() public {
        _scarce(3_000e6, 300);
        // 9,000 held: a 1,000 buy leaves 8,000, above the reserve, so no premium.
        assertEq(
            sv.quoteFill(true, 1_000e6, true, "").amountOut,
            Math.mulDiv(1_000e6, 1e30, Math.mulDiv(PRICE, 10_025, 10_000, Math.Rounding.Ceil))
        );
        _swap(true, true, 5_000e6);
        uint256 held = x.state().stockBooked * PRICE / 1e30;
        // A 2,000 buy now leaves `held - 2,000` of a 3,000 reserve.
        uint256 premium = Math.mulDiv(300, 3_000e6 - (held - 2_000e6), 3_000e6, Math.Rounding.Ceil);
        assertGt(premium, 0);
        Fill memory f = sv.quoteFill(true, 2_000e6, true, "");
        assertEq(f.spreadBps, 25, "the premium is not spread: it never refuses");
        assertEq(
            f.amountOut, Math.mulDiv(2_000e6, 1e30, Math.mulDiv(PRICE, 10_025 + premium, 10_000, Math.Rounding.Ceil))
        );
        // All that is left pays the whole premium, and still fills.
        uint256 all = x.state().stockBooked;
        f = sv.quoteFill(true, all, false, "");
        assertEq(uint256(f.reason), uint256(Refusal.None));
        assertEq(
            f.amountIn,
            Math.mulDiv(all, Math.mulDiv(PRICE, 10_325, 10_000, Math.Rounding.Ceil), 1e30, Math.Rounding.Ceil)
        );
        _swap(true, false, all);
        assertEq(x.state().stockBooked, 0);
    }

    /// The mirror: selling into the vault as its free cash runs low fetches less.
    function test_sellingIntoLowCashPaysThePremium() public {
        _scarce(12_000e6, 300);
        // 10,000 free: a 1,000 sale leaves 9,000 of a 12,000 reserve, a quarter short.
        uint256 bid = PRICE * (10_000 - 25 - 75) / 10_000;
        assertEq(sv.quoteFill(false, 1_000e6, false, "").amountIn, Math.mulDiv(1_000e6, 1e30, bid, Math.Rounding.Ceil));
    }

    // ── the config invariants ─────────────────────────────────────────────

    function _refused(StockConfig memory c) internal {
        vm.prank(OWNER);
        vm.expectRevert(StockLib.BadConfig.selector);
        x.setConfig(c);
    }

    function test_theConfigInvariants() public {
        StockConfig memory c = _cfg();
        c.scarcityBps = StockLib.MAX_SPREAD_LIMIT + 1;
        _refused(c);
        c = _cfg();
        c.netCap = c.maxTrade - 1; // a full trade could never pass the net bucket
        _refused(c);
        c = _cfg();
        c.netCap = c.windowCap + 1;
        _refused(c);
        c = _cfg();
        c.maxTradeClosed = c.maxTrade + 1;
        _refused(c);
        c = _cfg();
        c.windowCapClosed = c.windowCap + 1;
        _refused(c);
        c = _cfg();
        c.maxTradeClosed = c.windowCapClosed + 1;
        _refused(c);
        c = _cfg();
        c.closedNetCap = c.maxTradeClosed - 1;
        _refused(c);
        c = _cfg();
        c.maxUnhedged = c.maxTrade + c.hedgeBand - 1; // a full trade would leave too much unhedged
        _refused(c);

        // Each at its bound passes.
        c = _cfg();
        c.netCap = c.maxTrade;
        c.closedNetCap = c.maxTradeClosed;
        c.maxUnhedged = c.maxTrade + c.hedgeBand;
        c.scarcityBps = StockLib.MAX_SPREAD_LIMIT;
        _setCfg(c);
    }

    // ── room ──────────────────────────────────────────────────────────────

    function test_roomIsTheTradeCapWhenNothingElseBinds() public view {
        (uint256 room, Refusal binding) = _room(true);
        assertEq(room, 5_000e6);
        assertEq(uint256(binding), uint256(Refusal.Size));
    }

    function test_roomIsZeroWithTheReasonWhenNothingFills() public {
        vm.prank(GUARDIAN);
        x.pause(uint8(StockLib.PAUSE_FILLS));
        (uint256 room, Refusal binding) = _room(false);
        assertEq(room, 0);
        assertEq(uint256(binding), uint256(Refusal.Paused));
    }

    /// Whatever has filled before, `room` passes and one unit more is refused, for the reason it gives.
    function testFuzz_roomIsTheLargestFillThatPasses(uint256 before, bool beforeIn, bool cashIn, uint256 wait) public {
        StockConfig memory c = _caps(3_000e6, 4_000e6, 7_000e6);
        c.windowBps = 50;
        c.sizeBps = 20;
        c.scarcityReserve = 6_000e6;
        c.scarcityBps = 200;
        c.maxUnhedged = 14_000e6;
        _setCfg(c);
        before = bound(before, 0, 3_000e6);
        if (before > 1e6) _swap(beforeIn, beforeIn, before);
        vm.warp(block.timestamp + bound(wait, 0, 2 hours));
        _price(MANTISSA);

        (uint256 room, Refusal binding) = _room(cashIn);
        assertTrue(binding != Refusal.None);
        if (room != 0) {
            assertEq(uint256(sv.quoteFill(cashIn, room, cashIn, "").reason), uint256(Refusal.None));
        }
        assertEq(uint256(sv.quoteFill(cashIn, room + 1, cashIn, "").reason), uint256(binding));
        if (room != 0) _swap(cashIn, cashIn, room);
    }
}
