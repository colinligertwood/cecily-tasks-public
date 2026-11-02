import Foundation
import SwiftData

@testable import TasksCore

extension ModelContext {
    /// Inserts a task named `title` in Actions, to give subtasks, with one subtask when
    /// `withSubtask`, so it's a project.
    @discardableResult
    func insertProject(_ title: String, withSubtask: Bool = false) -> Item {
        let project = Item(title: title, bucket: .action)
        insert(project)
        if withSubtask {
            let subtask = Item(title: "First step of \(title)", bucket: .action)
            insert(subtask)
            subtask.parent = project
        }
        return project
    }
}

extension Item {
    /// Open in Actions' place.
    var isActive: Bool { status == .open && bucket == .action }
}
