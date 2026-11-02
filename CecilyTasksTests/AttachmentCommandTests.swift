import Foundation
import SwiftData
import Testing

@testable import CecilyTasks
@testable import TasksCore

/// Adding and deleting attachments, each a step that can be undone.
@MainActor
struct AttachmentCommandTests {
    let model: AppModel
    let undoManager = UndoManager()

    init() throws {
        model = try Store.open().get().model
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
    }

    func item(_ title: String, _ bucket: Bucket = .action) -> Item {
        let item = Item(title: title, bucket: bucket)
        model.context.insert(item)
        model.save()
        return item
    }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func step(_ change: () async -> Void) async {
        undoManager.beginUndoGrouping()
        await change()
        undoManager.endUndoGrouping()
    }

    @Test func addAttachmentAppliesToOneItemNotInTheTrash() {
        let a = item("A")
        let b = item("B")
        #expect(model.can(.addAttachment, [a]) && !model.can(.addAttachment, [a, b]))
        model.perform(.addAttachment, [a])
        #expect(model.attachingTo === a)
        model.perform(.trash, [b])
        #expect(!model.can(.addAttachment, [b]))
    }

    @Test func addingFilesIsOneStepThatCanBeUndone() async throws {
        let a = item("Kitchen")
        let photo = try file("Worktop.png", TestFiles.image(width: 600, height: 400))
        let quote = try file("Quote.pdf", TestFiles.pdf(lines: ["Quote"]))
        await step { await model.attach([photo, quote], to: a) }
        #expect(Set(a.attachmentsInOrder.map(\.filename)) == ["Worktop.png", "Quote.pdf"])
        #expect(a.attachmentsInOrder.first { $0.filename == "Worktop.png" }?.thumbnail != nil)
        #expect(undoManager.undoActionName == "Add Attachments")

        undoManager.undo()
        #expect(a.attachments?.isEmpty == true)
        undoManager.redo()
        #expect(a.attachments?.count == 2)
    }

    @Test func deletingOneCanBeUndone() async throws {
        let a = item("Kitchen")
        let url = try file("Quote.pdf", Data("quote".utf8))
        await step { await model.attach([url], to: a) }
        let quote = try #require(a.attachments?.first)
        await step { model.delete(quote) }
        #expect(a.attachments?.isEmpty == true)
        #expect(undoManager.undoActionName == "Delete Attachment")

        undoManager.undo()
        let back = try #require(a.attachments?.first)
        #expect(back.filename == "Quote.pdf" && back.data == Data("quote".utf8))
        undoManager.redo()
        #expect(a.attachments?.isEmpty == true)
    }

    @Test func aFileTooBigIsLeftOutAndSaidByName() async {
        let a = item("Kitchen")
        await step {
            await model.attach([PastedFile(name: "Film.mov", data: nil), PastedFile(name: "Note.txt", data: Data("hi".utf8))], to: a).value
        }
        #expect(a.attachments?.map(\.filename) == ["Note.txt"])
        #expect(model.attachmentProblem == AttachmentProblem(itemID: a.id, message: "“Film.mov” is bigger than 50 MB, so it wasn’t added."))
    }
}
