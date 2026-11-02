import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct ReferenceListTests {
    static let today = LocalDate(2026, 10, 21)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
    }

    func area(_ name: String, order: Double) -> Area {
        let area = Area(name: name)
        area.sortOrder = order
        context.insert(area)
        return area
    }

    func project(_ title: String, area: Area? = nil, order: Double = 0) -> Item {
        let project = Item(title: title, bucket: .action)
        project.sortOrder = order
        context.insert(project)
        project.area = area
        return project
    }

    func note(_ title: String, area: Area? = nil, project: Item? = nil, order: Double = 0) -> Item {
        let item = Item(title: title, bucket: .reference)
        item.kind = .note
        item.sortOrder = order
        context.insert(item)
        item.area = area
        item.parent = project
        return item
    }

    func groups(_ items: [Item], doneSince: Date? = nil) -> [ReferenceGroup] {
        ReferenceList.groups(items, today: Self.today, doneSince: doneSince)
    }

    func names(_ groups: [ReferenceGroup]) -> [String] {
        groups.map { "\($0.area?.name ?? "-")/\($0.project?.title ?? "-")" }
    }

    @Test func groupedByAreaThenProjectWithNoProjectFirstAndNoAreaLast() {
        let home = area("Home", order: 1)
        let family = area("Family", order: 0)
        let kitchen = project("Kitchen", area: home, order: 1)
        let shed = project("Shed", area: home, order: 0)
        let errands = project("Errands")
        let items = [
            note("Worktop", project: kitchen), note("Manual"), note("Router", area: home), note("Packing", area: family),
            note("Tip opening hours", project: shed), note("Shopping", project: errands), note("Tool list", project: shed),
        ]
        let groups = groups(items)
        #expect(names(groups) == ["Family/-", "Home/-", "Home/Shed", "Home/Kitchen", "-/-", "-/Errands"])
        #expect(
            groups.map { Set($0.items.map(\.title)) } == [
                ["Packing"], ["Router"], ["Tip opening hours", "Tool list"], ["Worktop"], ["Manual"], ["Shopping"],
            ])
    }

    @Test func anItemsOwnAreaComesBeforeItsProjects() {
        let home = area("Home", order: 0)
        let family = area("Family", order: 1)
        let kitchen = project("Kitchen", area: home)
        #expect(names(groups([note("Recipes", area: family, project: kitchen)])) == ["Family/Kitchen"])
    }

    @Test func eachGroupIsInTheListsOrder() {
        let items = [note("Moved down", order: 1), note("Older"), note("Newer")]
        items[2].createdAt = items[1].createdAt.addingTimeInterval(60)
        #expect(groups(items).first?.items.map(\.title) == ["Newer", "Older", "Moved down"])
    }

    @Test func referenceAndNotesAmongActionsShowingToday() {
        let filed = note("Router")
        let actionNote = note("Measurements")
        actionNote.bucket = .action
        let action = note("Call Sam")
        action.bucket = .action
        action.kind = .action
        let someday = note("Someday")
        someday.bucket = .someday
        let hidden = note("Hidden")
        hidden.hideUntil = Self.today.adding(days: 1).storedDate
        let sub = note("Subtask")
        sub.parent = filed
        let dayStart = Date(timeIntervalSince1970: 2_000_000)
        let doneToday = note("Done today")
        doneToday.markDone(at: dayStart.addingTimeInterval(60))
        let doneBefore = note("Done before")
        doneBefore.markDone(at: dayStart.addingTimeInterval(-60))
        let items = [filed, actionNote, action, someday, hidden, sub, doneToday, doneBefore]
        #expect(Set(groups(items, doneSince: dayStart).flatMap(\.items).map(\.title)) == ["Router", "Measurements", "Subtask", "Done today"])
    }

    @Test func itemsInAHiddenProjectAreHidden() {
        let kitchen = project("Kitchen")
        kitchen.hideUntil = Self.today.adding(days: 1).storedDate
        #expect(groups([note("Worktop", project: kitchen)]).isEmpty)
    }
}
