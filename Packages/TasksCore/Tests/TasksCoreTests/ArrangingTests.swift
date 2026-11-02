import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Moving a list's rows from the keyboard: up and down among the rows beside them, into the row
/// above, and out of their task.
@MainActor
struct ArrangingTests {
    let container: ModelContainer
    let context: ModelContext
    /// A, B and C at the top, with B1, B2 and B3 under B.
    let items: [Item]

    init() throws {
        container = try TasksSchema.container(at: nil)
        context = ModelContext(container)
        let context = context
        func item(_ title: String, _ order: Int, under parent: Item? = nil) -> Item {
            let item = Item(title: title, bucket: .action)
            context.insert(item)
            item.parent = parent
            item.sortOrder = Double(order)
            return item
        }
        let b = item("B", 1)
        items = [item("A", 0), b, item("C", 2), item("B1", 0, under: b), item("B2", 1, under: b), item("B3", 2, under: b)]
    }

    var rows: [ListRow] { ListRow.rows(items.sorted(by: Item.inListOrder), doneSince: nil) }

    /// The rows as an outline: each title after a dash for each level it's nested.
    var outline: [String] { rows.map { String(repeating: "-", count: $0.depth) + $0.item.title } }

    func items(_ titles: [String]) -> [Item] {
        titles.map { title in items.first { $0.title == title }! }
    }

    @Test(
        arguments: [
            (["B"], .up, ["B", "-B1", "-B2", "-B3", "A", "C"]),
            (["A"], .up, nil),
            (["B"], .down, ["A", "C", "B", "-B1", "-B2", "-B3"]),
            (["C"], .down, nil),
            (["B2"], .up, ["A", "B", "-B2", "-B1", "-B3", "C"]),
            (["B2"], .down, ["A", "B", "-B1", "-B3", "-B2", "C"]),
            (["B1"], .up, nil),
            (["B3"], .down, nil),
            (["B1", "B2"], .down, ["A", "B", "-B3", "-B1", "-B2", "C"]),
            (["C"], .intoAbove, ["A", "B", "-B1", "-B2", "-B3", "-C"]),
            (["B2"], .intoAbove, ["A", "B", "-B1", "--B2", "-B3", "C"]),
            (["A"], .intoAbove, nil),
            (["B2"], .outOfTask, ["A", "B", "-B1", "-B3", "B2", "C"]),
            (["B1", "B2"], .outOfTask, ["A", "B", "-B3", "B1", "B2", "C"]),
            (["A"], .outOfTask, nil),
            (["A", "B1"], .up, nil),
        ] as [([String], Arrangement, [String]?)])
    func rowsMove(moving: [String], move: Arrangement, outline expected: [String]?) {
        let before = outline
        #expect(Clarifier.canArrange(items(moving), move, in: rows) == (expected != nil))
        let undo = Clarifier.arrange(items(moving), move, in: rows)
        #expect(outline == expected ?? before)
        if let undo {
            Clarifier.undo(undo, in: context)
            #expect(outline == before, "undone")
        }
    }

    @Test func aSubtaskComesOutUnderItsTasksTask() throws {
        _ = try #require(Clarifier.arrange(items(["B2"]), .intoAbove, in: rows))
        #expect(outline == ["A", "B", "-B1", "--B2", "-B3", "C"])
        _ = try #require(Clarifier.arrange(items(["B2"]), .outOfTask, in: rows))
        #expect(outline == ["A", "B", "-B1", "-B2", "-B3", "C"])
    }

    @Test func aRowAtTheTopComesOutOfItsTaskWhereItIs() throws {
        let outer = Item(title: "House", bucket: .action)
        context.insert(outer)
        let b = items(["B"])[0]
        b.parent = outer
        let shown = ListRow.rows(items(["A", "B1", "C"]), doneSince: nil)
        #expect(shown.allSatisfy { !$0.isSubItem })
        _ = try #require(Clarifier.arrange(items(["B1"]), .outOfTask, in: shown))
        #expect(items(["B1"])[0].parent === outer)
        _ = try #require(Clarifier.arrange(items(["B1"]), .outOfTask, in: shown))
        #expect(items(["B1"])[0].parent == nil)
        #expect(!Clarifier.canArrange(items(["B1"]), .outOfTask, in: shown))
        #expect(!Clarifier.canArrange(items(["A"]), .outOfTask, in: shown))
    }

