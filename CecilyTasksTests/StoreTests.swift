import Foundation
import SwiftData
import Testing

@testable import CecilyTasks
@testable import TasksCore

@MainActor
struct StoreTests {
    @Test func underTestsTheStoreIsInMemoryWithItsBuiltIns() throws {
        let store = try Store.open().get()
        let context = ModelContext(store.model.container)
        #expect(try context.fetchCount(FetchDescriptor<Context>()) == Context.builtIn.count)
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 1)
        #expect(store.model.container.configurations.first?.isStoredInMemoryOnly == true)
    }

    @Test func syncStaysOffInABuildThatCantUseICloud() throws {
        let store = try Store.open().get()
        #expect(!CloudSync.canUseICloud)
        store.model.cloudSync.start()
        #expect(!store.model.cloudSync.isOn)
        #expect(!TasksSync.isSyncing(store.model.container))
    }
}

/// What the screens do through the app's model: capture, filing, and undo.
@MainActor
struct AppModelTests {
    let model: AppModel
    let undoManager = UndoManager()

    init() throws {
        model = try Store.open().get().model
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
    }

    @Test func captureSavesEachLineToTheInbox() throws {
        #expect(model.capture("Buy milk\nCall the bank @calls") == 2)
        let saved = try ModelContext(model.container).fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.createdAt)]))
        #expect(saved.map(\.title) == ["Buy milk", "Call the bank"])
        #expect(saved[1].contexts?.map(\.name) == ["Calls"])
        #expect(model.inbox().count == 2)
    }

    @Test func emptyCaptureAddsNothing() {
        #expect(model.capture("  \n\n") == 0 && model.inbox().isEmpty)
    }

    @Test func filingIsSavedAndCanBeUndoneAndRedone() throws {
        model.capture("Insurance")
        let item = try #require(model.inbox().first)
        model.file(item, ClarifyOutcome(.someday))
        #expect(model.inbox().isEmpty && undoManager.canUndo && undoManager.undoActionName == "File in Someday")
        let id = item.id
        let saved = try ModelContext(model.container).fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
        #expect(saved?.bucket == .someday)
        undoManager.undo()
        #expect(model.inbox().map(\.title) == ["Insurance"] && !undoManager.canUndo)
        #expect(undoManager.canRedo && undoManager.redoActionName == "File in Someday")
        undoManager.redo()
        #expect(model.inbox().isEmpty && item.bucket == .someday)
    }

    @Test func filingSeveralIsOneStep() throws {
        model.capture("Insurance\nPassport")
        model.file(model.inbox(), ClarifyOutcome(.reference))
        #expect(model.inbox().isEmpty)
        undoManager.undo()
        #expect(model.inbox().count == 2 && !undoManager.canUndo)
    }

    @Test func theLastTenDecisionsCanBeUndoneInTurn() throws {
        model.capture((1...10).map { "Item \($0)" }.joined(separator: "\n"))
        for item in model.inbox() { model.file(item, ClarifyOutcome(.someday)) }
        #expect(model.inbox().isEmpty)
        for count in 1...10 {
            undoManager.undo()
            #expect(model.inbox().count == count)
        }
    }

    @Test func doneCanBeUndone() throws {
        model.capture("Insurance")
        let item = try #require(model.inbox().first)
        model.toggleDone([item])
        #expect(item.status == .done && undoManager.undoActionName == "Mark as Done")
        undoManager.undo()
        #expect(item.status == .open && item.completedAt == nil)
    }

    @Test func aChangeToADetailCanBeUndone() throws {
        model.capture("Insurance")
        let item = try #require(model.inbox().first)
        model.edit([item], named: ItemField.due.undoName) { $0.setDay(LocalDate(2026, 11, 2), for: .due) }
        #expect(item.dueDate != nil && undoManager.undoActionName == "Change Due Date")
        undoManager.undo()
        #expect(item.dueDate == nil)
        model.edit([item], named: ItemField.due.undoName) { $0.setDay(nil, for: .due) }
        #expect(!undoManager.canUndo, "a change that changes nothing isn't a step")
    }

    @Test func theInboxIsOldestFirst() throws {
        model.capture("first")
        model.capture("second")
        #expect(model.inbox().map(\.title) == ["first", "second"])
    }
}
