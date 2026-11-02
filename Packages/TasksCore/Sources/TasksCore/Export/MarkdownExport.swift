import Foundation
import SwiftData

/// Items as Markdown, to read elsewhere: an item's title as a heading, its details as a short
/// list, its subtasks as a checklist, then its notes. A list is its open items the same way under
/// the list's name.
public enum MarkdownExport {
    /// One item, with its title as the top heading.
    public static func markdown(for item: Item, calendar: Calendar = .current) -> String {
        section(item, level: 1, calendar: calendar)
    }

    /// The open items of a list, under its name.
    public static func markdown(list title: String, items: [Item], calendar: Calendar = .current) -> String {
        var parts = ["# \(title)"]
        parts += topLevel(items).map { section($0, level: 2, calendar: calendar) }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// An item's open subtasks as a checklist, the subtasks' own open subtasks indented under them.
    public static func openSubtasks(of item: Item) -> String {
        checklist(item, depth: 0, openOnly: true).joined(separator: "\n")
    }

    /// A file name for `title`, safe for any file system.
    public static func filename(for title: String) -> String {
        let name = FullExport.safeFilename(title.trimmingCharacters(in: .whitespacesAndNewlines))
        return (name == "file" ? "Untitled" : name) + ".md"
    }

    /// The full export's Markdown files, by their paths in the export's folder: one for each list
    /// but the Trash, and one for each area, in `Areas/`, with its items by list.
    static func files(_ context: ModelContext, calendar: Calendar) throws -> [String: String] {
        let items = try context.fetch(FetchDescriptor<Item>()).filter { $0.status == .open }
        var files: [String: String] = [:]
        for bucket in Bucket.allCases where bucket != .trash {
            files[filename(for: bucket.title)] = markdown(
                list: bucket.title, items: items.filter { $0.bucket == bucket }, calendar: calendar)
        }
        for area in try context.fetch(FetchDescriptor<Area>()) {
            var parts = ["# \(area.name)"]
            for bucket in Bucket.allCases where bucket != .trash {
                let inArea = topLevel(items.filter { $0.bucket == bucket && ($0.area ?? $0.project?.area)?.id == area.id })
                guard !inArea.isEmpty else { continue }
                parts.append("## \(bucket.title)")
                parts += inArea.map { section($0, level: 3, calendar: calendar) }
            }
            var path = "Areas/" + filename(for: area.name)
            if files[path] != nil { path = "Areas/" + filename(for: "\(area.name) \(area.recordName.prefix(8))") }
            files[path] = parts.joined(separator: "\n\n") + "\n"
        }
        return files
    }

    /// The items not under another of `items`, in their order.
    private static func topLevel(_ items: [Item]) -> [Item] {
        let ids = Set(items.map(\.id))
        return items.filter { $0.parent.map { !ids.contains($0.id) } ?? true }.sorted(by: inOrder)
    }

    private static func inOrder(_ a: Item, _ b: Item) -> Bool {
        (a.sortOrder, a.createdAt) < (b.sortOrder, b.createdAt)
    }

    private static func section(_ item: Item, level: Int, calendar: Calendar) -> String {
        let title = item.title.isEmpty ? "Untitled" : item.title
        var parts = [String(repeating: "#", count: level) + " " + title]
        let details = details(of: item, calendar: calendar)
        if !details.isEmpty { parts.append(details.map { "- \($0)" }.joined(separator: "\n")) }
        let subtasks = checklist(item, depth: 0, openOnly: false)
        if !subtasks.isEmpty { parts.append(subtasks.joined(separator: "\n")) }
        let notes = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append(notes) }
        return parts.joined(separator: "\n\n")
    }

    private static func details(of item: Item, calendar: Calendar) -> [String] {
        var details: [String] = []
        if item.status == .done, let completed = item.completedAt { details.append("Done: \(LocalDate(completed, in: calendar))") }
        if let area = item.area { details.append("Area: \(area.name)") }
        let contexts = (item.contexts ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.name)
        if !contexts.isEmpty { details.append("Contexts: \(contexts.joined(separator: ", "))") }
        if let person = item.waitingOn, !person.isEmpty { details.append("Waiting for: \(person)") }
        if let day = item.day(.followUp) { details.append("Follow up: \(day)") }
        if let day = item.day(.due) { details.append("Due: \(day)") }
        if let day = item.day(.scheduled) {
            let time = item.scheduledTime.map { " " + $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar)) } ?? ""
            details.append("Scheduled: \(day)\(time)")
        }
        if let day = item.day(.hideUntil) { details.append("Hide until: \(day)") }
        if let estimate = item.timeEstimate { details.append("Time: \(estimate.rawValue)") }
        if let energy = item.energy { details.append("Energy: \(energy.rawValue)") }
        if let repetition = item.repeatRule {
            let text = repetition.naturalText.isEmpty ? ((try? Recurrence(rrule: repetition.rrule))?.summary ?? "Yes") : repetition.naturalText
            details.append("Repeats: \(text)")
        }
        let files = (item.attachments ?? []).sorted { $0.createdAt < $1.createdAt }.map(\.filename)
        if !files.isEmpty { details.append("Attachments: \(files.joined(separator: ", "))") }
        return details
    }

    private static func checklist(_ item: Item, depth: Int, openOnly: Bool) -> [String] {
        let children = (item.children ?? [])
            .filter { $0.bucket != .trash && $0.status != .dropped && (!openOnly || $0.status == .open) }
            .sorted(by: inOrder)
        return children.flatMap { child in
            let box = child.status == .done ? "[x]" : "[ ]"
            let line = String(repeating: "  ", count: depth) + "- \(box) \(child.title)"
            return [line] + checklist(child, depth: depth + 1, openOnly: openOnly)
        }
    }
}
