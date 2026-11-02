import Foundation
import SwiftData
import TasksCore

extension AppModel {
    /// Registers the decisions' undos with the undo manager, as one step named `name`. Undoing it
    /// registers the redo.
    func register(_ undos: [Clarifier.Undo], named name: String) {
        guard let undoManager, !undos.isEmpty else { return }
        undoManager.beginUndoGrouping()
        for undo in undos { register(undo, named: name, with: undoManager) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    private func register(_ undo: Clarifier.Undo, named name: String, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { model in
            let redo = undo.current(in: model.context)
            Clarifier.undo(undo, in: model.context)
            model.save()
            if let redo { model.register(redo, named: name, with: undoManager) }
            undoManager.setActionName(name)
        }
    }

    /// Makes a change to items, with one of their setters, and saves it, as one step named `name`
    /// that can be undone. Items the change leaves as they were aren't part of it.
    func edit(_ items: [Item], named name: String, _ change: (Item) -> Void) {
        let undos = items.map { item in (item, item.modifiedAt, Clarifier.Undo([item], title: item.title)) }
        items.forEach(change)
        save()
        register(undos.filter { $0.0.modifiedAt != $0.1 }.map(\.2), named: name)
    }
}
