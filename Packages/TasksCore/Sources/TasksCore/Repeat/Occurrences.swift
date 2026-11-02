import Foundation

extension Recurrence {
    /// The days the rule falls on, in order, from `start` onwards.
    ///
    /// `start` sets the rule's anchor (which week, month or year counts as the first for
    /// `INTERVAL`, and the default day, weekday and month), but is an occurrence only when the
    /// rule matches it. `COUNT` counts the occurrences returned.
    public func occurrences(from start: LocalDate) -> Occurrences {
        Occurrences(rule: self, start: start)
    }

    public func occurrences(from start: LocalDate, limit: Int) -> [LocalDate] {
        Array(occurrences(from: start).prefix(limit))
    }

    /// The first occurrence after `date`, in a series that began on `seriesStart`.
    public func nextOccurrence(after date: LocalDate, seriesStart: LocalDate) -> LocalDate? {
        occurrences(from: seriesStart).first { $0 > date }
    }
}

public struct Occurrences: Sequence, IteratorProtocol {
    /// How many periods in a row may hold no occurrence before the rule is taken to have none left,
    /// as with 30 February.
    static let emptyPeriodLimit = 2000

    let rule: Recurrence
    let start: LocalDate
    private var period = 0
    private var pending: [LocalDate] = []
    private var produced = 0
    private var emptyPeriods = 0
    private var finished = false

    init(rule: Recurrence, start: LocalDate) {
        self.rule = rule
        self.start = start
    }

    public mutating func next() -> LocalDate? {
        while !finished {
            if !pending.isEmpty {
                let day = pending.removeFirst()
                switch rule.end {
                case .never: break
                case .until(let last) where day > last:
                    finished = true
                    return nil
                case .count(let count) where produced >= count:
                    finished = true
                    return nil
                case .until, .count: break
                }
                produced += 1
                return day
            }
            let (first, days) = rule.days(inPeriod: period, start: start)
            period += 1
            pending = days.filter { $0 >= start }
            if case .until(let last) = rule.end, first > last {
                finished = true
            }
            emptyPeriods = pending.isEmpty ? emptyPeriods + 1 : 0
            if emptyPeriods >= Occurrences.emptyPeriodLimit {
                finished = true
            }
        }
        return nil
    }
}

extension Recurrence {
    /// The first day of the `index`th period counted from `start`'s, and the days in it the rule
    /// falls on, in order.
    func days(inPeriod index: Int, start: LocalDate) -> (first: LocalDate, days: [LocalDate]) {
        let step = index * interval
        let first: LocalDate
        var days: [LocalDate]
        switch frequency {
        case .daily:
            first = start.adding(days: step)
            days = matchesDaily(first) ? [first] : []
        case .weekly:
            let back = (start.weekday - weekStart.rawValue + 7) % 7
            first = start.adding(days: step * 7 - back)
            let weekdays = byDay.isEmpty ? [start.weekday] : byDay.map(\.weekday.rawValue)
            days = (0..<7).map { first.adding(days: $0) }.filter { weekdays.contains($0.weekday) && inMonths($0) }
        case .monthly:
            first = LocalDate(start.year, start.month, 1).adding(months: step)
            days = byMonth.isEmpty || byMonth.contains(first.month) ? monthDays(first.month, year: first.year, start: start) : []
        case .yearly:
            let year = start.year + step
            first = LocalDate(year, 1, 1)
            if !byMonth.isEmpty {
                days = byMonth.sorted().flatMap { monthDays($0, year: year, start: start) }
            } else if !byMonthDay.isEmpty {
                days = (1...12).flatMap { monthDays($0, year: year, start: start) }
            } else if !byDay.isEmpty {
                let count = LocalDate.isLeap(year) ? 366 : 365
                days = expand(byDay, over: (0..<count).map { first.adding(days: $0) })
            } else {
                days = start.day <= LocalDate.daysIn(month: start.month, year: year) ? [LocalDate(year, start.month, start.day)] : []
            }
        }
        days = Array(Set(days)).sorted()
        if !bySetPosition.isEmpty {
            days = Array(Set(bySetPosition.compactMap { position in days.at(position) })).sorted()
        }
        return (first, days)
    }

    private func monthDays(_ month: Int, year: Int, start: LocalDate) -> [LocalDate] {
        let length = LocalDate.daysIn(month: month, year: year)
        let all = (1...length).map { LocalDate(year, month, $0) }
        if !byMonthDay.isEmpty {
            let chosen = Set(byMonthDay.compactMap { $0 > 0 ? ($0 <= length ? $0 : nil) : (length + 1 + $0 >= 1 ? length + 1 + $0 : nil) })
            let days = all.filter { chosen.contains($0.day) }
            return byDay.isEmpty ? days : Set(expand(byDay, over: all)).intersection(days).sorted()
        }
        if !byDay.isEmpty {
            return expand(byDay, over: all)
        }
        return start.day <= length ? [LocalDate(year, month, start.day)] : []
    }

    /// The days in `span` that `weekdays` picks: every such weekday, or the numbered one counted
    /// from the span's start or (when negative) its end.
    private func expand(_ weekdays: [WeekdayNumber], over span: [LocalDate]) -> [LocalDate] {
        weekdays.flatMap { item -> [LocalDate] in
            let matches = span.filter { $0.weekday == item.weekday.rawValue }
            guard let ordinal = item.ordinal else { return matches }
            return matches.at(ordinal).map { [$0] } ?? []
        }
    }

    private func matchesDaily(_ day: LocalDate) -> Bool {
        guard inMonths(day) else { return false }
        if !byMonthDay.isEmpty {
            let length = LocalDate.daysIn(month: day.month, year: day.year)
            guard byMonthDay.contains(where: { ($0 > 0 ? $0 : length + 1 + $0) == day.day }) else { return false }
        }
        return byDay.isEmpty || byDay.contains { $0.weekday.rawValue == day.weekday }
    }

    private func inMonths(_ day: LocalDate) -> Bool {
        byMonth.isEmpty || byMonth.contains(day.month)
    }
}

extension Array {
    /// The element at a 1-based position, or counted from the end when negative.
    fileprivate func at(_ position: Int) -> Element? {
        let index = position > 0 ? position - 1 : count + position
        return indices.contains(index) ? self[index] : nil
    }
}
