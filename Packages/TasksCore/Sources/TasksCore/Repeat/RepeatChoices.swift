import Foundation

/// A repeat as the repeat form shows it: how often, on which days of the calendar, and when it
/// ends. It's read from a `RepeatRule` and written back as one, always on a schedule.
///
/// Days the rule doesn't name come from `anchor`, the day the item is on: a weekly rule with no
/// weekdays falls on the anchor's weekday, a monthly one on its day of the month. A rule that
/// counts from when each one is done reads as the schedule with the same interval from `anchor`.
/// Monthly repeats are every month in the months chosen, with no interval: every so many months
/// is the months it falls in.
public struct RepeatChoices: Hashable, Sendable {
    /// Whether a month's days are chosen by number or by position ("the last Friday").
    public enum MonthlyBy: Hashable, Sendable, CaseIterable {
        case days
        case position
    }

    /// What a position counts: one weekday, or any day, any weekday or any weekend day.
    public enum PositionDay: Hashable, Sendable {
        case weekday(Recurrence.Weekday)
        case day
        case anyWeekday
        case weekendDay

        public static let all: [PositionDay] =
            RepeatChoices.weekOrder.map { .weekday($0) } + [.day, .anyWeekday, .weekendDay]

        var days: [Recurrence.Weekday] {
            switch self {
            case .weekday(let day): [day]
            case .day: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
            case .anyWeekday: Recurrence.Weekday.weekdays
            case .weekendDay: [.saturday, .sunday]
            }
        }

        public var name: String {
            switch self {
            case .weekday(let day): day.name
            case .day: "Day"
            case .anyWeekday: "Weekday"
            case .weekendDay: "Weekend Day"
            }
        }
    }

    public var frequency: Recurrence.Frequency = .weekly
    public var interval = 1
    public var weekdays: Set<Recurrence.Weekday> = []
    public var monthlyBy: MonthlyBy = .days
    /// Days of the month, with -1 for the last.
    public var monthDays: Set<Int> = []
    /// 1 to 5, or -1 for the last.
    public var position = 1
    public var positionDay: PositionDay = .weekday(.monday)
    /// The months it falls in; all of them for every month. A yearly repeat is monthly in one.
    public var months: Set<Int> = []
    /// The month of the day the item is on, for a yearly repeat that doesn't name one.
    private var anchorMonth = 1
    /// How many times it happens in all, this one included; nil for no end. An end on a day reads
    /// as the number of times up to it from `anchor`.
    public var times: Int?
    public var showDaysBefore = 0

    /// The positions offered, in order: 1 to 5, then -1 for the last.
    public static let positions = [1, 2, 3, 4, 5, -1]

