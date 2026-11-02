import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct AreasAndContextsTests {
    static let now = Date(timeIntervalSince1970: 2_000_000)
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        try TasksSchema.seed(context)
    }

    @Test func namesAndHidingSetModifiedAtOnlyOnAChange() throws {
        let area = Area(name: "Home")
        area.modifiedAt = .distantPast
        context.insert(area)
        area.setName("Home", at: Self.now)
        #expect(area.modifiedAt == .distantPast)
        area.setName("House", at: Self.now)
        #expect(area.name == "House" && area.modifiedAt == Self.now)
        let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
        calls.setHidden(false, at: Self.now)
        #expect(calls.modifiedAt != Self.now)
        calls.setHidden(true, at: Self.now)
        calls.setName("Phone", at: Self.now)
        #expect(calls.isHidden && calls.name == "Phone" && calls.modifiedAt == Self.now)
    }

    @Test func puttingInOrderNumbersAndMarksWhatMoved() {
        let areas = ["Home", "Work", "Health"].enumerated().map { index, name in
            let area = Area(name: name)
            area.sortOrder = Double(index)
            area.modifiedAt = .distantPast
            context.insert(area)
            return area
        }
        Area.putInOrder([areas[0], areas[2], areas[1]], at: Self.now)
        #expect(areas.map(\.sortOrder) == [0, 2, 1])
        #expect(areas[0].modifiedAt == .distantPast && areas[1].modifiedAt == Self.now)
    }

    @Test func deletingAnAreaKeepsItsProjectsAndItems() throws {
        let area = Area(name: "Home")
        context.insert(area)
        let project = context.insertProject("Kitchen")
        project.area = area
        let item = Item(title: "Fix the gate", bucket: .action)
        context.insert(item)
        item.area = area
        try context.save()
        area.delete(at: Self.now)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Area>()) == 0)
        #expect(project.area == nil && item.area == nil && item.modifiedAt == Self.now)
        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 2)
    }

    @Test func deletingAContextTakesItOffItsItemsButABuiltInStays() throws {
        let garden = Context(name: "Garden")
        context.insert(garden)
        let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
        let item = Item(title: "Plant bulbs", bucket: .action)
        context.insert(item)
        item.contexts = [garden, calls]
        try context.save()
        garden.delete(at: Self.now)
        calls.delete(at: Self.now)
        try context.save()
        #expect(item.contexts?.map(\.name) == ["Calls"] && item.modifiedAt == Self.now)
        #expect(try context.fetch(FetchDescriptor<Context>()).map(\.name).sorted() == Context.builtIn.map(\.name).sorted())
    }
}
