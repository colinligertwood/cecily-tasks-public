import Foundation
import OSLog
import Observation
import SwiftData
import SwiftUI
import TasksCore

/// An item's notes being edited, as Markdown: saved to the store half a second after typing
/// stops, before sync runs, and when the editor closes, so nothing typed is ever only on screen.
/// Notes for an item that isn't made yet make it the first time there's something to save.
@MainActor
@Observable
final class NoteDraft {
    static let saveDelay: Duration = .milliseconds(500)

    /// The item the notes are in, or nil until it's made.
    private(set) var itemID: UUID?
    var text: String {
        didSet {
            guard text != oldValue else { return }
            scheduleSave()
        }
    }
    /// Why the last save failed, if it did.
    private(set) var problem: String?

    @ObservationIgnored private let container: ModelContainer
    /// Makes the item, in the context it's given, when there's no `itemID`.
    @ObservationIgnored private let make: (@MainActor (ModelContext) -> Item)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hasUnsaved = false
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "com.ligertwood.cecily.tasks", category: "editing")

    init(container: ModelContainer, itemID: UUID) {
        self.container = container
        self.itemID = itemID
        make = nil
        text = Self.item(itemID, in: ModelContext(container))?.body ?? ""
        observeSync()
    }

    /// Notes for an item that `make` makes when there's first something to save.
    init(container: ModelContainer, making make: @escaping @MainActor (ModelContext) -> Item) {
        self.container = container
        itemID = nil
        self.make = make
        text = ""
        observeSync()
    }

    private func observeSync() {
        observer = NotificationCenter.default.addObserver(forName: .willSync, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isEmpty: Bool { text.isEmpty }

    private func scheduleSave() {
        hasUnsaved = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves now, if anything's changed since the last save.
    func save() {
        saveTask?.cancel()
        guard hasUnsaved else { return }
        let context = ModelContext(container)
        let item: Item
        if let itemID {
            guard let found = Self.item(itemID, in: context) else {
                problem = "This item was deleted, so what you typed can't be saved."
                return
            }
            item = found
        } else if let make {
            guard !text.isEmpty else {
                hasUnsaved = false
                return
            }
            item = make(context)
        } else {
            return
        }
        do {
            item.body = text
            item.modifiedAt = .now
            try context.save()
            itemID = item.id
            hasUnsaved = false
            problem = nil
        } catch {
            log.error("Couldn't save notes: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't save these notes. \(error.localizedDescription)"
        }
    }

    /// Reads the notes again after sync changed them, unless there's typing not saved yet, which
    /// will be saved over them.
    func reload() {
        guard !hasUnsaved, let itemID, let item = Self.item(itemID, in: ModelContext(container)) else { return }
        let stored = item.body
        guard stored != text else { return }
        text = stored
        saveTask?.cancel()
        hasUnsaved = false
    }

    private static func item(_ id: UUID, in context: ModelContext) -> Item? {
        try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }
}
