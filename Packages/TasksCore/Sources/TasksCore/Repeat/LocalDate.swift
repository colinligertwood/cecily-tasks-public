import Foundation

/// A day on the calendar, with no time and no time zone.
///
/// Repeat rules work in days, so that a change of time zone or daylight saving never moves an
/// occurrence to another day. A day becomes a moment only when it's shown or notified, through
/// `date(in:hour:minute:)`.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }

    /// Reads `yyyy-MM-dd` or `yyyyMMdd`.
    public init?(_ text: String) {
        let digits = text.filter { $0 != "-" }
        guard digits.count == 8, digits.allSatisfy(\.isASCII), let value = Int(digits) else { return nil }
        let date = LocalDate(value / 10000, value / 100 % 100, value % 100)
        guard (1...12).contains(date.month), (1...LocalDate.daysIn(month: date.month, year: date.year)).contains(date.day) else { return nil }
        self = date
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// The moment this day reaches the given time in `calendar`'s time zone. A time that doesn't
    /// exist that day, inside a daylight-saving gap, moves forward by the length of the gap.
    public func date(in calendar: Calendar, hour: Int = 0, minute: Int = 0) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        if let date = calendar.date(from: parts) {
            return date
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    // MARK: Day arithmetic

    /// 1 is Sunday and 7 is Saturday, as in `Calendar`.
    public var weekday: Int {
        LocalDate.dayCalendar.component(.weekday, from: noon)
    }

    public var isLastDayOfMonth: Bool {
        day == LocalDate.daysIn(month: month, year: year)
    }

    public func adding(days: Int) -> LocalDate {
        LocalDate(LocalDate.dayCalendar.date(byAdding: .day, value: days, to: noon) ?? noon, in: LocalDate.dayCalendar)
    }

    /// Adds whole months, keeping the day of the month where it can and otherwise using the
    /// month's last day (31 January plus one month is 28 or 29 February).
    public func adding(months: Int) -> LocalDate {
        let total = year * 12 + (month - 1) + months
        let newYear = total.floorDivided(by: 12)
        let newMonth = total - newYear * 12 + 1
        return LocalDate(newYear, newMonth, min(day, LocalDate.daysIn(month: newMonth, year: newYear)))
    }

    /// Days from this day to `other`; negative when `other` is earlier.
    public func days(to other: LocalDate) -> Int {
        LocalDate.dayCalendar.dateComponents([.day], from: noon, to: other.noon).day ?? 0
    }

    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    public static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// A Gregorian calendar in UTC, which has no daylight saving, for counting days.
    static let dayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private var noon: Date {
        LocalDate.dayCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }
}

extension Int {
    fileprivate func floorDivided(by divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
