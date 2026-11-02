import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct CaptureTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
        context.insertProject("Kitchen refit", withSubtask: true)
        context.insertProject("Old move", withSubtask: true).status = .done
        try context.save()
    }

    @Test func eachLineLandsInTheInboxWithWhatItNamed() throws {
        let items = Capture.add(
            "Ask about worktops #kitchen-refit @calls due:fri\nWater plants every weekday\nPlain one", source: .quickAdd,
            today: LocalDate(2026, 10, 20), in: context)
        try context.save()
        #expect(items.map(\.title) == ["Ask about worktops", "Water plants", "Plain one"])
        #expect(items.allSatisfy { $0.bucket == .inbox && $0.status == .open && $0.source == .quickAdd })
        #expect(items[0].project?.title == "Kitchen refit" && items[0].contexts?.map(\.name) == ["Calls"])
        #expect(items[0].dueDate.map(LocalDate.init(day:)) == LocalDate(2026, 10, 23))
        #expect(items[1].repeatRule?.naturalText == "every weekday" && items[1].repeatRule?.rrule == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        #expect(items[2].project == nil && items[2].contexts?.isEmpty == true)
    }

    @Test func anEntrysFirstLineIsItsTitleAndTheRestItsNotes() throws {
        let item = try #require(
            Capture.add(
                entry: "\nAsk about worktops @calls due:fri\n\n- Granite or oak?\n- **Budget** first\n\n", details: CaptureDetails(),
                source: .quickAdd, today: LocalDate(2026, 10, 20), in: context))
        #expect(item.title == "Ask about worktops" && item.bucket == .inbox)
        #expect(item.body == "- Granite or oak?\n- **Budget** first")
        #expect(item.contexts?.map(\.name) == ["Calls"] && item.dueDate.map(LocalDate.init(day:)) == LocalDate(2026, 10, 23))
    }

    @Test func anEntrysChosenDetailsWinOverItsTokens() throws {
        let home = Area(name: "Home")
        context.insert(home)
        let errands = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name != "Calls" })
        var details = CaptureDetails()
        details.area = .chosen(home.id)
        details.due = .chosen(LocalDate(2026, 11, 2))
        details.contexts = .chosen([errands.id])
        details.repeats = .chosen("every 2 weeks")
        details.timeEstimate = .fifteenMinutes
        details.energy = .low
        let item = try #require(
            Capture.add(
                entry: "Buy filters @calls due:fri every day", details: details, source: .quickAdd, today: LocalDate(2026, 10, 20), in: context))
        #expect(item.title == "Buy filters" && item.area?.id == home.id)
        #expect(item.dueDate.map(LocalDate.init(day:)) == LocalDate(2026, 11, 2))
        #expect(item.contexts?.map(\.id) == [errands.id])
        #expect(item.repeatRule?.naturalText == "every 2 weeks" && item.repeatRule?.rrule == "FREQ=WEEKLY;INTERVAL=2")
        #expect(item.timeEstimate == .fifteenMinutes && item.energy == .low)
    }

    @Test func anEntrysDetailsChosenAsNoneWinOverItsTokens() throws {
        var details = CaptureDetails()
        details.project = .chosen(nil)
        details.due = .chosen(nil)
        details.contexts = .chosen([])
        details.repeats = .chosen(nil)
        let item = try #require(
            Capture.add(
                entry: "Ask about tiles #kitchen-refit @calls due:fri every week", details: details, source: .quickAdd,
                today: LocalDate(2026, 10, 20), in: context))
        #expect(item.title == "Ask about tiles" && item.parent == nil && item.dueDate == nil)
        #expect(item.contexts?.isEmpty == true && item.repeatRule == nil)
    }

    @Test func anEntryTakesTheListsAreaUnlessAnothersChosen() throws {
        let home = Area(name: "Home")
        let work = Area(name: "Work")
        context.insert(home)
        context.insert(work)
        let today = LocalDate(2026, 10, 20)
        let first = try #require(
            Capture.add(entry: "Fix the gate", details: CaptureDetails(), area: home.id, source: .quickAdd, today: today, in: context))
        var details = CaptureDetails()
        details.area = .chosen(work.id)
        let second = try #require(
            Capture.add(entry: "File the expenses", details: details, area: home.id, source: .quickAdd, today: today, in: context))
        details.area = .chosen(nil)
        let third = try #require(Capture.add(entry: "Read the paper", details: details, area: home.id, source: .quickAdd, today: today, in: context))
        #expect(first.area?.id == home.id && second.area?.id == work.id && third.area == nil)
    }

    @Test func anEntryWithNoTitleAddsNothing() {
        #expect(Capture.add(entry: "\n  \n", details: CaptureDetails(), source: .quickAdd, today: LocalDate(2026, 10, 20), in: context) == nil)
        #expect(Capture.add(entry: "@calls", details: CaptureDetails(), source: .quickAdd, today: LocalDate(2026, 10, 20), in: context) == nil)
    }

    @Test func aReferenceNoteWithSubtasksCanBeNamed() throws {
        let meeting = Item(title: "1:1 with Noor", bucket: .reference)
        meeting.kind = .note
        context.insert(meeting)
        let raised = Item(title: "Training budget", bucket: .action)
        context.insert(raised)
        raised.parent = meeting
        try context.save()
        let items = Capture.add("On-call rota #1:1-with-noor", source: .quickAdd, today: LocalDate(2026, 10, 20), in: context)
        #expect(items.first?.title == "On-call rota" && items.first?.parent === meeting && items.first?.bucket == .inbox)
    }

    @Test func linesKeepTheirOrder() throws {
        let items = Capture.add("one\ntwo\nthree", source: .quickAdd, today: LocalDate(2026, 10, 20), in: context)
        try context.save()
        let sorted = try context.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.createdAt)])).filter { $0.bucket == .inbox }.map(\.title)
        #expect(sorted == items.map(\.title))
    }

    @Test func aFinishedProjectOrHiddenContextIsntNamed() throws {
        try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Errands" }).isHidden = true
        let items = Capture.add("Box things #old-move @errands", source: .quickAdd, today: LocalDate(2026, 10, 20), in: context)
        #expect(items.first?.title == "Box things #old-move @errands")
    }

    @Test func theSourceIsRecorded() {
        let items = Capture.add("From the brain dump", source: .review, today: LocalDate(2026, 10, 20), in: context)
        #expect(items.first?.source == .review)
    }

    @Test func itemsCanBeAddedToAnotherList() {
        let today = LocalDate(2026, 10, 20)
        let someday = Capture.add("Learn the cello", source: .quickAdd, today: today, bucket: .someday, in: context)
        #expect(someday.first?.bucket == .someday && someday.first?.scheduledDate == nil)
        let scheduled = Capture.add(
            "Book the MOT\nRenew the TV licence !fri", source: .quickAdd, today: today, bucket: .action, scheduled: today, in: context)
        #expect(scheduled.allSatisfy { $0.bucket == .action })
        #expect(scheduled.map { $0.scheduledDate.map(LocalDate.init(day:)) } == [today, LocalDate(2026, 10, 23)])
    }

    @Test func itemsTakeTheAreaTheyreAddedIn() throws {
        let area = Area(name: "Work")
        context.insert(area)
        let items = Capture.add("one\ntwo", source: .quickAdd, today: LocalDate(2026, 10, 20), area: area.id, in: context)
        #expect(items.allSatisfy { $0.area === area })
        #expect(Capture.add("three", source: .quickAdd, today: LocalDate(2026, 10, 20), in: context).first?.area == nil)
    }
}

struct BrainDumpTests {
    @Test func theBuiltInPromptsAreTheSpecsEight() {
        let prompts = BrainDump.prompts([])
        #expect(prompts.map(\.title) == ["Work", "Home", "Money", "Health", "People", "Errands", "Ideas", "Anything else on your mind."])
        #expect(prompts[1].detail == "repairs, purchases, admin, paperwork, household.")
    }

    @Test func theSettingsOwnPromptsReplaceThem() {
        let prompts = BrainDump.prompts(["Garden: beds, tools", " ", "Car"])
        #expect(prompts.map(\.line) == ["Garden: beds, tools", "Car"])
    }
}
