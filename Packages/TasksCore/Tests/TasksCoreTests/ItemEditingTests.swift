import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct ItemEditingTests {
    static let then = Date(timeIntervalSince1970: 1_000_000)
    static let now = Date(timeIntervalSince1970: 2_000_000)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
    }

    func item(_ bucket: Bucket = .action) -> Item {
        let item = Item(title: "Insurance", bucket: bucket)
        item.modifiedAt = Self.then
        context.insert(item)
        return item
    }

    @Test(arguments: [
        (Bucket.inbox, [ItemField.area, .project, .scheduled, .due, .repeats, .hideUntil, .contexts]),
        (.action, [.area, .project, .scheduled, .due, .repeats, .hideUntil, .contexts, .timeEstimate, .energy]),
        (.waiting, [.area, .project, .due, .repeats, .hideUntil, .waitingFor, .followUp]),
        (.someday, [.area, .project, .hideUntil]),
        (.reference, [.area, .project, .hideUntil, .meeting]),
        (.trash, []),
    ])
    func fieldsFollowTheList(bucket: Bucket, fields: [ItemField]) {
        #expect(item(bucket).editableFields == fields)
    }

    @Test(arguments: Bucket.allCases)
    func theInspectorOffersEveryFieldWithTheMeetingOnlyInReference(bucket: Bucket) {
        let outOfReference = ItemField.allCases.filter { $0 != .meeting }
        #expect(item(bucket).inspectableFields == (bucket == .reference ? ItemField.allCases : outOfReference))
    }

    @Test(arguments: [
        (Bucket?.some(.reference), ItemField.allCases), (.action, ItemField.allCases.filter { $0 != .meeting }),
        (nil, ItemField.allCases.filter { $0 != .meeting }),
    ])
    func inTheTrashTheInspectorOffersTheFieldsOfWhereItGoesBack(from: Bucket?, fields: [ItemField]) {
        let item = item(.trash)
        item.trashedFrom = from
        #expect(item.inspectableFields == fields)
    }

    @Test func theGroupsHoldEveryFieldOnceInTheRowsOrder() {
        #expect(ItemField.Group.allCases.flatMap(\.fields) == ItemField.allCases)
        #expect(ItemField.Group.when.fields == [.scheduled, .due, .repeats, .hideUntil, .meeting])
        #expect(ItemField.Group.waiting.fields == [.waitingFor, .followUp])
    }

    @Test func fieldsKeepTheRowsOrder() {
        for bucket in Bucket.allCases {
            let fields = item(bucket).editableFields
            #expect(fields == ItemField.allCases.filter(fields.contains))
        }
    }

    @Test(arguments: [ItemField.due, .scheduled, .followUp, .hideUntil])
    func aDayIsSetAndCleared(field: ItemField) {
        let item = item()
        item.setDay(LocalDate(2026, 10, 23), for: field, at: Self.now)
        #expect(item.day(field) == LocalDate(2026, 10, 23))
        #expect(item.modifiedAt == Self.now)
        item.setDay(nil, for: field)
        #expect(item.day(field) == nil)
    }

    @Test func anUnchangedValueLeavesModifiedAtAlone() {
        let item = item()
        item.setTitle("Insurance", at: Self.now)
        item.setDay(nil, for: .due, at: Self.now)
        item.setProject(nil, at: Self.now)
        item.setArea(nil, at: Self.now)
        item.setWaitingFor("  ", at: Self.now)
        #expect(item.modifiedAt == Self.then)
    }

    @Test(arguments: [Bucket.inbox, .action])
    func startingTodayFilesInActionsAndShowsAHiddenItem(bucket: Bucket) {
        let today = LocalDate(2026, 10, 26)
        let item = item(bucket)
        item.scheduledDate = LocalDate(2026, 11, 2).storedDate
        item.hideUntil = LocalDate(2026, 10, 30).storedDate
        item.start(on: today, in: .current, at: Self.now)
        #expect(item.bucket == .action && item.day(.scheduled) == today && item.hideUntil == nil)
        #expect(item.scheduledTime == nil && item.modifiedAt == Self.now)
    }

    @Test func startingTodayKeepsTheTimeOfDayAcrossADaylightSavingChange() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let item = item()
        item.scheduledDate = LocalDate(2026, 10, 20).storedDate
        item.scheduledTime = LocalDate(2026, 10, 20).date(in: london, hour: 14, minute: 30)
        item.start(on: LocalDate(2026, 10, 26), in: london, at: Self.now)
        #expect(item.scheduledTime == LocalDate(2026, 10, 26).date(in: london, hour: 14, minute: 30))
        #expect(london.dateComponents([.hour, .minute], from: item.scheduledTime!) == DateComponents(hour: 14, minute: 30))
    }

    @Test func startingTodayKeepsAnEarlierHideUntilAndLeavesATodayItemAlone() {
        let today = LocalDate(2026, 10, 26)
        let item = item()
        item.scheduledDate = today.storedDate
        item.hideUntil = LocalDate(2026, 10, 1).storedDate
        item.start(on: today, in: .current, at: Self.now)
        #expect(item.day(.hideUntil) == LocalDate(2026, 10, 1) && item.modifiedAt == Self.then)
    }

    @Test func startingOnALaterDayShowsOnlyWhatsHiddenPastIt() {
        let item = item(.inbox)
        item.hideUntil = LocalDate(2026, 11, 5).storedDate
        item.start(on: LocalDate(2026, 11, 9), in: .current, at: Self.now)
        #expect(item.bucket == .action && item.day(.scheduled) == LocalDate(2026, 11, 9) && item.day(.hideUntil) == LocalDate(2026, 11, 5))
        item.start(on: LocalDate(2026, 11, 2), in: .current, at: Self.now)
        #expect(item.day(.scheduled) == LocalDate(2026, 11, 2) && item.hideUntil == nil)
    }

    @Test(arguments: [Bucket.waiting, .someday, .reference, .trash])
    func onlyTheInboxAndActionsStartToday(bucket: Bucket) {
        let item = item(bucket)
        #expect(!item.canStart)
        item.start(on: LocalDate(2026, 10, 26), in: .current, at: Self.now)
        #expect(item.bucket == bucket && item.scheduledDate == nil && item.modifiedAt == Self.then)
    }

    @Test func notesAndDoneItemsDontStartToday() {
        let note = item()
        note.kind = .note
        let done = item()
        done.status = .done
        let parent = item()
        let subtask = item()
        subtask.parent = parent
        #expect(![note, done].contains { $0.canStart })
        #expect(parent.canStart && subtask.canStart)
    }

    @Test func titleProjectAndAreaAreSet() {
        let item = item()
        let project = context.insertProject("Kitchen refit")
        let area = Area(name: "Home")
        context.insert(area)
        item.setTitle("Renew insurance", at: Self.now)
        item.setProject(project)
        item.setArea(area)
        #expect(item.title == "Renew insurance" && item.project === project && item.parent === project && item.area === area)
        #expect(item.modifiedAt > Self.then)
    }

    @Test func anyTaskGoesUnderAnotherButNotUnderItsOwnSubtask() {
        let project = context.insertProject("Kitchen refit")
        let other = context.insertProject("Garden")
        let subtask = item()
        subtask.parent = item()
        subtask.setProject(project)
        other.setProject(project)
        let below = item()
        below.parent = other
        other.setProject(below)
        #expect(subtask.project === project && other.parent === project && below.parent === other)
        subtask.setProject(nil)
        #expect(subtask.parent == nil)
    }

    @Test func everyTaskHasItsOwnDetails() {
        let project = context.insertProject("Kitchen refit")
        let action = item()
        action.parent = project
        let subtask = item(.waiting)
        subtask.parent = action
        for item in [project, action, subtask] {
            #expect(
                item.editableFields == ItemField.fields(for: item.bucket) && item.inspectableFields == ItemField.allCases.filter { $0 != .meeting })
        }
    }

    @Test func aContextIsToggled() throws {
        let item = item()
        let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
        item.toggle(calls, at: Self.now)
        #expect(item.contexts?.map(\.name) == ["Calls"])
        #expect(item.modifiedAt == Self.now)
        item.toggle(calls)
        #expect(item.contexts?.isEmpty == true)
    }

    @Test func waitingForIsTrimmedAndBlankClearsIt() {
        let item = item(.waiting)
        item.setWaitingFor("  Sam ", at: Self.now)
        #expect(item.waitingOn == "Sam")
        item.setWaitingFor("")
        #expect(item.waitingOn == nil)
    }
}

