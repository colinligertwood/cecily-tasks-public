import Foundation
import SwiftData
import Testing

@testable import TasksCore

/// Finding items by the words in their titles, notes and attachments' file names.
@MainActor
struct ItemSearchTests {
    let context: ModelContext

    init() throws {
        context = ModelContext(try TasksSchema.container(at: nil))
    }

    @discardableResult
    func item(_ title: String, _ bucket: Bucket = .action, notes: String = "", file: String? = nil, modifiedDaysAgo: Double = 0) -> Item {
        let item = Item(title: title, bucket: bucket)
        context.insert(item)
        item.body = notes
        item.modifiedAt = Date(timeIntervalSinceReferenceDate: 800_000_000 - modifiedDaysAgo * 86400)
        if let file {
            let attachment = TasksCore.Attachment(filename: file, contentType: "com.adobe.pdf", data: Data([1]))
            context.insert(attachment)
            attachment.item = item
        }
        return item
    }

    var all: [Item] { (try? context.fetch(FetchDescriptor<Item>())) ?? [] }

    func titles(_ query: String, filter: ItemSearch.Filter = ItemSearch.Filter()) -> Set<String> {
        Set(ItemSearch.results(all, query: query, filter: filter).flatMap { $0.results.map(\.item.title) })
    }

    func fill() {
        item("Dentist appointment")
        item("Renew passport", .someday, notes: "Needs a **photo** from the booth at the station")
        item("Café receipts", .reference, file: "Tax-Return 2026.pdf")
        item("Call the plumber", .waiting, notes: "- [ ] ask about the boiler")
        item("Plan the garden", .inbox, notes: "See [the seed catalogue](https://example.com/seeds)")
    }

    @Test(arguments: [
        ("dent", ["Dentist appointment"]),
        ("dent appo", ["Dentist appointment"]),
        ("appo dent", ["Dentist appointment"]),
        ("DENTIST", ["Dentist appointment"]),
        ("ntist", []),
        ("dentist plumber", []),
        ("cafe", ["Café receipts"]),
        ("photo", ["Renew passport"]),
        ("renew booth", ["Renew passport"]),
        ("tax return", ["Café receipts"]),
        ("2026", ["Café receipts"]),
        ("pdf", ["Café receipts"]),
        ("boiler", ["Call the plumber"]),
        ("seed catalogue", ["Plan the garden"]),
        ("example", []),
        ("https", []),
        ("the", ["Renew passport", "Call the plumber", "Plan the garden"]),
        ("   ", []),
        ("**", []),
    ])
    func findsByTheStartsOfWords(query: String, expected: [String]) {
        fill()
        #expect(titles(query) == Set(expected))
    }

    @Test func leavesOutTheTrashAndDropped() {
        item("Old dentist")
        let trashed = item("Dentist in the trash")
        Clarifier.file(trashed, ClarifyOutcome(.trash), today: LocalDate(2026, 10, 28))
        item("Dropped dentist").status = .dropped
        item("Done dentist").status = .done
        #expect(titles("dentist") == ["Old dentist", "Done dentist"])
    }

    @Test func groupsByListInTheListsOrder() {
        item("Garden ideas", .reference)
        item("Garden shed", .someday)
        item("Garden gate", .action)
        item("Garden hose", .inbox)
        item("Garden centre", .waiting)
        let groups = ItemSearch.results(all, query: "garden")
        #expect(groups.map(\.bucket) == [.inbox, .action, .waiting, .someday, .reference])
    }

    @Test func putsOpenFirstThenTheMostRecentlyChanged() {
        item("Bike lights", modifiedDaysAgo: 5)
        item("Bike pump", modifiedDaysAgo: 1).status = .done
        item("Bike lock", modifiedDaysAgo: 2)
        item("Bike bell", modifiedDaysAgo: 9).status = .done
        let found = ItemSearch.results(all, query: "bike").flatMap { $0.results.map(\.item.title) }
        #expect(found == ["Bike lock", "Bike lights", "Bike pump", "Bike bell"])
    }

    @Test func filtersByStatusContextAndAttachments() {
        let calls = Context(name: "Calls")
        context.insert(calls)
        item("Book the boiler service").contexts = [calls]
        item("Boiler manual", .reference, file: "boiler.pdf")
        item("Boiler fixed").status = .done
        #expect(titles("boiler", filter: ItemSearch.Filter(status: .open)) == ["Book the boiler service", "Boiler manual"])
        #expect(titles("boiler", filter: ItemSearch.Filter(status: .done)) == ["Boiler fixed"])
        #expect(titles("boiler", filter: ItemSearch.Filter(context: calls.id)) == ["Book the boiler service"])
        #expect(titles("boiler", filter: ItemSearch.Filter(hasAttachments: true)) == ["Boiler manual"])
        #expect(!ItemSearch.Filter().isOn && ItemSearch.Filter(status: .done).isOn)
    }

    @Test func keepsOnlyWhatTheListKeeps() {
        item("Garden gate")
        item("Garden shed", .someday)
        let found = ItemSearch.results(all, query: "garden") { $0.bucket == .someday }
        #expect(found.flatMap { $0.results.map(\.item.title) } == ["Garden shed"])
    }

    @Test func showsTheNotesWhereTheyMatchAndTheTitleDoesNot() {
        let item = item("Renew passport", notes: "Needs a **photo** from the booth at the station, and the old passport")
        let found = { (query: String) in ItemSearch.results(self.all, query: query).first?.results.first }
        #expect(found("renew")?.item === item)
        #expect(found("renew")?.excerpt == nil)
        #expect(found("passport")?.excerpt == nil)
        #expect(found("needs")?.excerpt == "Needs a photo from the booth at the station, and the old passport")
        #expect(found("booth")?.excerpt == "…photo from the booth at the station, and the old passport")
        #expect(found("renew station")?.excerpt == "…booth at the station, and the old passport")
    }

    @Test func remembersTheLastTenSearches() {
        var recent: [String] = []
        for query in ["dentist", " boiler ", "", "Dentist"] {
            recent = RecentSearches.adding(query, to: recent)
        }
        #expect(recent == ["Dentist", "boiler"])
        for number in 1...12 {
            recent = RecentSearches.adding("search \(number)", to: recent)
        }
        #expect(recent.count == 10 && recent.first == "search 12" && recent.last == "search 3")
    }
}
