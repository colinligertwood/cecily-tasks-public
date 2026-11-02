import Foundation
import SwiftData
import TasksCore

extension AppModel {
    /// Puts the trashed items back where they came from, with their subtasks, as one decision
    /// that can be undone.
    func putBack(_ items: [Item]) {
        edit(items.filter { $0.bucket == .trash }, named: "Put Back") { TrashList.putBack($0) }
    }

    /// Deletes everything in the Trash for good.
    func emptyTrash() {
        TrashList.empty(in: context)
        selection = []
        save()
    }

    /// Deletes what was trashed more than 30 days ago.
    func deleteOldTrash() {
        if TrashList.deleteOld(in: context) > 0 { save() }
    }
}
