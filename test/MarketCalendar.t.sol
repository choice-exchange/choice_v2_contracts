// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MarketCalendar} from "../src/stock/MarketCalendar.sol";

contract MarketCalendarTest is Test {
    address internal constant OWNER = address(0x0A11);
    address internal constant GUARDIAN = address(0x6A4D);

    MarketCalendar internal cal;

    // UTC instants, written out so a reader can check them against a world clock.
    uint256 internal constant MON_2026_10_12 = 1_791_763_200; // 2026-10-12 00:00:00Z
    uint256 internal constant H = 3600;

    function setUp() public {
        cal = new MarketCalendar(OWNER, GUARDIAN);
    }

    function _at(uint256 t, MarketCalendar.Session want, uint256 wantStart) internal view {
        (MarketCalendar.Session s, uint256 start) = cal.sessionAt(t);
        assertEq(uint256(s), uint256(want), "session");
        assertEq(start, wantStart, "start");
    }

    function test_anchor() public view {
        assertEq(cal.dayNumber(2026, 10, 12) * uint256(86_400), MON_2026_10_12);
        assertEq(cal.dayNumber(1970, 1, 1), 0);
    }

    function test_weekdaySessionsInDaylightTime() public view {
        uint256 m = MON_2026_10_12; // Sunday 20:00 EDT
        _at(m, MarketCalendar.Session.Overnight, m);
        _at(m + 7 * H, MarketCalendar.Session.Overnight, m); // 03:00 EDT
        _at(m + 8 * H, MarketCalendar.Session.PreMarket, m + 8 * H); // 04:00 EDT
        _at(m + 13 * H + 1799, MarketCalendar.Session.PreMarket, m + 8 * H);
        _at(m + 13 * H + 1800, MarketCalendar.Session.Regular, m + 13 * H + 1800); // 09:30 EDT
        _at(m + 20 * H - 1, MarketCalendar.Session.Regular, m + 13 * H + 1800);
        _at(m + 20 * H, MarketCalendar.Session.PostMarket, m + 20 * H); // 16:00 EDT
        _at(m + 24 * H - 1, MarketCalendar.Session.PostMarket, m + 20 * H);
        _at(m + 24 * H, MarketCalendar.Session.Overnight, m + 24 * H); // Monday 20:00 starts Tuesday
        assertEq(cal.tradingDay(m), cal.dayNumber(2026, 10, 12));
        assertEq(cal.tradingDay(m - 1), cal.dayNumber(2026, 10, 11));
    }

    function test_weekendIsClosedFromFridayEightPm() public view {
        uint256 sat = MON_2026_10_12 + 5 * 86_400; // 2026-10-17 00:00Z = Friday 20:00 EDT
        _at(sat - 1, MarketCalendar.Session.PostMarket, sat - 4 * H);
        _at(sat, MarketCalendar.Session.Closed, sat);
        _at(sat + 30 * H, MarketCalendar.Session.Closed, sat);
        _at(sat + 48 * H - 1, MarketCalendar.Session.Closed, sat); // Sunday 19:59:59 EDT
        _at(sat + 48 * H, MarketCalendar.Session.Overnight, sat + 48 * H); // Sunday 20:00 EDT
    }

    function test_daylightSavingSwitches() public view {
        // 2026: starts Sunday March 8 at 07:00Z, ends Sunday November 1 at 06:00Z.
        uint256 mar8 = uint256(cal.dayNumber(2026, 3, 8)) * 86_400;
        assertEq(cal.utcOffset(mar8 + 7 * H - 1), -5 * int256(H));
        assertEq(cal.utcOffset(mar8 + 7 * H), -4 * int256(H));
        uint256 nov1 = uint256(cal.dayNumber(2026, 11, 1)) * 86_400;
        assertEq(cal.utcOffset(nov1 + 6 * H - 1), -4 * int256(H));
        assertEq(cal.utcOffset(nov1 + 6 * H), -5 * int256(H));
        // 2027: March 14 and November 7.
        assertEq(cal.utcOffset(uint256(cal.dayNumber(2027, 3, 14)) * 86_400 + 7 * H), -4 * int256(H));
        assertEq(cal.utcOffset(uint256(cal.dayNumber(2027, 3, 14)) * 86_400 + 7 * H - 1), -5 * int256(H));
        assertEq(cal.utcOffset(uint256(cal.dayNumber(2027, 11, 7)) * 86_400 + 6 * H), -5 * int256(H));
    }

    function test_sessionsMoveAnHourAfterTheNovemberSwitch() public view {
        uint256 mon = uint256(cal.dayNumber(2026, 11, 2)) * 86_400; // Monday after the switch
        _at(mon + 30 * 60, MarketCalendar.Session.Closed, mon - 2 * 86_400); // Sun 19:30 EST; closed since Fri 20:00 EDT
        _at(mon + H, MarketCalendar.Session.Overnight, mon + H); // Sunday 20:00 EST = 01:00Z
        _at(mon + 14 * H + 1800, MarketCalendar.Session.Regular, mon + 14 * H + 1800); // 09:30 EST
        uint256 sat = mon + 5 * 86_400;
        _at(sat + H, MarketCalendar.Session.Closed, sat + H); // Friday 20:00 EST
    }

    function test_holidayAndHalfDay() public {
        uint32 thanksgiving = cal.dayNumber(2026, 11, 26);
        uint32 blackFriday = cal.dayNumber(2026, 11, 27);
        vm.startPrank(OWNER);
        uint32[] memory one = new uint32[](1);
        one[0] = thanksgiving;
        cal.setDays(one, MarketCalendar.DayType.Closed);
        one[0] = blackFriday;
        cal.setDays(one, MarketCalendar.DayType.Half);
        vm.stopPrank();

        uint256 thu = uint256(thanksgiving) * 86_400;
        uint256 fri = uint256(blackFriday) * 86_400;
        // Closed from Wednesday 20:00 EST (Thursday 01:00Z) to Thursday 20:00 EST.
        _at(thu + H - 1, MarketCalendar.Session.PostMarket, thu - 3 * H);
        _at(thu + 15 * H, MarketCalendar.Session.Closed, thu + H);
        _at(fri + H, MarketCalendar.Session.Overnight, fri + H);
        _at(fri + 18 * H - 1, MarketCalendar.Session.Regular, fri + 14 * H + 1800);
        _at(fri + 18 * H, MarketCalendar.Session.PostMarket, fri + 18 * H); // 13:00 EST
        _at(fri + 22 * H - 1, MarketCalendar.Session.PostMarket, fri + 18 * H);
        _at(fri + 22 * H, MarketCalendar.Session.Closed, fri + 22 * H); // 17:00 EST
        _at(fri + 36 * H, MarketCalendar.Session.Closed, fri + 22 * H); // Saturday: still the half day's close
    }

    function test_guardianCanOnlyClose() public {
        uint32[] memory one = new uint32[](1);
        one[0] = cal.dayNumber(2026, 10, 13);
        vm.prank(GUARDIAN);
        cal.closeDays(one);
        assertEq(uint256(cal.dayType(one[0])), uint256(MarketCalendar.DayType.Closed));

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        cal.setDays(one, MarketCalendar.DayType.Normal);

        vm.prank(address(0xBAD));
        vm.expectRevert(MarketCalendar.NotGuardianOrOwner.selector);
        cal.closeDays(one);

        vm.prank(OWNER);
        cal.setDays(one, MarketCalendar.DayType.Normal);
        assertEq(uint256(cal.dayType(one[0])), uint256(MarketCalendar.DayType.Normal));
    }

    function test_weekendOverrideStaysClosed() public {
        uint32[] memory one = new uint32[](1);
        one[0] = cal.dayNumber(2026, 10, 17); // a Saturday
        vm.prank(OWNER);
        cal.setDays(one, MarketCalendar.DayType.Normal);
        (MarketCalendar.Session s,) = cal.sessionAt(uint256(one[0]) * 86_400 + 15 * H);
        assertEq(uint256(s), uint256(MarketCalendar.Session.Closed));
    }

    function test_revertsPastTheLookback() public {
        uint32 first = cal.dayNumber(2026, 10, 12);
        uint32[] memory dayList = new uint32[](12);
        for (uint32 i; i < 12; ++i) {
            dayList[i] = first + i;
        }
        vm.prank(OWNER);
        cal.setDays(dayList, MarketCalendar.DayType.Closed);
        vm.expectRevert(
            abi.encodeWithSelector(MarketCalendar.ClosedTooLong.selector, uint256(first + 11) * 86_400 + 15 * H)
        );
        cal.sessionAt(uint256(first + 11) * 86_400 + 15 * H);
    }

    /// Every session begins at its own start, and the second before that start belongs to a
    /// different session: the calendar never reports a start it would not itself agree with.
    function testFuzz_startIsConsistent(uint256 t) public view {
        t = bound(t, 1_767_225_600, 2_208_988_800); // 2026 to 2040
        (MarketCalendar.Session s, uint256 start) = cal.sessionAt(t);
        assertLe(start, t);
        (MarketCalendar.Session s2, uint256 start2) = cal.sessionAt(start);
        assertEq(uint256(s2), uint256(s));
        assertEq(start2, start);
        (MarketCalendar.Session before,) = cal.sessionAt(start - 1);
        assertTrue(before != s, "a session's start is a change of session");
    }
}
