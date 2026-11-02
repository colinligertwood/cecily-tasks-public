import Foundation

/// A stop on Agenda's timeline: today, a day, a week, a month or everything later.
public struct TimelineStop: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Today, and every day before it.
        case today
        /// One of the six days after today.
        case day
        /// This week from today, as one stop, after Today and the week's days.
        case thisWeek
        case nextWeek
        /// A month, the first of them from today when it's this month.
        case month
        /// Everything from `first` on.
        case later
    }

    public let kind: Kind
    public let first: LocalDate
    /// The stop's last day; nil for Later.
    public let last: LocalDate?

    public var id: String { "\(kind)-\(first)" }

    /// Whether `day` is in the stop. Today has the days before it too.
    public func contains(_ day: LocalDate) -> Bool {
        switch kind {
        case .today: day <= first
        case .later: day >= first
        default: day >= first && day <= (last ?? first)
        }
    }
}

/// The items of one stop: what starts there, what's due, and what to follow up.
public struct TimelineParts {
    public let starts: [Item]
    public let due: [Item]
    public let followUp: [Item]

    public var isEmpty: Bool { starts.isEmpty && due.isEmpty && followUp.isEmpty }
}

/// Where an item is on the timeline: on its earliest date, in the part for that date. Dates
/// before today are on today.
public struct TimelinePlacement {
    public enum Part: Int, Comparable, Sendable {
        case starts, due, followUp

        public static func < (a: Part, b: Part) -> Bool { a.rawValue < b.rawValue }
    }

    public let item: Item
    /// The day the item is on: its date, or today for an earlier one.
    public let day: LocalDate
    /// The date itself.
    public let date: LocalDate
    public let part: Part
}

public enum Timeline {
    /// The most months the timeline names before Later.
    public static let mostMonths = 12

    /// The ways the stops can be laid out on `today`, from fewest to most, each taking in more
    /// stops than the one before: Today, This Week (today to the week's end), Next Week and Later;
    /// then the six days after today one by one after Today; then a month at a time before Later,
    /// the first the whole of the month after next week ends in. So the days come first, then the
    /// weeks, the months and Later. Weeks start on `weekStart` (1 is Sunday). On the week's last
    /// day there's no This Week.
    public static func layouts(today: LocalDate, weekStart: Int) -> [[TimelineStop]] {
        let daysToWeekStart = (weekStart - today.weekday + 7) % 7
        let toNextWeek = daysToWeekStart == 0 ? 7 : daysToWeekStart
        let nextWeek = TimelineStop(kind: .nextWeek, first: today.adding(days: toNextWeek), last: today.adding(days: toNextWeek + 6))
        let days = (1...6).map { TimelineStop(kind: .day, first: today.adding(days: $0), last: today.adding(days: $0)) }
        let thisWeek = toNextWeek == 1 ? [] : [TimelineStop(kind: .thisWeek, first: today, last: today.adding(days: toNextWeek - 1))]

        var months: [TimelineStop] = []
        let afterNextWeek = today.adding(days: toNextWeek + 7)
        var first = max(LocalDate(afterNextWeek.year, afterNextWeek.month, 1), today)
        for _ in 0..<mostMonths {
            let last = LocalDate(first.year, first.month, LocalDate.daysIn(month: first.month, year: first.year))
            months.append(TimelineStop(kind: .month, first: first, last: last))
            first = last.adding(days: 1)
        }

        func layout(_ week: [TimelineStop], months count: Int) -> [TimelineStop] {
            let shown = Array(months.prefix(count))
            let later = TimelineStop(kind: .later, first: shown.last?.last?.adding(days: 1) ?? today.adding(days: toNextWeek + 7), last: nil)
            return [TimelineStop(kind: .today, first: today, last: today)] + week + thisWeek + [nextWeek] + shown + [later]
        }
        return [layout([], months: 0), layout(days, months: 0)] + (1...mostMonths).map { layout(days, months: $0) }
    }

