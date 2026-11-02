import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct OutsideSavesTests {
    let container: ModelContainer

    init() throws {
        container = try TasksSchema.container(at: nil)
    }

    private func save(_ title: String, author: String?) throws {
        let context = ModelContext(container)
        context.author = author
        context.insert(Item(title: title))
        try context.save()
    }

    @Test func onlyAnExtensionsSavesCount() throws {
        try save("Before", author: OutsideSaves.author)
        var saves = OutsideSaves(container)
        let atFirst = saves.check(container)
        try save("In the app", author: nil)
        try save("From sync", author: TasksSync.author)
        let afterTheApps = saves.check(container)
        try save("Shared", author: OutsideSaves.author)
        let afterAShare = saves.check(container)
        let again = saves.check(container)
        #expect(!atFirst && !afterTheApps && afterAShare && !again)
    }
}
