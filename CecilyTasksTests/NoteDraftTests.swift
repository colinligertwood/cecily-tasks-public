import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import CecilyTasks
@testable import TasksCore

/// Notes are Markdown, saved as they're typed.
@MainActor
struct NoteDraftTests {
    let container: ModelContainer
    let itemID: UUID

    init() throws {
        container = try TasksSchema.container(at: nil)
        let context = ModelContext(container)
        let item = Item(title: "Call the insurer")
        context.insert(item)
        try context.save()
        itemID = item.id
    }

    func saved() throws -> Item? {
        let id = itemID
        return try ModelContext(container).fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }

    @Test func notesTypedAndLeftAreThereWhenTheyOpenAgain() throws {
        let draft = NoteDraft(container: container, itemID: itemID)
        draft.text = "**Policy** 1234"
        draft.save()
        let reopened = NoteDraft(container: container, itemID: itemID)
        #expect(reopened.text == "**Policy** 1234")
        #expect(try saved()?.body == "**Policy** 1234" && saved()?.title == "Call the insurer")
    }

    @Test func typingIsSavedSoonAfterItStops() async throws {
        let draft = NoteDraft(container: container, itemID: itemID)
        draft.text = "Ask about the excess"
        #expect(try saved()?.body == "")
        try await Task.sleep(for: NoteDraft.saveDelay + .milliseconds(300))
        #expect(try saved()?.body == "Ask about the excess")
    }

    @Test func syncingSavesWhatsBeingTypedFirst() throws {
        let draft = NoteDraft(container: container, itemID: itemID)
        draft.text = "Typed just before Sync Now"
        NotificationCenter.default.post(name: .willSync, object: nil)
        #expect(try saved()?.body == "Typed just before Sync Now")
    }

    @Test func aChangeFromSyncShowsUnlessTypingIsUnsaved() throws {
        let draft = NoteDraft(container: container, itemID: itemID)
        let context = ModelContext(container)
        let item = try #require(try context.fetch(FetchDescriptor<Item>()).first)
        item.body = "**from** the iPhone"
        try context.save()
        draft.reload()
        #expect(draft.text == "**from** the iPhone")
        draft.text = "typing here"
        item.body = "from the iPhone again"
        try context.save()
        draft.reload()
        #expect(draft.text == "typing here")
    }
}

/// An event's notes, which make the note in Reference linked to it the first time there's
/// something to save.
@MainActor
struct EventNoteDraftTests {
    let container: ModelContainer
    let event = CalendarEvent(
        id: "noor-0", title: "1:1 with Noor", start: .now, end: .now.addingTimeInterval(1800), isAllDay: false, calendarID: "work",
        reach: .always, seriesID: "noor", isRecurring: true, in: .current)

    init() throws {
        container = try TasksSchema.container(at: nil)
    }

    func draft() -> NoteDraft {
        NoteDraft(container: container) { [event] context in AgendaEvents.newMeetingNote(for: event, in: context).note }
    }

    func items() throws -> [Item] {
        try ModelContext(container).fetch(FetchDescriptor<Item>())
    }

    @Test func theFirstSaveMakesTheEventsNote() throws {
        let draft = draft()
        #expect(draft.itemID == nil)
        draft.text = "Ask about the offsite"
        draft.save()
        let all = try items()
        #expect(all.count == 1)
        let note = try #require(all.first)
        #expect(note.title == "1:1 with Noor" && note.bucket == .reference && note.kind == .note)
        #expect(note.calendarEventID == "noor" && note.body == "Ask about the offsite")
        #expect(draft.itemID == note.id && note.id == AgendaEvents.noteID(for: "noor"))
    }

    @Test func laterSavesWriteToTheSameNote() throws {
        let draft = draft()
        draft.text = "Ask about the offsite"
        draft.save()
        draft.text = "Ask about the offsite and the budget"
        draft.save()
        #expect(try items().map(\.body) == ["Ask about the offsite and the budget"])
    }

    @Test func nothingTypedMakesNothing() throws {
        let draft = draft()
        draft.text = "a"
        draft.text = ""
        draft.save()
        NotificationCenter.default.post(name: .willSync, object: nil)
        #expect(try items().isEmpty && draft.itemID == nil)
    }
}

/// The Mac app's sandbox: outgoing connections, which WebKit needs, and no incoming ones.
struct SandboxTests {
    @Test func theMacAppIsSandboxedWithOutgoingConnectionsOnly() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "CecilyTasks.entitlements")
        let entitlements = try #require(NSDictionary(contentsOf: file) as? [String: Any])
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.client"] as? Bool == true, "WebKit needs it to show an event's notes")
        #expect(entitlements["com.apple.security.network.server"] == nil)
    }
}
