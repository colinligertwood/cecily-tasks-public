import Foundation

/// How an item repeats: on a schedule fixed by the calendar, or a set time after each
/// one is done.
///
/// Only one copy of a repeating item is open at a time. When it's completed or skipped, the next
/// copy's date comes from `nextDate(after:closedOn:seriesStart:)`.
public struct RepeatRule: Hashable, Sendable, Codable {
    public enum Unit: String, Sendable, Codable, CaseIterable {
        case day
        case week
        case month
        case year
    }

    public enum Mode: Hashable, Sendable, Codable {
        case schedule(Recurrence)
        case afterCompletion(value: Int, unit: Unit)
    }

    public var mode: Mode
    /// Days before each date that the copy comes into view; 0 shows it from the day itself.
    public var showDaysBefore: Int
    /// The last day a copy may fall on.
    public var endDate: LocalDate?
    /// Copies still to be made after the open one; nil for no limit.
    public var remainingCount: Int?

    public init(_ mode: Mode, showDaysBefore: Int = 0, endDate: LocalDate? = nil, remainingCount: Int? = nil) {
        self.mode = mode
        self.showDaysBefore = showDaysBefore
        self.endDate = endDate
        self.remainingCount = remainingCount
    }

    /// The date of the copy that follows one dated `current` and closed (done or skipped) on
    /// `closedOn`, or nil when the repeat has ended. On a schedule, that's the first date after
    /// both, so dates that passed while the copy was open are skipped rather than made overdue.
    public func nextDate(after current: LocalDate, closedOn: LocalDate, seriesStart: LocalDate) -> LocalDate? {
        if let remainingCount, remainingCount <= 0 { return nil }
        let next: LocalDate?
        switch mode {
        case .schedule(let recurrence):
            next = recurrence.nextOccurrence(after: max(current, closedOn), seriesStart: seriesStart)
        case .afterCompletion(let value, let unit):
            next = closedOn.adding(value, unit)
        }
        guard let next else { return nil }
        if let endDate, next > endDate { return nil }
        return next
    }

    /// The rule to give the next copy: one fewer remaining, when there's a limit.
    public func advanced() -> RepeatRule {
        var rule = self
        rule.remainingCount = remainingCount.map { max($0 - 1, 0) }
        return rule
    }

    /// When a copy dated `date` should come into view, or nil to show it straight away.
    public func hideUntil(for date: LocalDate) -> LocalDate? {
        showDaysBefore > 0 ? date.adding(days: -showDaysBefore) : nil
    }
}

extension LocalDate {
    public func adding(_ value: Int, _ unit: RepeatRule.Unit) -> LocalDate {
        switch unit {
        case .day: adding(days: value)
        case .week: adding(days: value * 7)
        case .month: adding(months: value)
        case .year: adding(months: value * 12)
        }
    }
}
