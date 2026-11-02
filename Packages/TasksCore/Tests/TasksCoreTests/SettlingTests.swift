import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Rows just put under a task, shown nested under it while they settle.
@MainActor
struct SettlingTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
    }

    func item(_ title: String, under parent: Item? = nil) -> Item {
        let item = Item(title: title, bucket: .action)
        context.insert(item)
        item.parent = parent
        return item
    }

    /// Each part's rows as an outline: each title after a dash for each level it's nested.
    func outline(_ sections: [[ListRow]]) -> [[String]] {
        sections.map { $0.map { String(repeating: "-", count: $0.depth) + $0.item.title } }
    }

    @Test func aRowInAnotherPartIsNestedUnderTheTask() {
        let task = item("Paint the shed")
        let moved = item("Buy brushes", under: task)
        let step = item("Measure", under: moved)
        let other = item("Call Sam")
        let sections = [
            [ListRow(item: task), ListRow(item: other)],
            [ListRow(item: moved, under: nil), ListRow(item: step, depth: 1, under: moved)],
        ]
        let settled = ListRow.settling(sections, under: task.id, moved: [moved.id])
        #expect(outline(settled) == [["Paint the shed", "-Buy brushes", "--Measure", "Call Sam"], []])
        #expect(settled[0][1].under === task)
    }

    @Test func aRowShownInSeveralPartsIsNestedOnce() {
        let task = item("Paint the shed")
        let moved = item("Buy brushes", under: task)
        let sections = [[ListRow(item: moved)], [ListRow(item: task)], [ListRow(item: moved)]]
        #expect(outline(ListRow.settling(sections, under: task.id, moved: [moved.id])) == [[], ["Paint the shed", "-Buy brushes"], []])
    }

    @Test func aRowAlreadyUnderTheTaskStays() {
        let task = item("Paint the shed")
        let first = item("Sand", under: task)
        let moved = item("Buy brushes", under: task)
        let sections = [[ListRow(item: task), ListRow(item: first, depth: 1, under: task), ListRow(item: moved, depth: 1, under: task)]]
        #expect(ListRow.settling(sections, under: task.id, moved: [moved.id]) == sections)
    }

    @Test func nothingMovesWithoutTheTasksRowOrOnceUndone() {
        let task = item("Paint the shed")
        let moved = item("Buy brushes", under: task)
        let loose = item("Call Sam")
        let sections = [[ListRow(item: moved)], [ListRow(item: loose)]]
        #expect(ListRow.settling(sections, under: task.id, moved: [moved.id]) == sections)
        let withTask = [[ListRow(item: task)], [ListRow(item: loose)]]
        #expect(ListRow.settling(withTask, under: task.id, moved: [loose.id]) == withTask, "not under the task")
    }
}
