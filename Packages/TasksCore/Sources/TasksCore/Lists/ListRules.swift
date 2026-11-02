import Foundation

// What puts an item in a list on a given day. `today` is the day from
// `DayBoundary`, and `doneSince` the moment it started: items done since then stay in their
// lists, struck through, until the next day starts. Subtasks are listed by themselves.

extension Item {
    /// Hidden until a day after `today`, or under a task that is.
    public func isHidden(today: LocalDate) -> Bool {
        if hideUntil.map({ LocalDate(day: $0) > today }) ?? false { return true }
        return parent?.isHidden(today: today) ?? false
    }

    /// Open, or done since `doneSince`. Nil for open only.
    public func isCurrent(doneSince: Date?) -> Bool {
        switch status {
        case .open: true
        case .done: doneSince.map { (completedAt ?? .distantPast) >= $0 } ?? false
        case .dropped: false
        }
    }

    /// Scheduled for a day after `today`.
    public func isScheduledLater(today: LocalDate) -> Bool {
        scheduledDate.map { LocalDate(day: $0) > today } ?? false
    }

    /// An open task with subtasks, out of the trash, which items can be put under.
    public var isOpenProject: Bool { isProject && status == .open && bucket != .trash }

    /// Under a task that takes its subtasks out of every list: one on Someday or in the trash,
    /// dropped, or done before `doneSince` (any that's done, when it's nil).
    public func isInGoneProject(doneSince: Date? = nil) -> Bool {
        ancestors.contains {
            $0.bucket == .someday || $0.bucket == .trash || $0.status == .dropped || ($0.status == .done && !$0.isCurrent(doneSince: doneSince))
        }
    }

    /// Whether the item is shown in a list on `today`: open or done since `doneSince`, not hidden
    /// unless `showsHidden`, and not under a task that's gone.
    public func isListed(today: LocalDate, doneSince: Date?, showsHidden: Bool = false) -> Bool {
        isCurrent(doneSince: doneSince) && (showsHidden || !isHidden(today: today)) && !isInGoneProject(doneSince: doneSince)
    }

    /// Whether one of its subtasks is a next step on `today`: open, and in Actions or Waiting or
    /// starting on a later day.
    public func hasNextStep(today: LocalDate) -> Bool {
        (children ?? []).contains { $0.status == .open && ($0.bucket == .action || $0.bucket == .waiting || $0.isScheduledLater(today: today)) }
    }

    /// Whether the item is in Actions on `today`: an action, open or
    /// done since `doneSince`, listed, not scheduled for a later day, and with no subtask that's a
    /// next step; under a task that's One at a Time, only on its first open subtask's branch.
    public func isInActions(today: LocalDate, doneSince: Date? = nil, showsHidden: Bool = false) -> Bool {
        guard bucket == .action, kind == .action, isListed(today: today, doneSince: doneSince, showsHidden: showsHidden) else { return false }
        guard !isScheduledLater(today: today), !hasNextStep(today: today) else { return false }
        guard status == .open else { return true }
        var branch = self
        for parent in ancestors {
            if parent.isSequential, parent.openSubtasks.first?.id != branch.id { return false }
            branch = parent
        }
        return true
    }

    /// Stalled: an open task in Actions' place with subtasks, none of which is a next
    /// step. It's in Actions itself, with no next action.
    public func isStalled(today: LocalDate) -> Bool {
        status == .open && bucket == .action && isProject && !hasNextStep(today: today)
    }

    /// Its open subtasks in Actions' place, in their order.
    public var openSubtasks: [Item] {
        (children ?? [])
            .filter { $0.status == .open && $0.bucket == .action }
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
    }
}