    // MARK: A list in parts

    /// A, B, C and D in that order, in two parts: A and C, and B and D.
    func parts() -> (items: [Item], sections: [[ListRow]]) {
        let made = ["A", "B", "C", "D"].enumerated().map { index, title in
            let item = Item(title: title, bucket: .action)
            context.insert(item)
            item.sortOrder = Double(index)
            return item
        }
        return (made, [ListRow.rows([made[0], made[2]], doneSince: nil), ListRow.rows([made[1], made[3]], doneSince: nil)])
    }

    func order(_ items: [Item]) -> [String] {
        items.sorted(by: Item.inListOrder).map(\.title)
    }

    @Test func aListsOrderHasEachItemOnce() {
        let (items, sections) = parts()
        #expect(ListRow.order(sections + [sections[0]]).map(\.title) == ["A", "B", "C", "D"])
        #expect(order(items) == ["A", "B", "C", "D"])
    }

    @Test func aRowDroppedInOnePartKeepsTheOtherPartsOrder() throws {
        let (items, sections) = parts()
        _ = try #require(Clarifier.place([items[3]], at: 0, in: sections[1], of: sections))
        #expect(order(items) == ["A", "D", "B", "C"])
    }

    @Test func aRowDroppedAtAPartsEndGoesJustAfterItsLast() throws {
        let (items, sections) = parts()
        _ = try #require(Clarifier.place([items[1]], at: 2, in: sections[0], of: sections))
        #expect(order(items) == ["A", "C", "B", "D"])
    }

    @Test func aRowMovedDownInOnePartKeepsTheOtherPartsOrder() throws {
        let (items, sections) = parts()
        _ = try #require(Clarifier.arrange([items[0]], .down, in: sections[0], order: ListRow.order(sections)))
        #expect(order(items) == ["B", "C", "A", "D"])
    }

    // MARK: Actions' groups

    @Test func aRowDroppedInAnotherContextChangesContext() {
        let calls = Context(name: "Calls")
        let errands = Context(name: "Errands")
        let home = Context(name: "Home")
        [calls, errands, home].forEach(context.insert)
        let item = items(["A"])[0]
        item.contexts = [calls, home]
        #expect(Clarifier.regroup([item], from: .context(calls), to: .context(errands)))
        #expect(Set((item.contexts ?? []).map(\.name)) == ["Errands", "Home"])
        #expect(!Clarifier.regroup([item], from: .context(errands), to: .context(errands)), "already there")
        #expect(Clarifier.regroup([item], from: .context(home), to: .noContext))
        #expect((item.contexts ?? []).isEmpty)
    }

    @Test func aRowDroppedInAnotherAreaOrTaskMovesThere() {
        let home = Area(name: "Home")
        context.insert(home)
        let item = items(["A"])[0]
        let task = items(["B"])[0]
        #expect(Clarifier.regroup([item], from: .noArea, to: .area(home)))
        #expect(item.area === home)
        #expect(Clarifier.regroup([item], from: .area(home), to: .noArea))
        #expect(item.area == nil)
        #expect(Clarifier.regroup([item], from: .noProject, to: .project(task)))
        #expect(item.parent === task)
        #expect(Clarifier.regroup([item], from: .project(task), to: .noProject))
        #expect(item.parent == nil)
    }

    @Test func aRowDroppedInAnotherReferenceGroupTakesItsAreaAndTask() {
        let home = Area(name: "Home")
        context.insert(home)
        let item = items(["A"])[0]
        let task = items(["B"])[0]
        let from = ReferenceGroup(area: nil, project: nil, items: [item]).dropGroup
        let to = ReferenceGroup(area: home, project: task, items: []).dropGroup
        #expect(Clarifier.regroup([item], from: from, to: to))
        #expect(item.area === home && item.parent === task)
        #expect(!Clarifier.regroup([item], from: to, to: DropGroup(id: "a day", headings: [])), "a group with nothing to give")
    }
}
