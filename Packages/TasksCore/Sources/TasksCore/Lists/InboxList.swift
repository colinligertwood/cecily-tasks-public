import Foundation

/// The Inbox's groups and words: the rows by when they came in, and when it
/// was last emptied.
public enum InboxList {
    /// When an item came in, as the Inbox groups it.
    public enum Period: CaseIterable, Sendable {
        case today
        case yesterday
        /// The days before yesterday since the week started.
        case thisWeek
        case earlier

        public var name: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .thisWeek: "This Week"
            case .earlier: "Earlier"
            }
        }
    }

    /// When `item` came in, by the day it was captured, with days starting at `boundary`, and
    /// weeks on the calendar's first weekday.
    public static func period(of item: Item, today: LocalDate, boundary: DayBoundary, in calendar: Calendar) -> Period {
        let day = boundary.day(at: item.createdAt, in: calendar)
        if day >= today { return .today }
        if day == today.adding(days: -1) { return .yesterday }
        let sinceWeekStart = (today.weekday - calendar.firstWeekday + 7) % 7
        return day >= today.adding(days: -sinceWeekStart) ? .thisWeek : .earlier
    }

    /// "Emptied this morning", "Emptied yesterday", "Emptied on Monday", "Emptied on 12 October".
    public static func emptied(at moment: Date, now: Date, boundary: DayBoundary, in calendar: Calendar) -> String {
        let today = boundary.day(at: now, in: calendar)
        let day = boundary.day(at: moment, in: calendar)
        guard day >= today else {
            return "Emptied " + (day == today.adding(days: -1) ? "yesterday" : "on " + dayName(day, today: today, in: calendar))
        }
        let hour = calendar.component(.hour, from: moment)
        return hour < 12 ? "Emptied this morning" : hour < 17 ? "Emptied this afternoon" : "Emptied this evening"
    }

    /// "today", "yesterday", a weekday in the last week, or a day and month.
    private static func dayName(_ day: LocalDate, today: LocalDate, in calendar: Calendar) -> String {
        if day >= today { return "today" }
        if day == today.adding(days: -1) { return "yesterday" }
        if day > today.adding(days: -7) { return Recurrence.english.weekdaySymbols[day.weekday - 1] }
        return "\(day.day) \(Recurrence.english.monthSymbols[day.month - 1])"
    }
}
