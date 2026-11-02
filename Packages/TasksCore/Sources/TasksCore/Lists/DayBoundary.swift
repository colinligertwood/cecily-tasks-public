import Foundation

/// When each day starts: a time after midnight, 04:00 unless set otherwise. Until then it's
/// still the day before, so at 1 a.m. tomorrow's items aren't due, scheduled or back yet.
public struct DayBoundary: Hashable, Sendable {
    /// Minutes after midnight.
    public var minutes: Int

    public init(minutes: Int = 4 * 60) {
        self.minutes = min(max(minutes, 0), 24 * 60 - 1)
    }

    /// The day `now` is in, in `calendar`'s time zone.
    public func day(at now: Date, in calendar: Calendar) -> LocalDate {
        let date = LocalDate(now, in: calendar)
        return now < start(of: date, in: calendar) ? date.adding(days: -1) : date
    }

    /// The moment `day` starts. A start inside a daylight-saving gap moves forward by the length
    /// of the gap.
    public func start(of day: LocalDate, in calendar: Calendar) -> Date {
        day.date(in: calendar, hour: minutes / 60, minute: minutes % 60)
    }

    /// The moment the day after the one `now` is in starts.
    public func nextStart(after now: Date, in calendar: Calendar) -> Date {
        start(of: day(at: now, in: calendar).adding(days: 1), in: calendar)
    }
}
