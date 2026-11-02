import SwiftUI
import TasksCore

/// Rows just put under a task, and what Edit ▸ Undo calls the move.
struct Settling: Equatable {
    let task: UUID
    let moved: Set<UUID>
    let name: String
}

extension AppModel {
    /// How long rows put under a task are shown nested under it.
    static let settlingTime: Duration = .seconds(4)

    /// Shows `moved`, selected, nested under `task` in every list for a few seconds, with the task
    /// kept where it was, then lets the lists settle, with animation.
    func settle(_ moved: [Item], under task: Item, named name: String) {
        settlingEnd?.cancel()
        withAnimation {
            settling = Settling(task: task.id, moved: Set(moved.map(\.id)), name: name)
            selection = Set(moved.map(\.id))
        }
        settlingEnd = Task { [weak self] in
            try? await Task.sleep(for: Self.settlingTime)
            guard !Task.isCancelled else { return }
            withAnimation { self?.settling = nil }
        }
    }

    /// Undoes the move whose rows are settling, when it's still the last thing done, and lets
    /// the lists settle.
    func undoSettling() {
        settlingEnd?.cancel()
        withAnimation {
            if let settling, undoManager?.undoActionName == settling.name { undoManager?.undo() }
            settling = nil
        }
    }

    /// A list's rows by part as they show while rows settle under a task.
    func settled(_ sections: [[ListRow]]) -> [[ListRow]] {
        guard let settling else { return sections }
        return ListRow.settling(sections, under: settling.task, moved: settling.moved)
    }

    /// The task to keep in its list while rows settle under it.
    var keptWhileSettling: Set<UUID> {
        settling.map { [$0.task] } ?? []
    }
}
