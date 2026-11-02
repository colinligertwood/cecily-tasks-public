import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct SomedayListTests {
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

    func project(_ title: String, _ bucket: Bucket = .someday, area: Area? = nil, order: Double = 0) -> Item {
        let project = item(title, area: area, order: order)
        project.bucket = bucket
        return project
    }

    func item(_ title: String, area: Area? = nil, project: Item? = nil, order: Double = 0) -> Item {
        let item = Item(title: title, bucket: .someday)
        item.sortOrder = order
        context.insert(item)
        item.area = area
        item.parent = project
        return item
    }

    func groups(_ items: [Item], doneSince: Date? = nil) -> [SomedayGroup] {
        SomedayList.groups(items, today: Self.today, doneSince: doneSince)
    }

    @Test func groupedByAreaInTheAreasOrderWithNoAreaLast() {
        let home = area("Home", order: 1)
        let family = area("Family", order: 0)
        let items = [project("Sourdough", area: home), project("Allotment"), item("Pottery"), item("Lisbon", area: family), item("Sail", area: home)]
        let groups = groups(items)
        #expect(groups.map(\.area?.name) == ["Family", "Home", nil])
        #expect(groups.map { Set($0.items.map(\.title)) } == [["Lisbon"], ["Sourdough", "Sail"], ["Allotment", "Pottery"]])
    }

    @Test func anItemWithNoAreaIsInItsProjectsArea() {
        let home = area("Home", order: 0)
        let kitchen = project("Kitchen", .action, area: home)
        #expect(groups([item("Wine fridge", project: kitchen)]).map(\.area?.name) == ["Home"])
    }

    @Test func eachGroupIsInTheListsOrder() {
        let items = [item("Moved down", order: 1), item("Older"), item("Newer"), project("Project", order: 2)]
        items[2].createdAt = items[1].createdAt.addingTimeInterval(60)
        #expect(groups(items).first?.items.map(\.title) == ["Newer", "Older", "Moved down", "Project"])
    }

    @Test func onlySomedayItemsShowingToday() {
        let open = item("Sail")
        let hidden = item("Hidden")
        hidden.hideUntil = Self.today.adding(days: 3).storedDate
        let action = item("Action")
        action.bucket = .action
        let activeProject = project("Active project", .action)
        let step = item("Step")
        step.parent = open
        let dayStart = Date(timeIntervalSince1970: 2_000_000)
        let doneToday = item("Done today")
        doneToday.markDone(at: dayStart.addingTimeInterval(60))
        let doneBefore = item("Done before")
        doneBefore.markDone(at: dayStart.addingTimeInterval(-60))
        let items = [open, hidden, action, activeProject, step, doneToday, doneBefore]
        #expect(Set(groups(items, doneSince: dayStart).flatMap(\.items).map(\.title)) == ["Sail", "Done today"])
    }

    @Test(arguments: [
        (ItemStatus.open, Bucket.action, true), (.open, .someday, false), (.done, .action, false), (.dropped, .action, false), (.open, .trash, false),
    ])
    func itemsUnderATaskShowWhileItsActive(status: ItemStatus, bucket: Bucket, shown: Bool) {
        let kitchen = project("Kitchen", bucket)
        kitchen.status = status
        let item = item("Wine fridge", project: kitchen)
        #expect(groups([item]).flatMap(\.items).isEmpty == !shown)
    }

    @Test func itemsInAHiddenProjectAreHidden() {
        let kitchen = project("Kitchen", .action)
        kitchen.hideUntil = Self.today.adding(days: 1).storedDate
        #expect(groups([item("Wine fridge", project: kitchen)]).isEmpty)
    }

    @Test func activateMovesItemsToActionsAndMakesProjectsActive() throws {
        let kitchen = project("Kitchen", .action)
        let moving = item("Wine fridge", project: kitchen)
        let sourdough = project("Sourdough")
        try context.save()
        let undo = try #require(Clarifier.activate([moving, sourdough]))
        #expect(moving.bucket == .action && moving.project === kitchen && moving.isInActions(today: Self.today))
        #expect(sourdough.isActive)
        Clarifier.undo(undo, in: context)
        #expect(moving.bucket == .someday && sourdough.bucket == .someday && moving.project === kitchen)
        moving.bucket = .waiting
        #expect(Clarifier.activate([moving]) == nil)
    }

    @Test func activatingAnItemActivatesItsSomedayProject() throws {
        let sourdough = project("Sourdough")
        let basket = item("Buy a proving basket", project: sourdough)
        let flour = item("Find rye flour", project: sourdough)
        try context.save()
        let undo = try #require(Clarifier.activate([basket, flour]))
        #expect(sourdough.isActive && basket.isInActions(today: Self.today) && flour.isInActions(today: Self.today))
        Clarifier.undo(undo, in: context)
        #expect(sourdough.bucket == .someday && basket.bucket == .someday && flour.bucket == .someday)
    }
}
