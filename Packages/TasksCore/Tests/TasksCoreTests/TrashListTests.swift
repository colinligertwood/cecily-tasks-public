import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// What's in the Trash, putting it back where it came from, and deleting it.
@MainActor
struct TrashListTests {
    static let today = LocalDate(2026, 10, 26)
    static let now = today.date(in: .current, hour: 12)
    let context: ModelContext

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
    }

    func item(_ title: String, _ bucket: Bucket = .action, under parent: Item? = nil) -> Item {
        let item = Item(title: title, bucket: bucket)
        context.insert(item)
        item.parent = parent
        return item
    }

    func trash(_ item: Item, daysAgo: Double = 0) {
        Clarifier.file(item, ClarifyOutcome(.trash), today: Self.today)
        item.trashedAt = Self.now.addingTimeInterval(-daysAgo * 86400)
    }

    var all: [Item] { (try? context.fetch(FetchDescriptor<Item>())) ?? [] }

    @Test(arguments: [Bucket.inbox, .action, .waiting, .someday, .reference])
    func anItemIsPutBackWhereItCameFrom(bucket: Bucket) throws {
        let item = item("Old broadband offer", bucket)
        trash(item)
        #expect(item.bucket == .trash && item.trashedFrom == bucket && TrashList.destination(of: item) == bucket)
        TrashList.putBack(item, at: Self.now)
        #expect(item.bucket == bucket && item.trashedFrom == nil && item.trashedAt == nil)
    }

    @Test func oneTrashedBeforeWhereItCameFromWasKeptGoesToTheInbox() {
        let item = item("Old broadband offer", .trash)
        #expect(TrashList.destination(of: item) == .inbox)
        TrashList.putBack(item, at: Self.now)
        #expect(item.bucket == .inbox)
    }

    @Test func trashingAgainKeepsWhereItCameFrom() {
        let item = item("Old broadband offer", .someday)
        trash(item, daysAgo: 3)
        let trashedAt = item.trashedAt
        Clarifier.file(item, ClarifyOutcome(.trash), today: Self.today)
        #expect(item.trashedFrom == .someday && item.trashedAt == trashedAt)
    }

    @Test func filingItOutOfTheTrashForgetsWhereItCameFrom() {
        let item = item("Old broadband offer", .someday)
        trash(item)
        Clarifier.file(item, ClarifyOutcome(.reference), today: Self.today)
        #expect(item.bucket == .reference && item.trashedFrom == nil && item.trashedAt == nil)
    }

    @Test func undoingTheTrashPutsItBack() throws {
        let item = item("Old broadband offer", .waiting)
        let undo = Clarifier.file(item, ClarifyOutcome(.trash), today: Self.today)
        #expect(Clarifier.undo(undo, in: context))
        #expect(item.bucket == .waiting && item.trashedFrom == nil && item.trashedAt == nil)
    }

    @Test func aTrashedTaskIsPutBackWithItsSubtasks() {
        let fence = item("Repaint the fence")
        let paint = item("Buy fence paint", under: fence)
        trash(fence)
        #expect(!paint.isListed(today: Self.today, doneSince: nil))
        TrashList.putBack(fence, at: Self.now)
        #expect(paint.bucket == .action && paint.isListed(today: Self.today, doneSince: nil))
    }

    @Test func theTrashIsMostRecentlyTrashedFirstWithSubtasksUnderTheirTask() {
        let older = item("Old broadband offer", .someday)
        let fence = item("Repaint the fence")
        let paint = item("Buy fence paint", under: fence)
        let sand = item("Sand down the old paint", under: fence)
        let skip = item("Hire a skip", under: fence)
        skip.status = .dropped
        _ = item("Book the boiler service")
        trash(older, daysAgo: 5)
        trash(fence, daysAgo: 1)
        sand.sortOrder = 1
        let rows = ListRow.rows(TrashList.items(all), doneSince: nil)
        #expect(rows.map(\.item.title) == [fence, paint, sand, older].map(\.title))
        #expect(rows.map(\.depth) == [0, 1, 1, 0])
    }

    @Test func whatWasTrashedMoreThan30DaysAgoIsDeletedWithItsSubtasks() throws {
        let old = item("Repaint the fence")
        _ = item("Buy fence paint", under: old)
        let recent = item("Old broadband offer", .someday)
        let kept = item("Book the boiler service")
        trash(old, daysAgo: 31)
        trash(recent, daysAgo: 29)
        try context.save()
        #expect(TrashList.deleteOld(in: context, at: Self.now) == 1)
        try context.save()
        #expect(Set(all.map(\.title)) == [recent.title, kept.title])
    }

    @Test func emptyingTheTrashDeletesEverythingInIt() throws {
        let fence = item("Repaint the fence")
        _ = item("Buy fence paint", under: fence)
        trash(fence)
        trash(item("Old broadband offer", .someday), daysAgo: 10)
        _ = item("Book the boiler service")
        try context.save()
        #expect(TrashList.empty(in: context) == 2)
        try context.save()
        #expect(all.map(\.title) == ["Book the boiler service"])
    }
}
