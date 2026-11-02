import Foundation

/// A repeat on a schedule: the part of an iCalendar RRULE (RFC 5545) that works in whole days.
///
/// Supported parts: `FREQ` (`DAILY`, `WEEKLY`, `MONTHLY`, `YEARLY`), `INTERVAL`, `BYDAY` (with
/// ordinals such as `2TU` or `-1FR`), `BYMONTHDAY` (negative counts from the month's end),
/// `BYMONTH`, `BYSETPOS`, `COUNT`, `UNTIL` and `WKST`. Anything else is refused rather than
/// ignored, so a rule is never quietly read as something else.
public struct Recurrence: Hashable, Sendable, Codable {
    public enum Frequency: String, Sendable, Codable, CaseIterable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    /// Numbered as in `Calendar`: 1 is Sunday and 7 is Saturday.
    public enum Weekday: Int, Sendable, Codable, CaseIterable {
        case sunday = 1
        case monday
        case tuesday
        case wednesday
        case thursday
        case friday
        case saturday

        public var code: String {
            ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][rawValue - 1]
        }

        public init?(code: String) {
            guard let match = Weekday.allCases.first(where: { $0.code == code }) else { return nil }
            self = match
        }

        public static let weekdays: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]
    }

    /// A day of the week, optionally numbered within the month or year: `2TU` is the second
    /// Tuesday and `-1FR` the last Friday.
    public struct WeekdayNumber: Hashable, Sendable, Codable {
        public var weekday: Weekday
        public var ordinal: Int?

        public init(_ weekday: Weekday, _ ordinal: Int? = nil) {
            self.weekday = weekday
            self.ordinal = ordinal
        }

        public var code: String {
            (ordinal.map(String.init) ?? "") + weekday.code
        }
    }

    public enum End: Hashable, Sendable, Codable {
        case never
        /// The last day an occurrence may fall on.
        case until(LocalDate)
        /// The number of occurrences in all.
        case count(Int)
    }

    public var frequency: Frequency
    public var interval: Int
    public var byDay: [WeekdayNumber]
    public var byMonthDay: [Int]
    public var byMonth: [Int]
    public var bySetPosition: [Int]
    public var weekStart: Weekday
    public var end: End

    public init(
        _ frequency: Frequency, interval: Int = 1, byDay: [WeekdayNumber] = [], byMonthDay: [Int] = [], byMonth: [Int] = [],
        bySetPosition: [Int] = [], weekStart: Weekday = .monday, end: End = .never
    ) {
        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay
        self.byMonthDay = byMonthDay
        self.byMonth = byMonth
        self.bySetPosition = bySetPosition
        self.weekStart = weekStart
        self.end = end
    }
}

// MARK: - RRULE text

public enum RecurrenceError: Error, Equatable, Sendable {
    case missingFrequency
    case unsupported(String)
    case invalidValue(part: String, value: String)
    case countAndUntil
}