    /// The days of the week, Monday first.
    public static let weekOrder: [Recurrence.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

    /// The choices for `rule`, or a weekly repeat on `anchor`'s weekday for none.
    public init(rule: RepeatRule?, anchor: LocalDate) {
        let anchorWeekday = Recurrence.Weekday(rawValue: anchor.weekday) ?? .monday
        weekdays = [anchorWeekday]
        monthDays = [anchor.day]
        positionDay = .weekday(anchorWeekday)
        position = min((anchor.day - 1) / 7 + 1, 5)
        months = Set(1...12)
        anchorMonth = anchor.month
        guard let rule else { return }
        showDaysBefore = rule.showDaysBefore
        var endDate = rule.endDate
        if let remaining = rule.remainingCount { times = remaining + 1 }
        switch rule.mode {
        case .afterCompletion(let value, let unit):
            interval = value
            frequency =
                switch unit {
                case .day: .daily
                case .week: .weekly
                case .month, .year: .monthly
                }
            if unit == .month { useMonths(every: value) }
            if unit == .year { useMonths(every: 12) }
        case .schedule(let recurrence):
            read(recurrence)
            if case .until(let day) = recurrence.end { endDate = endDate.map { min($0, day) } ?? day }
        }
        if let endDate, times == nil {
            var open = self
            open.times = nil
            times = 1 + open.rule.upcoming(after: anchor, count: 999).count { $0 <= endDate }
        }
    }

    /// Every `count` months as the months it falls in from the anchor's month, when `count`
    /// divides a year; otherwise once a year, in the anchor's month.
    private mutating func useMonths(every count: Int) {
        frequency = .monthly
        interval = 1
        let step = count < 12 && 12 % count == 0 ? count : 12
        months = Set(stride(from: 0, to: 12, by: step).map { (anchorMonth - 1 + $0) % 12 + 1 })
    }

    private mutating func read(_ recurrence: Recurrence) {
        frequency = recurrence.frequency
        interval = recurrence.interval
        if frequency == .yearly {
            frequency = .monthly
            interval = 1
            months = recurrence.byMonth.isEmpty ? [anchorMonth] : Set(recurrence.byMonth)
        } else if frequency == .monthly, interval > 1 {
            useMonths(every: interval)
        } else if !recurrence.byMonth.isEmpty {
            months = Set(recurrence.byMonth)
        }
        if case .count(let count) = recurrence.end { times = count }
        let plainDays = recurrence.byDay.filter { $0.ordinal == nil }.map(\.weekday)
        if frequency == .weekly, !plainDays.isEmpty { weekdays = Set(plainDays) }
        if frequency == .daily, !plainDays.isEmpty, interval == 1 {
            frequency = .weekly
            weekdays = Set(plainDays)
        }
        guard frequency == .monthly else { return }
        if !recurrence.byMonthDay.isEmpty {
            monthlyBy = .days
            monthDays = Set(recurrence.byMonthDay)
        } else if recurrence.byDay.count == 1, let day = recurrence.byDay.first, let ordinal = day.ordinal {
            monthlyBy = .position
            position = ordinal
            positionDay = .weekday(day.weekday)
        } else if !plainDays.isEmpty, let ordinal = recurrence.bySetPosition.first {
            monthlyBy = .position
            position = ordinal
            positionDay = PositionDay.all.first { Set($0.days) == Set(plainDays) } ?? .weekday(plainDays[0])
        }
    }

    /// The rule the choices make.
    public var rule: RepeatRule {
        RepeatRule(.schedule(recurrence), showDaysBefore: showDaysBefore, remainingCount: times.map { max($0, 1) - 1 })
    }

    /// The day the last time falls on, `count` times in all from one on `start`; nil when the rule
    /// stops before then.
    public func lastDate(times count: Int, from start: LocalDate) -> LocalDate? {
        var open = self
        open.times = nil
        guard count > 1 else { return start }
        let dates = open.rule.upcoming(after: start, count: count - 1)
        return dates.count == count - 1 ? dates.last : nil
    }

    private var recurrence: Recurrence {
        var recurrence = Recurrence(frequency, interval: frequency == .monthly ? 1 : max(interval, 1))
        switch frequency {
        case .daily:
            break
        case .weekly:
            recurrence.byDay = weekdays.sorted { $0.mondayFirst < $1.mondayFirst }.map { Recurrence.WeekdayNumber($0) }
        case .monthly, .yearly:
            if !months.isEmpty, months.count < 12 { recurrence.byMonth = months.sorted() }
            switch monthlyBy {
            case .days:
                recurrence.byMonthDay = monthDays.sorted { ($0 < 0 ? 100 - $0 : $0) < ($1 < 0 ? 100 - $1 : $1) }
            case .position:
                if case .weekday(let day) = positionDay {
                    recurrence.byDay = [Recurrence.WeekdayNumber(day, position)]
                } else {
                    recurrence.byDay = positionDay.days.map { Recurrence.WeekdayNumber($0) }
                    recurrence.bySetPosition = [position]
                }
            }
        }
        return recurrence
    }
}

extension Recurrence.Weekday {
    /// Its place in a week that starts on Monday.
    public var mondayFirst: Int { (rawValue + 5) % 7 }
}

extension RepeatRule {
    /// How it repeats, in words, with when it ends: "Every 2 weeks on Monday", "Monthly on the last
    /// Friday, 10 times", "3 days after done".
    public var summary: String {
        switch mode {
        case .afterCompletion(let value, let unit):
            return "\(value) \(unit.rawValue)\(value == 1 ? "" : "s") after done" + endSummary
        case .schedule(var recurrence):
            if recurrence.end == .never {
                if let endDate {
                    recurrence.end = .until(endDate)
                } else if let remainingCount {
                    recurrence.end = .count(remainingCount + 1)
                }
            }
            return recurrence.summary
        }
    }

    private var endSummary: String {
        if let endDate { return ", until \(endDate.day) \(Recurrence.english.shortMonthSymbols[endDate.month - 1]) \(endDate.year)" }
        if let remainingCount { return remainingCount == 0 ? ", once" : ", \(remainingCount + 1) times" }
        return ""
    }

    /// The dates of the next `count` copies after one dated `date`, each taken as done on its day.
    public func upcoming(after date: LocalDate, count: Int = 5) -> [LocalDate] {
        var dates: [LocalDate] = []
        var rule = self
        var current = date
        while dates.count < count, let next = rule.nextDate(after: current, closedOn: current, seriesStart: current) {
            dates.append(next)
            rule = rule.advanced()
            current = next
        }
        return dates
    }

    /// The first date the rule falls on, on or after `day`: on a schedule, the first day it
    /// matches; after completion, `day` itself.
    public func firstDate(onOrAfter day: LocalDate) -> LocalDate? {
        switch mode {
        case .schedule(let recurrence): recurrence.occurrences(from: day, limit: 1).first
        case .afterCompletion: day
        }
    }

