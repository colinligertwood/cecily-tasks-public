import Foundation
import ImageIO
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct AttachmentTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "AttachmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ name: String, size: Int) throws -> URL {
        let url = folder.appending(path: name)
        #expect(FileManager.default.createFile(atPath: url.path(), contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    @Test func aFileIsReadWithItsNameAndType() throws {
        let url = folder.appending(path: "Receipt.pdf")
        try TestFiles.pdf(lines: ["Receipt"]).write(to: url)
        let file = try AttachedFile.read(url)
        let data = try Data(contentsOf: url)
        #expect(file.name == "Receipt.pdf" && file.contentType == "com.adobe.pdf" && file.data == data)
    }

    @Test func aFileOverTheLimitIsRefusedBeforeItsRead() throws {
        let large = try file("Video.mov", size: AttachedFile.largest + 1)
        #expect(throws: AttachedFile.Problem.tooLarge("Video.mov")) { try AttachedFile.read(large) }
        #expect(try AttachedFile.read(try file("Largest.mov", size: AttachedFile.largest)).data.count == AttachedFile.largest)
        #expect(throws: AttachedFile.Problem.tooLarge("Data.bin")) {
            try AttachedFile(name: "Data.bin", contentType: "public.data", data: Data(count: AttachedFile.largest + 1))
        }
        #expect(AttachedFile.message(for: AttachedFile.Problem.tooLarge("Video.mov")) == "“Video.mov” is bigger than 50 MB, so it wasn’t added.")
    }

    @Test func attachingKeepsTheFileOnTheItemInTheOrderAdded() throws {
        let context = ModelContext(try TasksSchema.container(at: nil))
        let item = Item(title: "Kitchen")
        context.insert(item)
        let first = item.attach(try AttachedFile(name: "Quote.pdf", contentType: "com.adobe.pdf", data: Data([1, 2])))
        first.createdAt = .now.addingTimeInterval(-60)
        item.attach(try AttachedFile(name: "Photo.png", contentType: "public.png", data: Data([3]), thumbnail: Data([4])))
        try context.save()
        #expect(item.attachmentsInOrder.map(\.filename) == ["Quote.pdf", "Photo.png"])
        let photo = try #require(item.attachmentsInOrder.last)
        #expect(photo.byteSize == 1 && photo.thumbnail == Data([4]) && photo.isImage && !first.isImage)
    }

    @Test func aDeletedAttachmentIsPutBackOnItsItem() throws {
        let context = ModelContext(try TasksSchema.container(at: nil))
        let item = Item(title: "Kitchen")
        context.insert(item)
        let attachment = item.attach(try AttachedFile(name: "Photo.png", contentType: "public.png", data: Data([3]), thumbnail: Data([4])))
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        attachment.createdAt = created
        try context.save()
        let kept = try #require(attachment.kept)
        context.delete(attachment)
        try context.save()
        #expect(item.attachments?.isEmpty == true)

        let back = try #require(kept.putBack(in: context))
        try context.save()
        #expect(item.attachments?.count == 1 && back.item === item)
        #expect(back.filename == "Photo.png" && back.contentType == "public.png" && back.data == Data([3]) && back.thumbnail == Data([4]))
        #expect(back.createdAt == created && back.byteSize == 1)

        context.delete(item)
        try context.save()
        #expect(kept.putBack(in: context) == nil)
    }

    @Test func itsFileIsWrittenOnceUnderItsID() throws {
        let context = ModelContext(try TasksSchema.container(at: nil))
        let item = Item(title: "Kitchen")
        context.insert(item)
        let attachment = item.attach(try AttachedFile(name: "Plans/v2.txt", contentType: "public.plain-text", data: Data("one".utf8)))
        let url = try attachment.writeFile(in: folder)
        #expect(url.lastPathComponent == "Plans-v2.txt" && url.deletingLastPathComponent().lastPathComponent == attachment.id.uuidString)
        attachment.data = Data("two".utf8)
        #expect(try attachment.writeFile(in: folder) == url)
        #expect(try Data(contentsOf: url) == Data("one".utf8))
    }

    @Test(arguments: [
        ("Photo.png", TestFiles.image(width: 1200, height: 800)),
        ("Quote.pdf", TestFiles.pdf(lines: ["Fitwell Kitchens: quote"])),
    ])
    func aThumbnailIsMadeNoBiggerThanItsSize(name: String, data: Data) async throws {
        let url = folder.appending(path: name)
        try data.write(to: url)
        let thumbnail = try #require(await Thumbnail.make(for: url))
        let image = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(max(image.width, image.height) <= Int(Thumbnail.size) * 2)
        #expect(max(image.width, image.height) > 0)
    }

    @Test func anImagesDataIsMadeSmallerToShow() throws {
        let data = TestFiles.image(width: 1200, height: 800)
        let image = try #require(Thumbnail.image(from: data, pixels: 300))
        #expect(image.width == 300 && image.height == 200)
        #expect(Thumbnail.image(from: Data("not an image".utf8), pixels: 300) == nil)
    }
}