extension Recurrence {
    /// Reads an RRULE such as `FREQ=MONTHLY;BYDAY=FR;BYSETPOS=-1`, with or without `RRULE:`.
    public init(rrule: String) throws(RecurrenceError) {
        var text = rrule.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("RRULE:") {
            text.removeFirst("RRULE:".count)
        }
        var frequency: Frequency?
        var interval = 1
        var byDay: [WeekdayNumber] = []
        var byMonthDay: [Int] = []
        var byMonth: [Int] = []
        var bySetPosition: [Int] = []
        var weekStart = Weekday.monday
        var count: Int?
        var until: LocalDate?

        for part in text.split(separator: ";") where !part.isEmpty {
            let pieces = part.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
            guard pieces.count == 2 else { throw .invalidValue(part: String(part), value: "") }
            let (name, value) = (pieces[0], pieces[1])
            func invalid() -> RecurrenceError { .invalidValue(part: name, value: value) }
            func integers(_ range: ClosedRange<Int>, allowNegative: Bool) throws(RecurrenceError) -> [Int] {
                var result: [Int] = []
                for item in value.split(separator: ",") {
                    guard let number = Int(item), range.contains(abs(number)), allowNegative || number > 0 else { throw invalid() }
                    result.append(number)
                }
                guard !result.isEmpty else { throw invalid() }
                return result
            }
            switch name {
            case "FREQ":
                guard let parsed = Frequency(rawValue: value) else {
                    throw ["SECONDLY", "MINUTELY", "HOURLY"].contains(value) ? .unsupported("FREQ=\(value)") : invalid()
                }
                frequency = parsed
            case "INTERVAL":
                guard let number = Int(value), number > 0 else { throw invalid() }
                interval = number
            case "BYDAY":
                byDay = []
                for item in value.split(separator: ",") {
                    let code = String(item.suffix(2))
                    let number = item.dropLast(2)
                    guard let weekday = Weekday(code: code) else { throw invalid() }
                    if number.isEmpty {
                        byDay.append(WeekdayNumber(weekday))
                    } else {
                        guard let ordinal = Int(number), (1...53).contains(abs(ordinal)) else { throw invalid() }
                        byDay.append(WeekdayNumber(weekday, ordinal))
                    }
                }
                guard !byDay.isEmpty else { throw invalid() }
            case "BYMONTHDAY":
                byMonthDay = try integers(1...31, allowNegative: true)
            case "BYMONTH":
                byMonth = try integers(1...12, allowNegative: false)
            case "BYSETPOS":
                bySetPosition = try integers(1...366, allowNegative: true)
            case "WKST":
                guard let weekday = Weekday(code: value) else { throw invalid() }
                weekStart = weekday
            case "COUNT":
                guard let number = Int(value), number > 0 else { throw invalid() }
                count = number
            case "UNTIL":
                guard let date = LocalDate(String(value.prefix(8))) else { throw invalid() }
                until = date
            default:
                throw .unsupported(name)
            }
        }
        guard let frequency else { throw .missingFrequency }
        if count != nil && until != nil { throw .countAndUntil }
        if frequency != .monthly && frequency != .yearly, byDay.contains(where: { $0.ordinal != nil }) {
            throw .invalidValue(part: "BYDAY", value: byDay.map(\.code).joined(separator: ","))
        }
        let withinMonth = frequency == .monthly || !byMonth.isEmpty
        if withinMonth, byDay.contains(where: { abs($0.ordinal ?? 0) > 5 }) {
            throw .invalidValue(part: "BYDAY", value: byDay.map(\.code).joined(separator: ","))
        }
        if frequency == .weekly, !byMonthDay.isEmpty {
            throw .invalidValue(part: "BYMONTHDAY", value: byMonthDay.map(String.init).joined(separator: ","))
        }
        let end: End = count.map { .count($0) } ?? until.map { .until($0) } ?? .never
        self.init(
            frequency, interval: interval, byDay: byDay, byMonthDay: byMonthDay, byMonth: byMonth, bySetPosition: bySetPosition,
            weekStart: weekStart, end: end)
    }

    /// The rule as an RRULE, in a fixed order of parts, without `RRULE:`.
    public var rrule: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if !byMonth.isEmpty { parts.append("BYMONTH=" + byMonth.map(String.init).joined(separator: ",")) }
        if !byMonthDay.isEmpty { parts.append("BYMONTHDAY=" + byMonthDay.map(String.init).joined(separator: ",")) }
        if !byDay.isEmpty { parts.append("BYDAY=" + byDay.map(\.code).joined(separator: ",")) }
        if !bySetPosition.isEmpty { parts.append("BYSETPOS=" + bySetPosition.map(String.init).joined(separator: ",")) }
        if weekStart != .monday { parts.append("WKST=\(weekStart.code)") }
        switch end {
        case .never: break
        case .count(let count): parts.append("COUNT=\(count)")
        case .until(let date): parts.append("UNTIL=" + String(format: "%04d%02d%02d", date.year, date.month, date.day))
        }
        return parts.joined(separator: ";")
    }
}