    /// The same rule with the days it took from the copy's date written into it, so the copies
    /// after one dated `day` keep falling where they would when that copy moves.
    public func pinned(to day: LocalDate) -> RepeatRule {
        guard case .schedule(var recurrence) = mode else { return self }
        let weekday = Recurrence.Weekday(rawValue: day.weekday) ?? .monday
        switch recurrence.frequency {
        case .daily:
            break
        case .weekly:
            if recurrence.byDay.isEmpty { recurrence.byDay = [Recurrence.WeekdayNumber(weekday)] }
        case .monthly:
            if recurrence.byDay.isEmpty, recurrence.byMonthDay.isEmpty { recurrence.byMonthDay = [day.day] }
        case .yearly:
            if recurrence.byDay.isEmpty, recurrence.byMonthDay.isEmpty {
                if recurrence.byMonth.isEmpty { recurrence.byMonth = [day.month] }
                recurrence.byMonthDay = [day.day]
            }
        }
        var rule = self
        rule.mode = .schedule(recurrence)
        return rule
    }

    /// Whether changing to `other` changes which days it falls on.
    public func fallsDifferently(from other: RepeatRule) -> Bool {
        mode != other.mode
    }
}

extension RepeatRule {
    /// How often, short enough for a tag, with its one main detail: "Daily", "Weekdays",
    /// "Mon, Thu", "Every 2 weeks, Mon", "Monthly, 21st", "Monthly, last Fri", "Yearly, 15 Mar".
    /// It ends with "…" when it leaves something out (other months left out, more days, an end);
    /// `summary` has it all.
    public var label: String {
        let hasEnd = endDate != nil || remainingCount != nil
        switch mode {
        case .afterCompletion(let value, let unit):
            return (value == 1 ? Self.often(unit) : "Every \(value) \(unit.rawValue)s") + (hasEnd ? "…" : "")
        case .schedule(let recurrence):
            let (text, isPartial) = recurrence.label
            return text + (isPartial || hasEnd || recurrence.end != .never ? "…" : "")
        }
    }

    private static func often(_ unit: Unit) -> String {
        switch unit {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        case .year: "Yearly"
        }
    }
}

extension Recurrence {
    /// The label's words, and whether they leave out a detail other than the end.
    fileprivate var label: (String, Bool) {
        let days = Set(byDay.filter { $0.ordinal == nil }.map(\.weekday))
        if interval == 1, frequency == .daily || frequency == .weekly, days == Set(Weekday.weekdays) { return ("Weekdays", false) }
        switch frequency {
        case .daily where days.isEmpty:
            return (interval == 1 ? "Daily" : "Every \(interval) days", false)
        case .daily, .weekly:
            let start = interval == 1 ? "Weekly" : "Every \(interval) weeks"
            guard (1...3).contains(days.count) else { return (start, days.count > 3) }
            let names = RepeatChoices.weekOrder.filter(days.contains).map { Self.english.shortWeekdaySymbols[$0.rawValue - 1] }.joined(
                separator: ", ")
            return (interval == 1 ? names : "\(start), \(names)", false)
        case .monthly, .yearly:
            let months = Set(byMonth)
            let isYearly = frequency == .yearly ? months.count <= 1 : interval == 1 && months.count == 1
            let start =
                if isYearly { interval == 1 || frequency == .monthly ? "Yearly" : "Every \(interval) years" } else {
                    interval == 1 ? "Monthly" : "Every \(interval) months"
                }
            let leavesOutMonths = !isYearly && !months.isEmpty && months.count < 12
            guard let (day, isPartial) = dayLabel else { return (start, leavesOutMonths) }
            let month = isYearly ? months.first.map { Self.english.shortMonthSymbols[$0 - 1] } : nil
            let detail =
                if let month { byMonthDay.count == 1 && byMonthDay[0] > 0 ? "\(byMonthDay[0]) \(month)" : "\(day) in \(month)" } else { day }
            return ("\(start), \(detail)", isPartial || leavesOutMonths)
        }
    }

    /// The days of the month in short, and whether that leaves some out: "21st", "1st, 15th",
    /// "last day", "last Fri", "1st weekday". Nil when the rule names none.
    private var dayLabel: (String, Bool)? {
        if !byMonthDay.isEmpty {
            let sorted = byMonthDay.sorted { ($0 < 0 ? 100 - $0 : $0) < ($1 < 0 ? 100 - $1 : $1) }
            let names = sorted.prefix(2).map { $0 > 0 ? Self.numbered($0) : $0 == -1 ? "last day" : "\(Self.numbered(-$0)) last day" }
            return (names.joined(separator: ", "), sorted.count > 2)
        }
        if byDay.count == 1, let day = byDay.first, let ordinal = day.ordinal ?? bySetPosition.first {
            return ("\(Self.position(ordinal)) \(Self.english.shortWeekdaySymbols[day.weekday.rawValue - 1])", false)
        }
        if let position = bySetPosition.first {
            let days = Set(byDay.map(\.weekday))
            let name =
                switch days {
                case Set(Weekday.allCases): "day"
                case Set(Weekday.weekdays): "weekday"
                case [.saturday, .sunday]: "weekend day"
                default: ""
                }
            return name.isEmpty ? nil : ("\(Self.position(position)) \(name)", false)
        }
        return nil
    }

    /// "1st", "2nd", "last", "2nd last".
    private static func position(_ number: Int) -> String {
        number > 0 ? numbered(number) : number == -1 ? "last" : "\(numbered(-number)) last"
    }
}
