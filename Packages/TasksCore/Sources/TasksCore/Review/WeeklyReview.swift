import Foundation
import SwiftData

/// A list gone through in the weekly review, in the sidebar's order. Its raw value is what a
/// `ReviewRecord`'s `stepsDone` keeps.
public enum ReviewList: String, CaseIterable, Sendable {
    case agenda
    case inbox
    case actions
    case waiting
    case someday
}

/// When the weekly review's reminder comes, from `AppSettings`.
public struct ReviewReminder: Hashable, Sendable {
    public var isOn: Bool
    /// 1 is Sunday and 7 Saturday, as in `Calendar`.
    public var weekday: Int
    /// Minutes after midnight.
    public var time: Int

    public init(isOn: Bool = true, weekday: Int = 6, time: Int = 15 * 60) {
        self.isOn = isOn
        self.weekday = weekday
        self.time = time
    }

    public init(_ settings: AppSettings) {
        self.init(isOn: settings.weeklyReviewReminder, weekday: settings.weeklyReviewWeekday, time: settings.weeklyReviewTime)
    }
}

/// The weekly review: the app in review mode while a review is open, with each
/// list ticked once it's been gone through. A review is open until it's finished, by ticking its
/// last list or with Finish Review. Reviews started on two devices before either saw the other's
/// are one review: their ticks count together, and finishing joins them.
public enum WeeklyReview {
    /// Days without a finished review before the review counts as missed.
    public static let missedAfterDays = 14
    /// The reminders planned ahead, a week apart.
    public static let remindersAhead = 4

    /// The open reviews, the one started first first.
    public static func open(_ records: [ReviewRecord]) -> [ReviewRecord] {
        records.filter { $0.completedAt == nil }.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    /// The review in progress, or nil when the app isn't in review mode.
    public static func current(_ records: [ReviewRecord]) -> ReviewRecord? {
        open(records).first
    }

    /// The lists ticked in the open reviews.
    public static func ticked(_ records: [ReviewRecord]) -> Set<ReviewList> {
        Set(open(records).flatMap(\.stepsDone).compactMap(ReviewList.init(rawValue:)))
    }

    /// The first list not ticked, in the sidebar's order.
    public static func next(_ records: [ReviewRecord]) -> ReviewList? {
        let ticked = ticked(records)
        return ReviewList.allCases.first { !ticked.contains($0) }
    }

    /// The review in progress, or a new one started `now`.
    @discardableResult
    public static func start(in context: ModelContext, at now: Date = .now) -> ReviewRecord {
        if let current = current(records(in: context)) { return current }
        let record = ReviewRecord()
        record.createdAt = now
        record.modifiedAt = now
        record.startedAt = now
        context.insert(record)
        return record
    }

    /// Ticks `list` in the review in progress, starting one if none is open, and finishes the
    /// review when it was the last.
    public static func tick(_ list: ReviewList, in context: ModelContext, at now: Date = .now) {
        let record = start(in: context, at: now)
        if !record.stepsDone.contains(list.rawValue) {
            record.stepsDone.append(list.rawValue)
            record.modifiedAt = now
        }
        if ticked(records(in: context)).count == ReviewList.allCases.count { finish(in: context, at: now) }
    }

    /// Finishes the review in progress: the one started first takes every open review's ticks and
    /// is marked finished, and the others are deleted.
    public static func finish(in context: ModelContext, at now: Date = .now) {
        let open = open(records(in: context))
        guard let first = open.first else { return }
        for other in open.dropFirst() {
            for step in other.stepsDone where !first.stepsDone.contains(step) { first.stepsDone.append(step) }
            context.delete(other)
        }
        first.completedAt = now
        first.modifiedAt = now
    }

    /// When the last review was finished.
    public static func lastFinished(_ records: [ReviewRecord]) -> Date? {
        records.compactMap(\.completedAt).max()
    }

    /// Whether no review has been finished in `missedAfterDays` days, counting from `firstLaunch`
    /// when none ever has, and none is open.
    public static func isMissed(_ records: [ReviewRecord], firstLaunch: Date, now: Date, boundary: DayBoundary, in calendar: Calendar) -> Bool {
        guard current(records) == nil else { return false }
        let since = boundary.day(at: lastFinished(records) ?? firstLaunch, in: calendar)
        return boundary.day(at: now, in: calendar) >= since.adding(days: missedAfterDays)
    }

    /// The reminders wanted after `now`, soonest first: on each review day at the review time, for
    /// `remindersAhead` weeks. None while a review is open, and none on a review day when a review
    /// was finished that day or the day before. Days of finished reviews start at `boundary`.
    public static func reminders(
        _ records: [ReviewRecord], reminder: ReviewReminder, now: Date, boundary: DayBoundary, in calendar: Calendar
    ) -> [Date] {
        guard reminder.isOn, current(records) == nil else { return [] }
        let finishedDays = Set(records.compactMap(\.completedAt).map { boundary.day(at: $0, in: calendar) })
        let today = LocalDate(now, in: calendar)
        let first = today.adding(days: (reminder.weekday - today.weekday + 7) % 7)
        let dates = (0...remindersAhead).compactMap { week -> Date? in
            let day = first.adding(days: 7 * week)
            let date = day.date(in: calendar, hour: reminder.time / 60, minute: reminder.time % 60)
            guard date > now, !finishedDays.contains(day), !finishedDays.contains(day.adding(days: -1)) else { return nil }
            return date
        }
        return Array(dates.prefix(remindersAhead))
    }

    private static func records(in context: ModelContext) -> [ReviewRecord] {
        (try? context.fetch(FetchDescriptor<ReviewRecord>())) ?? []
    }
}