    /// The first stop `day` is in other than This Week, unless only This Week has it: so Today or a
    /// day before Next Week, and Next Week before the first month, which have them too. Days before
    /// the first stop are in it.
    public static func stop(for day: LocalDate, in stops: [TimelineStop]) -> TimelineStop? {
        stops.first { $0.kind != .thisWeek && $0.contains(day) } ?? stops.first { $0.contains(day) } ?? stops.first
    }

    /// Where each item is on `today`: open or done since `doneSince`, not hidden unless
    /// `showsHidden`, and not in the trash, on its earliest date. An item's dates are its start
    /// date when it's an action, its due date, and its follow-up date when it's waiting; on the
    /// same day, the first of those is its part. An item due today or earlier is in today's Due,
    /// whatever its other dates. Items without them aren't on the timeline.
    public static func placements(_ items: [Item], today: LocalDate, doneSince: Date?, showsHidden: Bool = false) -> [TimelinePlacement] {
        items.compactMap { item in
            guard item.bucket != .trash, item.isListed(today: today, doneSince: doneSince, showsHidden: showsHidden) else { return nil }
            var dates: [(LocalDate, TimelinePlacement.Part)] = []
            if item.bucket == .action, item.kind == .action, let day = item.day(.scheduled) { dates.append((day, .starts)) }
            if let day = item.day(.due) { dates.append((day, .due)) }
            if item.bucket == .waiting, let day = item.day(.followUp) { dates.append((day, .followUp)) }
            if let due = item.day(.due), due <= today { return TimelinePlacement(item: item, day: today, date: due, part: .due) }
            guard let (date, part) = dates.min(by: { ($0.0, $0.1) < ($1.0, $1.1) }) else { return nil }
            return TimelinePlacement(item: item, day: max(date, today), date: date, part: part)
        }
    }

    /// The stop's items, in order. What starts there has those on today first, then those
    /// started earlier, oldest first, then later days in order; on a day, those with a time come
    /// first, earliest first, then the rest in the list's order. What's due and to follow up is
    /// oldest date first, then in the list's order.
    public static func parts(of stop: TimelineStop, _ placements: [TimelinePlacement], today: LocalDate) -> TimelineParts {
        let shown = placements.filter { stop.contains($0.day) }
        func part(_ part: TimelinePlacement.Part) -> [Item] {
            shown.filter { $0.part == part }
                .sorted { a, b in
                    let (earlierA, earlierB) = (a.date < today, b.date < today)
                    if part == .starts, earlierA != earlierB { return earlierB }
                    if a.date != b.date { return a.date < b.date }
                    if part == .starts {
                        switch (a.item.scheduledTime, b.item.scheduledTime) {
                        case (let x?, let y?) where x != y: return x < y
                        case (.some, nil): return true
                        case (nil, .some): return false
                        default: break
                        }
                    }
                    return Item.inListOrder(a.item, b.item)
                }
                .map(\.item)
        }
        return TimelineParts(starts: part(.starts), due: part(.due), followUp: part(.followUp))
    }

    /// The days ahead the weekly review looks at, today among them.
    public static let reviewDays = 28

    /// The stops with something in the `days` days from today, each with its items there, each
    /// item once, in the stop `stop(for:in:)` gives its day: what starts, then what's due, then
    /// what to follow up, each in `parts`' order.
    public static func ahead(_ stops: [TimelineStop], _ placements: [TimelinePlacement], today: LocalDate, days: Int = reviewDays)
        -> [(stop: TimelineStop, items: [Item])]
    {
        let end = today.adding(days: days)
        let near = Dictionary(grouping: placements.filter { $0.day < end }) { stop(for: $0.day, in: stops) }
        return stops.compactMap { stop in
            let parts = parts(of: stop, near[stop] ?? [], today: today)
            let items = parts.starts + parts.due + parts.followUp
            return items.isEmpty ? nil : (stop, items)
        }
    }

    /// The stops that have something.
    public static func filled(_ stops: [TimelineStop], _ placements: [TimelinePlacement]) -> Set<TimelineStop> {
        Set(stops.filter { stop in placements.contains { stop.contains($0.day) } })
    }
}
