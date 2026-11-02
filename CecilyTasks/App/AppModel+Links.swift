import Foundation
import SwiftData
import TasksCore

extension AppModel: NoteLinking {
    func linkTargets(matching query: String, excluding: UUID?) -> [NoteLink.Target] {
        let items = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        let areas = (try? context.fetch(FetchDescriptor<Area>())) ?? []
        return NoteLink.targets(matching: query, items: items, areas: areas, excluding: excluding)
    }

    func linkTitles(_ urls: [String]) -> [String: (title: String?, isGone: Bool)] {
        let ids = urls.compactMap { url -> UUID? in
            if case .item(let id) = NoteLink(url) { id } else { nil }
        }
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let areas = (try? context.fetch(FetchDescriptor<Area>())) ?? []
        return NoteLink.titles(
            for: urls, items: Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            areas: Dictionary(areas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Opens a linked item over the list, or narrows the lists to a linked area. A link to
    /// something gone opens nothing.
    func open(_ link: NoteLink) {
        switch link {
        case .item(let id):
            guard let item = try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first, item.bucket != .trash else {
                return
            }
            openItem = id
        case .area(let id):
            guard (try? context.fetchCount(FetchDescriptor<Area>(predicate: #Predicate { $0.id == id }))) ?? 0 > 0 else { return }
            area = id
        }
    }
}