@MainActor
struct NewRecordTests {
    let context: ModelContext

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
        try TasksSchema.seed(context)
    }

    @Test func eachIsMadeTrimmedAndPutLast() throws {
        let area = try #require(NewRecord.area(named: " Garden ", in: context))
        let later = try #require(NewRecord.area(named: "Travel", in: context))
        #expect(area.name == "Garden" && later.sortOrder == area.sortOrder + 1)
        let made = try #require(NewRecord.context(named: "Online", in: context))
        #expect(made.sortOrder == Double(Context.builtIn.count) && !made.isBuiltIn)
    }

    @Test func anItemIsMadeEmptyWhereItsAsked() throws {
        let area = try #require(NewRecord.area(named: "Work", in: context))
        let item = NewRecord.item(in: .action, scheduled: LocalDate(2026, 10, 23), area: area.id, in: context)
        #expect(item.title.isEmpty && item.bucket == .action && item.area === area)
        #expect(item.day(.scheduled) == LocalDate(2026, 10, 23))
        #expect(NewRecord.item(in: .inbox, in: context).area == nil)
    }

    @Test func aBlankNameMakesNothing() throws {
        #expect(NewRecord.area(named: "  ", in: context) == nil)
        #expect(NewRecord.context(named: "", in: context) == nil)
        #expect(try context.fetchCount(FetchDescriptor<Area>()) == 0)
    }
}
