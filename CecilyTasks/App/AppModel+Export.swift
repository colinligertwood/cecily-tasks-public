import Foundation
import SwiftData
import TasksCore

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// What's being exported, while the save panel is open.
enum ExportRequest {
    /// Everything, as a folder.
    case all(URL)
    /// An item or a list, as a Markdown file.
    case markdown(name: String, text: String)
}

extension AppModel {
    /// The item Export as Markdown exports: the open item, or the one selected.
    var markdownItem: Item? {
        guard let id = openItem ?? (selection.count == 1 ? selection.first : nil) else { return nil }
        return try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }

    /// The list a page shows, if it's one that exports as Markdown.
    static func markdownBucket(_ page: Page) -> Bucket? {
        switch page {
        case .inbox: .inbox
        case .actions: .action
        case .waiting: .waiting
        case .someday: .someday
        case .reference: .reference
        case .agenda, .trash: nil
        }
    }

    var canExportMarkdown: Bool { markdownItem != nil || Self.markdownBucket(page) != nil }

    /// Opens the save panel for the open or selected item as Markdown, or else the list showing.
    func exportMarkdown() {
        if let item = markdownItem {
            exportMarkdown(item)
        } else {
            exportMarkdown(list: page)
        }
    }

    /// Opens the save panel for a page's list as Markdown, with its open items in the area chosen.
    func exportMarkdown(list page: Page) {
        if let bucket = Self.markdownBucket(page) {
            let raw = bucket.rawValue
            let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.bucketRaw == raw && $0.statusRaw == "open" }))) ?? []
            let shown = items.filter { area == nil || ($0.area ?? $0.project?.area)?.id == area }
            let title = bucket.title
            exporting = .markdown(name: title, text: MarkdownExport.markdown(list: title, items: shown))
        }
    }

    func exportMarkdown(_ item: Item) {
        exporting = .markdown(name: item.title, text: MarkdownExport.markdown(for: item))
    }

    /// Writes everything to a folder in the temporary folder, in place of the last export there,
    /// and opens the save panel for it.
    func exportAll() {
        let exports = FileManager.default.temporaryDirectory.appending(path: "Export", directoryHint: .isDirectory)
        let folder = exports.appending(path: "Cecily Tasks backup \(LocalDate(.now, in: .current))", directoryHint: .isDirectory)
        do {
            try? FileManager.default.removeItem(at: exports)
            try FullExport.write(context, to: folder)
            exporting = .all(folder)
        } catch {
            exportProblem = "Couldn’t back up your tasks. \(error.localizedDescription)"
        }
    }

    /// Reads an export into the store, which has to have nothing in it yet.
    func restore(from folder: URL) {
        let isScoped = folder.startAccessingSecurityScopedResource()
        defer { if isScoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            try FullExport.restore(from: folder, into: context)
            refreshToday()
            refreshReview()
            updateNotifications()
            let count = (try? context.fetchCount(FetchDescriptor<Item>())) ?? 0
            exportProblem = nil
            restored = count
        } catch {
            context.rollback()
            exportProblem = error.localizedDescription
        }
    }

    /// Copies an item's open subtasks to the clipboard as a Markdown checklist.
    func copyOpenSubtasks(of item: Item) {
        let text = MarkdownExport.openSubtasks(of: item)
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}
