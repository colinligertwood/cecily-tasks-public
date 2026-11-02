import Foundation
import SwiftData
import Testing

@testable import TasksCore

@MainActor
struct NoteLinksTests {
    let context: ModelContext

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
    }

    func item(_ title: String, _ bucket: Bucket = .action, modified: TimeInterval = 0) -> Item {
        let item = Item(title: title, bucket: bucket)
        item.modifiedAt = Date(timeIntervalSinceReferenceDate: modified)
        context.insert(item)
        return item
    }

    @Test func aLinkIsReadFromItsURL() {
        let id = UUID()
        #expect(NoteLink(NoteLink.item(id).url) == .item(id))
        #expect(NoteLink(NoteLink.area(id).url) == .area(id))
        #expect(NoteLink("cecily-tasks://item/\(id.uuidString.lowercased())") == .item(id))
        #expect(NoteLink("cecily-tasks://item/not-an-id") == nil)
        #expect(NoteLink("cecily-tasks://list/\(id.uuidString)") == nil)
        #expect(NoteLink("https://example.com/item/\(id.uuidString)") == nil)
    }

    @Test(arguments: [
        ("Dentist", "[Dentist](cecily-tasks://x)"),
        ("Plan [draft]", "[Plan \\[draft\\]](cecily-tasks://x)"),
        ("", "[cecily-tasks://x](cecily-tasks://x)"),
    ])
    func markdown(_ title: String, _ expected: String) {
        #expect(NoteLink.markdown(title: title, url: "cecily-tasks://x") == expected)
    }

    @Test func targetsMatchWordStartsInAnyOrder() {
        let dentist = item("Dentist appointment", modified: 2)
        _ = item("Book the plumber", modified: 3)
        let done = item("Dental records", .reference, modified: 5)
        done.status = .done
        let trashed = item("Dentist bill", .trash)
        let area = Area(name: "Dental")
        context.insert(area)

        let found = NoteLink.targets(matching: "dent", items: [dentist, done, trashed], areas: [area])
        #expect(found.map(\.link) == [.area(area.id), .item(dentist.id), .item(done.id)])
        #expect(found.map(\.place) == ["Area", "Actions", "Reference"])
        #expect(NoteLink.targets(matching: "appo DENT", items: [dentist], areas: []).map(\.link) == [.item(dentist.id)])
        #expect(NoteLink.targets(matching: "dent", items: [dentist], areas: [], excluding: dentist.id).isEmpty)
    }

    @Test func withNoWordsTheLatestOpenItemsAreOffered() {
        let older = item("Older", modified: 1)
        let newer = item("Newer", modified: 9)
        let done = item("Done", modified: 10)
        done.status = .done
        let found = NoteLink.targets(matching: "", items: [older, newer, done], areas: [], limit: 5)
        #expect(found.map(\.title) == ["Newer", "Older"])
    }

    @Test func titlesAreTheTargetsCurrentOnes() {
        let renamed = item("New name")
        let trashed = item("Old thing", .trash)
        let area = Area(name: "Home")
        let missing = UUID()
        let urls = [
            NoteLink.item(renamed.id).url, NoteLink.item(trashed.id).url, NoteLink.area(area.id).url, NoteLink.item(missing).url,
            "https://example.com",
        ]
        let titles = NoteLink.titles(
            for: urls, items: [renamed.id: renamed, trashed.id: trashed], areas: [area.id: area])
        #expect(titles[urls[0]]?.title == "New name")
        #expect(titles[urls[0]]?.isGone == false)
        #expect(titles[urls[1]]?.isGone == true)
        #expect(titles[urls[2]]?.title == "Home")
        #expect(titles[urls[3]]?.title == nil)
        #expect(titles[urls[3]]?.isGone == true)
        #expect(titles[urls[4]] == nil)
    }

    @Test(arguments: [
        ("https://example.com/a?b=c", true),
        ("  http://example.com  ", true),
        ("https://example.com and more", false),
        ("example.com", false),
        ("mailto:someone@example.com", false),
        ("", false),
    ])
    func pastedURLs(_ text: String, _ isURL: Bool) {
        #expect((WebLinkTitle.pastedURL(text) != nil) == isURL)
    }

    @Test(arguments: [
        ("<html><head><title>  Swift &amp; You\n</title></head></html>", "Swift & You"),
        ("<meta property=\"og:title\" content=\"Fancy &#8211; title\"><title>Plain</title>", "Fancy – title"),
        ("<meta content=\"Reversed\" property='og:title'>", "Reversed"),
        ("<TITLE>Caps &#x27;n&#x27; all</TITLE>", "Caps 'n' all"),
        ("<title>   </title>", nil),
        ("<p>No title</p>", nil),
    ])
    func titlesFromHTML(_ html: String, _ title: String?) {
        #expect(WebLinkTitle.title(fromHTML: html) == title)
    }

    @Test func aFetchedTitleUsesTheLoader() async {
        let url = URL(string: "https://example.com")!
        let title = await WebLinkTitle.fetchTitle(url) { _ in Data("<title>Example Domain</title>".utf8) }
        #expect(title == "Example Domain")
        let failed = await WebLinkTitle.fetchTitle(url) { _ in throw URLError(.timedOut) }
        #expect(failed == nil)
    }
}
