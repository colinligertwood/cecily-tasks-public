import Foundation

extension Recurrence {
    /// How it repeats, in words: "Every Thursday", "Every 2 weeks on Monday and Thursday",
    /// "Monthly on the first Tuesday", "Every year on 14 March", with "until 12 Dec 2026" or
    /// "10 times" when it ends.
    public var summary: String {
        var text = schedule
        switch end {
        case .never: break
        case .until(let day): text += ", until \(day.day) \(Self.english.shortMonthSymbols[day.month - 1]) \(day.year)"
        case .count(let count): text += count == 1 ? ", once" : ", \(count) times"
        }
        return text
    }

    private var schedule: String {
        let days = byDay.filter { $0.ordinal == nil }.map(\.weekday)
        let isWeekdays = Set(days) == Set(Weekday.weekdays) && days.count == Weekday.weekdays.count
        switch frequency {
        case .daily:
            if isWeekdays, interval == 1 { return "Every weekday" }
            return every("day", "days")
        case .weekly:
            if isWeekdays, interval == 1 { return "Every weekday" }
            let named = Self.list(Self.sorted(days, from: weekStart).map(\.name))
            if interval == 1 { return days.isEmpty ? "Every week" : "Every " + named }
            return every("week", "weeks") + (days.isEmpty ? "" : " on " + named)
        case .monthly:
            if interval == 1, byMonth.count == 1, let month = byMonth.first { return on("Every year", inMonth: month) }
            let start = interval == 1 ? "Monthly" : every("month", "months")
            let chosen = Set(byMonth)
            guard !chosen.isEmpty, chosen.count < 12 else { return on(start, inMonth: nil) }
            if chosen.count > 6 {
                let left = (1...12).filter { !chosen.contains($0) }.map { Self.english.monthSymbols[$0 - 1] }
                return on(start, inMonth: nil) + ", except " + Self.list(left)
            }
            return on(start, inMonth: nil) + " in " + Self.list(chosen.sorted().map { Self.english.monthSymbols[$0 - 1] })
        case .yearly:
            let start = every("year", "years")
            guard byMonth.count == 1, let month = byMonth.first else { return start }
            return on(start, inMonth: month)
        }
    }

    /// `start` with the day of the month, or of `month`, when the rule gives one.
    private func on(_ start: String, inMonth month: Int?) -> String {
        let monthName = month.map { Self.english.monthSymbols[$0 - 1] }
        if byDay.count == 1, let day = byDay.first, let ordinal = day.ordinal ?? bySetPosition.first {
            return "\(start) on the \(Self.ordinal(ordinal)) \(day.weekday.name)" + (monthName.map { " of " + $0 } ?? "")
        }
        if byMonthDay.count == 1, let day = byMonthDay.first {
            if let monthName, day > 0 { return "\(start) on \(day) \(monthName)" }
            let text = day > 0 ? Self.numbered(day) : day == -1 ? "last day" : "\(Self.ordinal(day)) day"
            return "\(start) on the \(text)" + (monthName.map { " of " + $0 } ?? "")
        }
        if byMonthDay.count > 1 {
            let days = byMonthDay.sorted { ($0 < 0 ? 100 - $0 : $0) < ($1 < 0 ? 100 - $1 : $1) }
                .map { $0 > 0 ? Self.numbered($0) : $0 == -1 ? "last day" : "\(Self.ordinal($0)) day" }
            return "\(start) on the \(Self.list(days))" + (monthName.map { " of " + $0 } ?? "")
        }
        if bySetPosition.count == 1, let position = bySetPosition.first, byDay.allSatisfy({ $0.ordinal == nil }) {
            let days = Set(byDay.map(\.weekday))
            let name =
                switch days {
                case Set(Weekday.allCases): "day"
                case Set(Weekday.weekdays): "weekday"
                case [.saturday, .sunday]: "weekend day"
                default: ""
                }
            if !name.isEmpty { return "\(start) on the \(Self.ordinal(position)) \(name)" + (monthName.map { " of " + $0 } ?? "") }
        }
        return start + (monthName.map { " in " + $0 } ?? "")
    }

    /// The calendar whose names the summary uses, since its words are English.
    static let english: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private func every(_ one: String, _ many: String) -> String {
        interval == 1 ? "Every \(one)" : "Every \(interval) \(many)"
    }

    private static func sorted(_ days: [Weekday], from start: Weekday) -> [Weekday] {
        days.sorted { ($0.rawValue - start.rawValue + 7) % 7 < ($1.rawValue - start.rawValue + 7) % 7 }
    }

    /// "Monday", "Monday and Thursday", "Monday, Wednesday and Friday".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// "first", "second", ..., "last", "second to last".
    private static func ordinal(_ number: Int) -> String {
        let words = ["first", "second", "third", "fourth", "fifth"]
        if number > 0 { return number <= words.count ? words[number - 1] : numbered(number) }
        if number == -1 { return "last" }
        return (-number <= words.count ? words[-number - 1] : numbered(-number)) + " to last"
    }

    /// "1st", "2nd", "3rd", "11th", "22nd".
    static func numbered(_ number: Int) -> String {
        let suffix =
            switch (number % 10, number % 100) {
            case (_, 11...13): "th"
            case (1, _): "st"
            case (2, _): "nd"
            case (3, _): "rd"
            default: "th"
            }
        return "\(number)\(suffix)"
    }
}

extension Recurrence.Weekday {
    /// "Monday".
    public var name: String {
        Recurrence.english.weekdaySymbols[rawValue - 1]
    }
}
