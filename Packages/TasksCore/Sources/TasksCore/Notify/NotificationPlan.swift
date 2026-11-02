import Foundation

/// A notification the app wants pending: when, what it says, and the item it opens, if any.
public struct PlannedNotification: Hashable, Sendable {
    public enum Trigger: String, Sendable {
        /// At an item's start time.
        case starts
        /// On its due day.
        case due
        /// On a waiting item's follow-up day.
        case followUp
        /// On the weekly review's day.
        case weeklyReview
    }

    /// The item's ID, the trigger and the day, so a changed item replaces its notification.
    public let id: String
    /// Nil for the weekly review's.
    public let itemID: UUID?
    public let trigger: Trigger
    public let date: Date
    public let title: String
    public let body: String
}

/// Which notifications are on, and the time of day for due dates and follow-ups.
public struct NotificationSettings: Hashable, Sendable {
    public var starts: Bool
    public var due: Bool
    public var followUps: Bool
    /// Minutes after midnight.
    public var timeOfDay: Int

    public init(starts: Bool = true, due: Bool = true, followUps: Bool = true, timeOfDay: Int = 9 * 60) {
        self.starts = starts
        self.due = due
        self.followUps = followUps
        self.timeOfDay = timeOfDay
    }

    public init(_ settings: AppSettings) {
        self.init(
            starts: settings.notifyScheduled, due: settings.notifyDue, followUps: settings.notifyFollowUps,
            timeOfDay: settings.dueNotificationTime)
    }
}

public enum NotificationPlan {
    /// The most notifications kept pending, under iOS's limit of 64.
    public static let limit = 60

    /// The notifications wanted after `now`, soonest first, at most `limit`:
    /// at an item's start time when it has one, and at the settings' time of day on its due day
    /// and, for a waiting item, its follow-up day. Days become moments in `calendar`'s time zone.
    /// Only open items not in the trash or in a project that's gone have them; hidden items do.
    public static func notifications(_ items: [Item], settings: NotificationSettings, now: Date, in calendar: Calendar) -> [PlannedNotification] {
        let hour = settings.timeOfDay / 60
        let minute = settings.timeOfDay % 60
        var planned: [PlannedNotification] = []
        for item in items where item.status == .open && item.bucket != .trash && !item.isInGoneProject() {
            let title = item.title.isEmpty ? "Untitled" : item.title
            func add(_ trigger: PlannedNotification.Trigger, _ day: LocalDate, _ date: Date, _ body: String) {
                guard date > now else { return }
                planned.append(
                    PlannedNotification(
                        id: "\(item.id.uuidString)-\(trigger.rawValue)-\(day)", itemID: item.id, trigger: trigger, date: date, title: title,
                        body: body))
            }
            if settings.starts, let day = item.day(.scheduled), let time = item.scheduledTime {
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                add(.starts, day, day.date(in: calendar, hour: parts.hour ?? 0, minute: parts.minute ?? 0), "Scheduled for now")
            }
            if settings.due, let day = item.day(.due) {
                add(.due, day, day.date(in: calendar, hour: hour, minute: minute), "Due today")
            }
            if settings.followUps, item.bucket == .waiting, let day = item.day(.followUp) {
                let person = (item.waitingOn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                add(.followUp, day, day.date(in: calendar, hour: hour, minute: minute), person.isEmpty ? "Follow up" : "Follow up with \(person)")
            }
        }
        return Array(planned.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(limit))
    }

    /// The weekly review's reminders after `now` (`WeeklyReview.reminders`), which open the app in
    /// review mode.
    public static func reviewReminders(
        _ records: [ReviewRecord], reminder: ReviewReminder, now: Date, boundary: DayBoundary, in calendar: Calendar
    ) -> [PlannedNotification] {
        WeeklyReview.reminders(records, reminder: reminder, now: now, boundary: boundary, in: calendar).map { date in
            PlannedNotification(
                id: "weeklyReview-\(LocalDate(date, in: calendar))", itemID: nil, trigger: .weeklyReview, date: date, title: "Weekly Review",
                body: "Time to go through your lists")
        }
    }
}
