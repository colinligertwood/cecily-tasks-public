import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct SharedItemTests {
    let page = URL(string: "https://www.example.com/guides/insurance/")!
    let photo = SharedItem.File(name: "Receipt.jpeg", contentType: "public.jpeg", data: Data([1, 2, 3]))

    @Test func aPageIsTitledByItsTitleWithTheLinkInTheNotes() throws {
        let shared = try SharedItem.read(link: page, pageTitle: " Renewing home insurance ", text: page.absoluteString)
        #expect(shared.title == "Renewing home insurance" && shared.text.isEmpty)
        #expect(shared.notes == "<\(page.absoluteString)>")
    }

    @Test func textSharedWithAPageGoesAboveTheLink() throws {
        let shared = try SharedItem.read(link: page, pageTitle: "Renewing home insurance", text: "Check the excess")
        #expect(shared.notes == "Check the excess\n\n<\(page.absoluteString)>")
    }

    @Test(arguments: [
        ("https://www.example.com/guides/insurance/", "example.com/guides/insurance"),
        ("https://example.com", "example.com"),
        ("message:%3C1234@example.com%3E", "message:%3C1234@example.com%3E"),
    ])
    func aLinkWithoutATitleIsTitledByWhereItGoes(link: String, title: String) throws {
        let url = try #require(URL(string: link))
        #expect(try SharedItem.read(link: url).title == title)
        #expect(try SharedItem.read(link: url, text: link).title == title)
    }

    @Test func textsFirstLineIsTheTitleAndTheRestTheNotes() throws {
        let shared = try SharedItem.read(text: "  Call the plumber \n\nAbout the leak\nunder the sink\n")
        #expect(shared.title == "Call the plumber" && shared.text == "About the leak\nunder the sink")
        #expect(try SharedItem.read(text: "One line @calls due:fri").title == "One line @calls due:fri")
    }

    @Test func aFileIsTitledByItsName() throws {
        let shared = try SharedItem.read(file: photo)
        #expect(shared.title == "Receipt" && shared.notes.isEmpty)
        #expect(try SharedItem.read(text: "For the tax return", file: photo).title == "For the tax return")
    }

    @Test func aFileOverTheLimitIsRefused() {
        let large = SharedItem.File(name: "Video.mov", contentType: "com.apple.quicktime-movie", data: Data(count: SharedItem.largestFile + 1))
        #expect(throws: SharedItem.Problem.tooLarge) { try SharedItem.read(file: large) }
        let largest = SharedItem.File(name: "Video.mov", contentType: "com.apple.quicktime-movie", data: Data(count: SharedItem.largestFile))
        #expect(throws: Never.self) { try SharedItem.read(file: largest) }
    }

    @Test func nothingReadableIsRefused() {
        #expect(throws: SharedItem.Problem.nothing) { try SharedItem.read() }
        #expect(throws: SharedItem.Problem.nothing) { try SharedItem.read(text: "  \n ") }
    }

    @Test func itsAddedToTheInboxAsSharedWithItsFile() throws {
        let context = ModelContext(try TasksSchema.container(at: nil))
        let item = try SharedItem.read(text: "For the tax return", file: photo).add(to: context)
        try context.save()
        #expect(item.bucket == .inbox && item.source == .share && item.title == "For the tax return")
        let attachment = try #require(item.attachments?.first)
        #expect(attachment.filename == "Receipt.jpeg" && attachment.contentType == "public.jpeg" && attachment.byteSize == 3)
    }
}
