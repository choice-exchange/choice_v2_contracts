// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MarketCalendar
/// @notice The US equity trading sessions, in UTC, for contracts that must know whether the market
/// is open without trusting a price feed to say so.
///
/// **The schedule.** Times are New York local time. A trading day D runs from 20:00 on the evening
/// before D to 20:00 on D: overnight 20:00-04:00, pre-market 04:00-09:30, regular 09:30-16:00,
/// post-market 16:00-20:00. A half day ends regular trading at 13:00 and post-market at 17:00, then
/// is closed until 20:00. Saturday and Sunday trading days are closed, so the week's closed spell
/// runs from Friday 20:00 to Sunday 20:00.
///
/// **Daylight saving is computed, not configured**: New York is UTC-4 from the second Sunday of
/// March at 02:00 local to the first Sunday of November at 02:00 local, UTC-5 otherwise (the US rule
/// since 2007). Holidays and half days are the only inputs, set by the owner a year or more ahead.
///
/// **Who may change a day.** The owner sets any day to normal, closed or half. The guardian may only
/// CLOSE a day: an unscheduled closure (a national day of mourning, an exchange outage) must not wait
/// for a timelock, and closing is the safe direction. A consumer treating a closed day as open would
/// trade on a frozen price; treating an open day as closed only widens its spread and stops deposits.
contract MarketCalendar is Ownable2Step {
    enum Session {
        Closed,
        Overnight,
        PreMarket,
        Regular,
        PostMarket
    }

    enum DayType {
        Normal,
        Closed,
        Half
    }

    int256 internal constant HOUR = 3600;
    int256 internal constant DAY = 86_400;
    int256 internal constant OVERNIGHT_START = -4 * HOUR; // 20:00 the evening before
    int256 internal constant PRE_START = 4 * HOUR;
    int256 internal constant REGULAR_START = 9 * HOUR + 30 * 60;
    int256 internal constant REGULAR_END = 16 * HOUR;
    int256 internal constant HALF_REGULAR_END = 13 * HOUR;
    int256 internal constant POST_END = 20 * HOUR;
    int256 internal constant HALF_POST_END = 17 * HOUR;
    /// @dev The longest closed run the calendar will look back over: a weekend plus a holiday on
    /// each side is four days; ten leaves room for an unscheduled closure next to them.
    uint256 internal constant MAX_LOOKBACK_DAYS = 10;

    address public guardian;
    mapping(uint32 day => DayType) public dayType;

    error NotGuardianOrOwner();

    event DaySet(uint32 indexed day, DayType dayType);
    event GuardianUpdated(address guardian);

    constructor(address owner_, address guardian_) Ownable(owner_) {
        guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    // -------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------

    /// @notice The session at UTC time `t`.
    function session(uint256 t) external view returns (Session s) {
        (s,) = sessionAt(t);
    }

    /// @notice The session at UTC time `t` and when it began, in UTC. For a closed spell, `start`
    /// is the end of the last session before it: the close whose price a frozen market holds. A spell
    /// longer than `MAX_LOOKBACK_DAYS` (only a run of unscheduled closures makes one) answers `t`
    /// itself: its close is too far back to price off, so a reader that wants a price from after the
    /// close needs one from now. It never reverts, so a reader can refuse rather than fail.
    function sessionAt(uint256 t) public view returns (Session s, uint256 start) {
        int256 off = utcOffset(t);
        // forge-lint: disable-next-line(unsafe-typecast) - block timestamps are far below 2**255.
        int256 local = int256(t) + off;
        int256 day = (local - OVERNIGHT_START) / DAY;
        int256 sod = local - day * DAY; // seconds after day's local midnight, from -4h to 20h
        // forge-lint: disable-next-line(unsafe-typecast) - days since 1970 fit 32 bits for 11 million years.
        uint32 d = uint32(uint256(day));
        DayType kind = _kind(d);
        if (kind != DayType.Closed) {
            bool half = kind == DayType.Half;
            int256 regularEnd = half ? HALF_REGULAR_END : REGULAR_END;
            int256 postEnd = half ? HALF_POST_END : POST_END;
            int256 base = day * DAY;
            if (sod < PRE_START) return (Session.Overnight, _utc(base + OVERNIGHT_START));
            if (sod < REGULAR_START) return (Session.PreMarket, _utc(base + PRE_START));
            if (sod < regularEnd) return (Session.Regular, _utc(base + REGULAR_START));
            if (sod < postEnd) return (Session.PostMarket, _utc(base + regularEnd));
            return (Session.Closed, _utc(base + postEnd));
        }
        return (Session.Closed, _lastClose(d, t));
    }

    /// @notice New York's offset from UTC at UTC time `t`, in seconds: -4h in daylight saving time,
    /// -5h otherwise.
    function utcOffset(uint256 t) public pure returns (int256) {
        uint256 year = _year(t / 86_400);
        uint256 dstStart = _nthSunday(year, 3, 2) * 86_400 + 7 hours; // 02:00 EST
        uint256 dstEnd = _nthSunday(year, 11, 1) * 86_400 + 6 hours; // 02:00 EDT
        return t >= dstStart && t < dstEnd ? -4 * HOUR : -5 * HOUR;
    }

    /// @notice The trading day `t` falls in, as days since 1970-01-01 of its New York date.
    function tradingDay(uint256 t) external pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast) - block timestamps are far below 2**255.
        int256 local = int256(t) + utcOffset(t);
        // forge-lint: disable-next-line(unsafe-typecast) - non-negative for any t after 1970-01-01 04:00.
        return uint32(uint256((local - OVERNIGHT_START) / DAY));
    }

    /// @notice The day number of a calendar date, for setting days: `dayNumber(2026, 11, 26)`.
    function dayNumber(uint256 year, uint256 month, uint256 dayOfMonth) external pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast) - days since 1970 fit 32 bits.
        return uint32(_daysFromCivil(year, month, dayOfMonth));
    }

    // -------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------

    function setDays(uint32[] calldata dayList, DayType kind) external onlyOwner {
        for (uint256 i; i < dayList.length; ++i) {
            dayType[dayList[i]] = kind;
            emit DaySet(dayList[i], kind);
        }
    }

    /// @notice Close `days`. The guardian's only power: it cannot reopen a day.
    function closeDays(uint32[] calldata dayList) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        for (uint256 i; i < dayList.length; ++i) {
            dayType[dayList[i]] = DayType.Closed;
            emit DaySet(dayList[i], DayType.Closed);
        }
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    /// @dev A weekend day is closed whatever its override says.
    function _kind(uint32 d) internal view returns (DayType) {
        uint256 weekday = (uint256(d) + 4) % 7; // 1970-01-01 was a Thursday; 0 = Sunday
        if (weekday == 0 || weekday == 6) return DayType.Closed;
        return dayType[d];
    }

    /// @dev Day `d` is closed: the spell began when the last open day before it ended.
    function _lastClose(uint32 d, uint256 t) internal view returns (uint256) {
        for (uint256 k = 1; k <= MAX_LOOKBACK_DAYS; ++k) {
            // forge-lint: disable-next-line(unsafe-typecast) - k <= MAX_LOOKBACK_DAYS.
            uint32 prev = d - uint32(k);
            DayType kind = _kind(prev);
            if (kind == DayType.Closed) continue;
            int256 base = int256(uint256(prev)) * DAY;
            return _utc(base + (kind == DayType.Half ? HALF_POST_END : POST_END));
        }
        return t;
    }

    /// @dev A New York local time (seconds, as if it were UTC) back to UTC. No session boundary
    /// sits within hours of a daylight-saving switch (02:00 on a Sunday), so the offset at the
    /// local time read as UTC plus five hours is the offset at the instant itself.
    function _utc(int256 local) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast) - local times here are after 1970.
        uint256 guess = uint256(local + 5 * HOUR);
        // forge-lint: disable-next-line(unsafe-typecast) - as above.
        return uint256(local - utcOffset(guess));
    }

    /// @dev The day number of the `n`th Sunday of `month` in `year`.
    function _nthSunday(uint256 year, uint256 month, uint256 n) internal pure returns (uint256) {
        uint256 first = _daysFromCivil(year, month, 1);
        uint256 weekday = (first + 4) % 7;
        return first + (7 - weekday) % 7 + (n - 1) * 7;
    }

    /// @dev Howard Hinnant's days_from_civil, for dates from 1970.
    function _daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    /// @dev The year of day number `z`, from Hinnant's civil_from_days.
    function _year(uint256 z) internal pure returns (uint256) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        return yoe + era * 400 + (mp >= 10 ? 1 : 0);
    }
}
