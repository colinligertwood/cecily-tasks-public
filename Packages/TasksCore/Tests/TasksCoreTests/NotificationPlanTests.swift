import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct NotificationPlanTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    static let today = LocalDate(2026, 10, 20)
    static let now = today.date(in: calendar, hour: 10)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
    }

    func item(_ title: String, _ bucket: Bucket = .action, starts: Int? = nil, at hour: Int? = nil, due: Int? = nil, followUp: Int? = nil) -> Item {
        let item = Item(title: title, bucket: bucket)
        let day = { (days: Int) in Self.today.adding(days: days) }
        item.scheduledDate = starts.map { day($0).storedDate }
        item.scheduledTime = starts.flatMap { starts in hour.map { day(starts).date(in: Self.calendar, hour: $0, minute: 30) } }
        item.dueDate = due.map { day($0).storedDate }
        item.followUpDate = followUp.map { day($0).storedDate }
        context.insert(item)
        return item
    }

    func plan(_ items: [Item], _ settings: NotificationSettings = NotificationSettings()) -> [PlannedNotification] {
        NotificationPlan.notifications(items, settings: settings, now: Self.now, in: Self.calendar)
    }

    func moment(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.today.adding(days: days).date(in: Self.calendar, hour: hour, minute: minute)
    }

    @Test func eachTriggerIsAtItsTime() {
        let planned = plan([
            item("Dentist", starts: 1, at: 14), item("Tax return", due: 2), item("Quote", .waiting, followUp: 3),
        ])
        #expect(planned.map(\.title) == ["Dentist", "Tax return", "Quote"])
        #expect(planned.map(\.trigger) == [.starts, .due, .followUp])
        #expect(planned.map(\.date) == [moment(1, 14, 30), moment(2, 9), moment(3, 9)])
        #expect(planned.map(\.body) == ["Scheduled for now", "Due today", "Follow up"])
    }

    @Test func aFollowUpNamesWhoItsWaitingFor() {
        let quote = item("Quote", .waiting, followUp: 1)
        quote.waitingOn = "Sam"
        #expect(plan([quote]).map(\.body) == ["Follow up with Sam"])
    }

    @Test func anItemCanHaveSeveral() {
        #expect(plan([item("Both", starts: 1, at: 8, due: 1)]).map(\.trigger) == [.starts, .due])
    }

    @Test func theTimeOfDayIsTheSettings() {
        #expect(plan([item("Due", due: 1)], NotificationSettings(timeOfDay: 7 * 60 + 45)).map(\.date) == [moment(1, 7, 45)])
    }

    @Test func aStartWithoutATimeAndAFollowUpOutOfWaitingHaveNone() {
        #expect(plan([item("Untimed", starts: 1), item("Not waiting", followUp: 1)]).isEmpty)
    }

    @Test func eachSwitchTurnsItsOwnOff() {
        let items = [item("Dentist", starts: 1, at: 14), item("Tax return", due: 2), item("Quote", .waiting, followUp: 3)]
        #expect(plan(items, NotificationSettings(starts: false)).map(\.trigger) == [.due, .followUp])
        #expect(plan(items, NotificationSettings(due: false)).map(\.trigger) == [.starts, .followUp])
        #expect(plan(items, NotificationSettings(followUps: false)).map(\.trigger) == [.starts, .due])
    }

    @Test func onlyWhatsStillToComeIsPlanned() {
        #expect(plan([item("This morning", due: 0), item("Yesterday", due: -1), item("Earlier today", starts: 0, at: 8)]).isEmpty)
        #expect(plan([item("This afternoon", starts: 0, at: 15)]).map(\.date) == [moment(0, 15, 30)])
    }

    @Test func doneDroppedTrashedAndUnderGoneTasksHaveNone() {
        let done = item("Done", due: 1)
        done.markDone(at: Self.now)
        let dropped = item("Dropped", due: 1)
        dropped.status = .dropped
        let trashed = item("Trashed", .trash, due: 1)
        let project = context.insertProject("Dropped project")
        project.status = .dropped
        let inProject = item("In it", due: 1)
        inProject.parent = project
        #expect(plan([done, dropped, trashed, project, inProject]).isEmpty)
    }

    @Test func subtasksHaveTheirOwn() {
        let parent = item("Parent")
        let subtask = item("Subtask", due: 1)
        subtask.parent = parent
        #expect(plan([parent, subtask]).map(\.title) == ["Subtask"])
    }

    @Test func hiddenItemsStillHaveThem() {
        let hidden = item("Hidden", due: 5)
        hidden.hideUntil = Self.today.adding(days: 4).storedDate
        #expect(plan([hidden]).count == 1)
    }

    @Test func theIDsStayTheSameAndFollowTheDay() throws {
        let tax = item("Tax return", due: 2)
        let first = try #require(plan([tax]).first)
        #expect(plan([tax]).first?.id == first.id)
        tax.title = "Self assessment"
        #expect(plan([tax]).first?.id == first.id)
        tax.dueDate = Self.today.adding(days: 3).storedDate
        #expect(plan([tax]).first?.id != first.id)
        #expect(first.id == "\(tax.id.uuidString)-due-\(Self.today.adding(days: 2))")
    }

    @Test func onlyTheSoonestAreKept() {
        let items = (1...80).map { (day: Int) in item("Due \(day)", due: day) }
        let planned = plan(items.shuffled())
        #expect(planned.count == NotificationPlan.limit)
        #expect(planned.map(\.title) == (1...60).map { "Due \($0)" })
    }

    @Test func aDaylightSavingDayKeepsTheClockTime() {
        // The clocks go back in London on 25 October 2026.
        #expect(plan([item("Dentist", starts: 5, at: 9), item("Tax return", due: 5)]).map(\.date) == [moment(5, 9), moment(5, 9, 30)])
        #expect(Self.calendar.dateComponents([.hour, .minute], from: moment(5, 9, 30)) == DateComponents(hour: 9, minute: 30))
    }
}
