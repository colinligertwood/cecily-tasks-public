import Foundation
import SwiftData
import TasksCore

extension AppModel {
    /// Files an item, as a decision that can be undone.
    func file(_ item: Item, _ outcome: ClarifyOutcome) {
        file([item], outcome)
    }

    /// Files each item the same way, as one decision that can be undone.
    func file(_ items: [Item], _ outcome: ClarifyOutcome) {
        guard !items.isEmpty else { return }
        let undos = items.map { Clarifier.file($0, outcome, today: today) }
        save()
        register(undos, named: Self.undoName(of: outcome.destination))
    }

    /// Starts the items today, as one decision that can be undone. Those that can't start today
    /// are left as they are.
    func startToday(_ items: [Item]) {
        start(items, on: today)
    }

    /// Starts the items on `day`, as one decision that can be undone: "Schedule for Today", or "Change
    /// Start Date" for another day. Those that can't be started are left as they are.
    func start(_ items: [Item], on day: LocalDate) {
        let name = day == today ? "Schedule for Today" : "Change Scheduled Date"
        edit(items.filter(\.canStart), named: name) { $0.start(on: day, in: .current) }
    }

    /// Starts dragged rows on `day`. False when none of them can be started.
    @discardableResult
    func start(dragged payloads: [String], on day: LocalDate) -> Bool {
        let starting = items(dragged: payloads).filter(\.canStart)
        guard !starting.isEmpty else { return false }
        start(starting, on: day)
        selection = []
        return true
    }

    /// Marks the items done, or open again when they all are. Each stays where it is, struck
    /// through while done, until the next day starts. A repeating item makes its next copy when
    /// it's done, and opening it again takes the copy back.
    func toggleDone(_ items: [Item]) {
        let (reopened, undo) = Clarifier.toggleDone(items, today: today, in: context)
        guard reopened || undo != nil else { return }
        save()
        if let undo {
            register([undo], named: "Mark as Done")
        } else if let undoManager {
            undoManager.registerUndo(withTarget: self) { model in model.toggleDone(items) }
            undoManager.setActionName("Mark as Not Done")
        }
    }
}
