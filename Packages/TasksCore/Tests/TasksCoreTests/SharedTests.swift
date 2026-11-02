import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct SharedTests {
    let context: ModelContext

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
        try TasksSchema.seed(context)
    }

    @Test func itemsAreTheSameOrMixed() {
        let items = (0..<3).map { _ in Item(title: "Insurance", bucket: .action) }
        items.forEach(context.insert)
        #expect(Shared(items) { $0.day(.due) } == .same(nil))
        items[0].setDay(LocalDate(2026, 10, 23), for: .due)
        #expect(Shared(items) { $0.day(.due) } == .mixed)
        #expect(Shared([Item]()) { $0.title } == nil)
    }

    @Test func aContextIsSetOnEachWithoutToggling() throws {
        let calls = try #require(try context.fetch(FetchDescriptor<Context>()).first { $0.name == "Calls" })
        let items = (0..<2).map { _ in Item(title: "Insurance", bucket: .action) }
        items.forEach(context.insert)
        items[0].setContext(calls, true)
        for item in items { item.setContext(calls, true) }
        #expect(items.allSatisfy { $0.contexts?.map(\.name) == ["Calls"] })
        for item in items { item.setContext(calls, false) }
        #expect(items.allSatisfy { $0.contexts?.isEmpty == true })
    }
}
