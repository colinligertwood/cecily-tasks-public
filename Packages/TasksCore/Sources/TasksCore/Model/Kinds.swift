import Foundation

// The model's choices. Each is stored as its raw string, so a value added later reads as unknown
// on an older version rather than failing, and CloudKit stores plain text.

public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case action
    case note
}

public enum Bucket: String, Codable, Sendable, CaseIterable {
    case inbox
    case action
    case waiting
    case someday
    case reference
    case trash
}

extension Bucket {
    /// The list's name, as it's shown.
    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .action: "Actions"
        case .waiting: "Waiting"
        case .someday: "Someday"
        case .reference: "Reference"
        case .trash: "Trash"
        }
    }
}

public enum ItemStatus: String, Codable, Sendable, CaseIterable {
    case open
    case done
    case dropped
}

public enum TimeEstimate: String, Codable, Sendable, CaseIterable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case twoHoursOrMore = "2h+"
}

public enum Energy: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum ItemSource: String, Codable, Sendable, CaseIterable {
    case quickAdd
    case share
    case watch
    case siri
    case review
    case `import`
}

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case schedule
    case afterCompletion
}

// MARK: - Days

extension LocalDate {
    /// A date-only field's day. Date-only fields are stored as midnight UTC on their day, so the
    /// day is the same in every time zone.
    public init(day date: Date) {
        self.init(date, in: LocalDate.dayCalendar)
    }

    /// The date to store in a date-only field for this day.
    public var storedDate: Date {
        date(in: LocalDate.dayCalendar)
    }
}
