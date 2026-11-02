import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct WaitingListTests {
    static let today = LocalDate(2026, 10, 21)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
    }

    @discardableResult
    func waiting(_ title: String, for person: String?, followUpIn days: Int? = nil) -> Item {
        let item = Item(title: title, bucket: .waiting)
        item.waitingOn = person
        item.followUpDate = days.map { Self.today.adding(days: $0).storedDate }
        context.insert(item)
        return item
    }

    func groups(_ items: [Item], doneSince: Date? = nil) -> [WaitingGroup] {
        WaitingList.groups(items, today: Self.today, doneSince: doneSince)
    }

    @Test func groupedByPersonWithNoOneLast() {
        let items = [
            waiting("Invoice", for: nil), waiting("Quote", for: "Sam"), waiting("Keys", for: "alex"), waiting("Report", for: "Sam "),
        ]
        let groups = groups(items)
        #expect(groups.map(\.person) == ["alex", "Sam", nil])
        #expect(groups.map { $0.items.map(\.title).sorted() } == [["Keys"], ["Quote", "Report"], ["Invoice"]])
    }

    @Test(
        arguments: [
            ("Sam", .letter("S")), ("alex", .letter("A")), ("Émile", .letter("E")), ("  zoë", .letter("Z")), ("3M", .letter("#")),
            ("Øystein", .letter("#")), (nil, .noOne),
        ] as [(String?, WaitingTab)])
    func aGroupIsFiledUnderItsPersonsFirstLetter(person: String?, tab: WaitingTab) {
        #expect(groups([waiting("Quote", for: person)]).first?.tab == tab)
    }

    @Test func theTabsAreTheAlphabetThenOthersAndNoOneWhenUsed() {
        let letters = WaitingTab.alphabet.map { WaitingTab.letter($0) }
        #expect(letters.count == 26)
        #expect(WaitingTab.tabs(for: groups([waiting("Quote", for: "Sam")])) == letters)
        let items = [waiting("Quote", for: "Sam"), waiting("Parts", for: "3M"), waiting("Invoice", for: nil)]
        #expect(WaitingTab.tabs(for: groups(items)) == letters + [.letter("#"), .noOne])
    }

    @Test func soonestFollowUpFirstAndUndatedLast() {
        let items = [
            waiting("Undated", for: "Sam"), waiting("Next week", for: "Sam", followUpIn: 7), waiting("Overdue", for: "Sam", followUpIn: -2),
            waiting("Tomorrow", for: "Sam", followUpIn: 1),
        ]
        #expect(groups(items).first?.items.map(\.title) == ["Overdue", "Tomorrow", "Next week", "Undated"])
    }

    @Test func onlyWaitingItemsShowingToday() {
        let open = waiting("Quote", for: "Sam")
        let hidden = waiting("Keys", for: "Sam")
        hidden.hideUntil = Self.today.adding(days: 2).storedDate
        let action = waiting("Call", for: "Sam")
        action.bucket = .action
        let sub = waiting("Subtask", for: "Sam")
        sub.parent = open
        let dayStart = Date(timeIntervalSince1970: 2_000_000)
        let doneToday = waiting("Signed", for: "Sam")
        doneToday.markDone(at: dayStart.addingTimeInterval(60))
        let doneBefore = waiting("Paid", for: "Sam")
        doneBefore.markDone(at: dayStart.addingTimeInterval(-60))
        let shown = groups([open, hidden, action, sub, doneToday, doneBefore], doneSince: dayStart).flatMap(\.items).map(\.title)
        #expect(Set(shown) == ["Quote", "Subtask", "Signed"])
    }

    @Test func peopleAreEveryoneNamedOnceInAlphabeticalOrder() {
        let earlier = Date(timeIntervalSince1970: 1_000_000)
        waiting("Quote", for: "sam").modifiedAt = earlier
        waiting("Report", for: " Sam ").modifiedAt = earlier.addingTimeInterval(60)
        waiting("Keys", for: "Émile")
        waiting("Invoice", for: nil)
        waiting("Parts", for: "  ")
        let done = waiting("Tiles", for: "alex")
        done.markDone()
        done.bucket = .action
        waiting("Ladder", for: "Jo").bucket = .trash
        let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        #expect(WaitingList.people(items) == ["alex", "Émile", "Sam"])
    }

    @Test(
        arguments: [
            ("s", ["Sam", "Sam Smith", "Sasha", "Jo Smith"]), ("sam", ["Sam Smith"]), ("SM", ["Jo Smith", "Sam Smith"]),
            ("emi", ["Émile"]), ("sam s", ["Sam Smith"]), ("  ", []), ("x", []),
        ] as [(String, [String])])
    func namesMatchTheStartOfTheNameOrOfALaterWord(typed: String, matches: [String]) {
        let people = ["Émile", "Jo Smith", "Sam", "Sam Smith", "Sasha"]
        #expect(WaitingList.matches(typed, among: people) == matches)
    }

    @Test func nudgeAddsAFollowUpActionInCallsAndTheProject() throws {
        let project = context.insertProject("Kitchen")
        let item = waiting("the quote", for: "Sam")
        item.parent = project
        try context.save()
        let undo = Clarifier.nudge(item, in: context)
        let actions = try context.fetch(FetchDescriptor<Item>()).filter { $0.bucket == .action && !$0.isProject }
        let made = try #require(actions.first)
        #expect(actions.count == 1 && made.title == "Follow up with Sam about the quote")
        #expect(made.contexts?.map(\.name) == ["Calls"] && made.project === project && made.status == .open)
        #expect(item.bucket == .waiting, "the waiting item stays")
        Clarifier.undo(undo, in: context)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Item>()).filter { $0.bucket == .action && !$0.isProject }.isEmpty)
    }

    @Test func nudgingNoOneNamedSaysWhatItsAbout() {
        let item = waiting("the invoice", for: nil)
        _ = Clarifier.nudge(item, in: context)
        let titles = (try? context.fetch(FetchDescriptor<Item>()))?.filter { $0.bucket == .action }.map(\.title)
        #expect(titles == ["Follow up about the invoice"])
    }

    @Test func takeBackMovesToActionsKeepingTheProject() throws {
        let project = context.insertProject("Kitchen")
        let item = waiting("Quote", for: "Sam")
        item.parent = project
        try context.save()
        let undo = try #require(Clarifier.takeBack([item]))
        #expect(item.bucket == .action && item.project === project && item.isInActions(today: Self.today))
        Clarifier.undo(undo, in: context)
        #expect(item.bucket == .waiting)
        item.bucket = .someday
        #expect(Clarifier.takeBack([item]) == nil)
    }
}
