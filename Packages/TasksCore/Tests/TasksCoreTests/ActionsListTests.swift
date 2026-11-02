import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct ActionsListTests {
    static let today = LocalDate(2026, 10, 21)
    static let start = Date(timeIntervalSince1970: 1_000_000)
    let container: ModelContainer
    let context: ModelContext
    let calls: Context
    let errands: Context

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        calls = Context(name: "Calls")
        calls.sortOrder = 1
        errands = Context(name: "Errands")
        errands.sortOrder = 0
        context.insert(calls)
        context.insert(errands)
    }

    /// An action made `minute` minutes after the start, so later ones are newer.
    func action(_ title: String, minute: Double, _ contexts: [Context] = []) -> Item {
        let item = Item(title: title, bucket: .action)
        item.createdAt = Self.start.addingTimeInterval(minute * 60)
        context.insert(item)
        item.contexts = contexts
        return item
    }

    func titles(_ groups: [ListGroup]) -> [[String]] {
        groups.map { $0.items.map(\.title) }
    }

    func groups(_ items: [Item], by grouping: ActionsGrouping, _ filter: ActionsFilter = ActionsFilter()) -> [ListGroup] {
        ActionsList.groups(items, by: grouping, filter: filter, today: Self.today, doneSince: nil)
    }

    // MARK: Grouping

    @Test func byContextInTheContextsOrderWithAnywhereLast() {
        let items = [
            action("Call the bank", minute: 1, [calls]),
            action("Buy stamps", minute: 2, [errands]),
            action("Read the lease", minute: 3),
            action("Call Sam", minute: 4, [calls]),
        ]
        let groups = groups(items, by: .context)
        #expect(groups.map(\.id) == ["context-\(errands.id)", "context-\(calls.id)", "no-context"])
        #expect(titles(groups) == [["Buy stamps"], ["Call Sam", "Call the bank"], ["Read the lease"]])
    }

    @Test func anActionWithSeveralContextsIsInEach() {
        let both = action("Return the parcel", minute: 1, [calls, errands])
        let groups = groups([both], by: .context)
        #expect(titles(groups) == [["Return the parcel"], ["Return the parcel"]])
    }

    @Test func aHiddenContextDoesntCount() {
        calls.isHidden = true
        let groups = groups([action("Call the bank", minute: 1, [calls])], by: .context)
        #expect(groups.map(\.id) == ["no-context"])
    }

    @Test func byProjectInTheProjectsOrder() {
        let garden = context.insertProject("Garden")
        garden.sortOrder = 2
        let taxes = context.insertProject("Taxes")
        taxes.sortOrder = 1
        let seeds = action("Buy seeds", minute: 1)
        seeds.parent = garden
        let receipts = action("Gather receipts", minute: 2)
        receipts.parent = taxes
        let loose = action("Call the bank", minute: 3)
        let groups = groups([seeds, receipts, loose], by: .project)
        #expect(groups.map(\.id) == ["project-\(taxes.id)", "project-\(garden.id)", "no-project"])
        #expect(titles(groups) == [["Gather receipts"], ["Buy seeds"], ["Call the bank"]])
    }

    @Test func byAreaUsesTheProjectsAreaWhenTheActionHasNone() {
        let home = Area(name: "Home")
        let work = Area(name: "Work")
        work.sortOrder = 1
        let garden = context.insertProject("Garden")
        for model in [home, work] { context.insert(model) }
        garden.area = home
        let seeds = action("Buy seeds", minute: 1)
        seeds.parent = garden
        let report = action("Write the report", minute: 2)
        report.area = work
        let loose = action("Call the bank", minute: 3)
        let groups = groups([seeds, report, loose], by: .area)
        #expect(groups.map(\.id) == ["area-\(home.id)", "area-\(work.id)", "no-area"])
        #expect(titles(groups) == [["Buy seeds"], ["Write the report"], ["Call the bank"]])
    }

    @Test func ungroupedIsOneGroupNewestFirst() {
        let items = [action("Older", minute: 1, [calls]), action("Newer", minute: 2)]
        #expect(titles(groups(items, by: .none)) == [["Newer", "Older"]])
        #expect(groups([], by: .none).isEmpty)
    }

    @Test(arguments: ActionsGrouping.allCases)
    func onlyWhatsInActionsIsGrouped(grouping: ActionsGrouping) {
        let open = action("Open", minute: 1)
        let waiting = action("Waiting", minute: 2)
        waiting.bucket = .waiting
        let later = action("Later", minute: 3)
        later.scheduledDate = Self.today.adding(days: 1).storedDate
        let sub = action("Subtask", minute: 4)
        sub.parent = open
        let alone = action("Alone", minute: 5)
        #expect(groups([open, waiting, later, sub, alone], by: grouping).flatMap(\.items).map(\.title).sorted() == ["Alone", "Subtask"])
    }

    @Test func doneTodayStaysInItsGroup() {
        let dayStart = Self.start
        let done = action("Call the bank", minute: 1, [calls])
        done.markDone(at: dayStart.addingTimeInterval(120))
        let groups = ActionsList.groups([done], by: .context, today: Self.today, doneSince: dayStart)
        #expect(titles(groups) == [["Call the bank"]])
    }

    @Test func aTaskKeptStaysAfterGettingASubtask() {
        let task = action("Paint the shed", minute: 1, [calls])
        let moved = action("Buy brushes", minute: 2, [errands])
        moved.parent = task
        #expect(titles(groups([task, moved], by: .context)) == [["Buy brushes"]])
        let kept = ActionsList.groups([task, moved], by: .context, today: Self.today, doneSince: nil, keeping: [task.id])
        #expect(titles(kept) == [["Buy brushes"], ["Paint the shed"]])
    }

    // MARK: Filters

    @Test(arguments: [
        (TimeEstimate.fiveMinutes, ["5"]),
        (.thirtyMinutes, ["5", "30"]),
        (.twoHoursOrMore, ["5", "30", "2h"]),
    ])
    func timeShowsWhatFits(time: TimeEstimate, shown: [String]) {
        let items = [(TimeEstimate.fiveMinutes, "5"), (.thirtyMinutes, "30"), (.twoHoursOrMore, "2h")].enumerated().map { index, pair in
            let item = action(pair.1, minute: -Double(index))
            item.timeEstimate = pair.0
            return item
        }
        let unknown = action("unknown", minute: -10)
        #expect(groups(items + [unknown], by: .none, ActionsFilter(time: time)).flatMap(\.items).map(\.title) == shown)
    }

    @Test(arguments: [(Energy.low, ["low"]), (.medium, ["low", "medium"]), (.high, ["low", "medium", "high"])])
    func energyShowsWhatMatches(energy: Energy, shown: [String]) {
        let items = Energy.allCases.enumerated().map { index, needed in
            let item = action(needed.rawValue, minute: -Double(index))
            item.energy = needed
            return item
        }
        let unknown = action("unknown", minute: -10)
        #expect(groups(items + [unknown], by: .none, ActionsFilter(energy: energy)).flatMap(\.items).map(\.title) == shown)
    }

    @Test(arguments: [(-3, true), (0, true), (7, true), (8, false)])
    func dueSoonIsWithinAWeek(daysAhead: Int, isShown: Bool) {
        let item = action("Renew the passport", minute: 1)
        item.dueDate = Self.today.adding(days: daysAhead).storedDate
        let undated = action("Undated", minute: 2)
        let shown = groups([item, undated], by: .none, ActionsFilter(dueSoon: true)).flatMap(\.items).map(\.title)
        #expect(shown == (isShown ? ["Renew the passport"] : []))
    }

    @Test func filtersCombine() {
        let quick = action("Quick and easy", minute: 1)
        quick.timeEstimate = .fiveMinutes
        quick.energy = .low
        let hard = action("Quick but hard", minute: 2)
        hard.timeEstimate = .fiveMinutes
        hard.energy = .high
        let filter = ActionsFilter(time: .fifteenMinutes, energy: .low)
        #expect(!filter.isEmpty && ActionsFilter().isEmpty)
        #expect(groups([quick, hard], by: .none, filter).flatMap(\.items).map(\.title) == ["Quick and easy"])
    }

    // MARK: Details

    @Test func estimateAndEnergyAreSetOnlyWhenTheyChange() {
        let item = action("Call the bank", minute: 1)
        item.modifiedAt = .distantPast
        let now = Date(timeIntervalSince1970: 2_000_000)
        item.setTimeEstimate(nil, at: now)
        item.setEnergy(nil, at: now)
        #expect(item.modifiedAt == .distantPast)
        item.setTimeEstimate(.fifteenMinutes, at: now)
        #expect(item.timeEstimate == .fifteenMinutes && item.modifiedAt == now)
        item.setEnergy(.medium, at: now.addingTimeInterval(60))
        #expect(item.energy == .medium && item.modifiedAt == now.addingTimeInterval(60))
    }
}
