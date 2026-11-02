import CryptoKit
import Foundation
import SwiftData

/// The copies a repeating item makes when it's done: one open copy at a time,
/// with the repeat moving on to it.
public enum RepeatCopies {
    /// Makes the next copy of `item`, done on `closedOn`, and moves its repeat to the copy, with
    /// one fewer remaining when there's a limit. The copy has the item's details and subtasks,
    /// open, and its dates moved on to the rule's next date: the start day, due date and
    /// follow-up date all by the same number of days, or a start day of the next date when it had
    /// none; its subtasks' dates move by as many days. It's hidden until `showDaysBefore` days
    /// before that date. Nil when the item doesn't repeat, its
    /// repeat has ended, or the copy is there already.
    @MainActor
    @discardableResult
    public static func makeNext(after item: Item, closedOn: LocalDate, in context: ModelContext, at now: Date = .now) -> Item? {
        guard let repetition = item.repeatRule, let rule = repetition.rule, find(item.nextCopyID, in: context) == nil else { return nil }
        let base = item.day(.scheduled) ?? item.day(.due) ?? closedOn
        guard let next = rule.nextDate(after: base, closedOn: closedOn, seriesStart: base) else { return nil }
        let shift = base.days(to: next)
        let copy = copied(item, shift: shift, in: context, at: now)
        copy.id = item.nextCopyID
        copy.parent = item.parent
        let hadDate = item.scheduledDate != nil || item.dueDate != nil || item.followUpDate != nil
        if !hadDate { copy.scheduledDate = next.storedDate }
        copy.hideUntil = rule.hideUntil(for: next)?.storedDate
        repetition.rule = rule.advanced()
        repetition.item = copy
        repetition.modifiedAt = now
        return copy
    }

    /// Takes back the copy made when `item` was done, while it's still open, giving the repeat back
    /// to `item`. True when there was one to take back.
    @MainActor
    @discardableResult
    public static func takeBack(after item: Item, in context: ModelContext, at now: Date = .now) -> Bool {
        guard let copy = find(item.nextCopyID, in: context), copy.status == .open else { return false }
        if let repetition = copy.repeatRule, var rule = repetition.rule {
            rule.remainingCount = rule.remainingCount.map { $0 + 1 }
            repetition.rule = rule
            repetition.item = item
            repetition.modifiedAt = now
        }
        context.delete(copy)
        return true
    }

    /// A copy of `item` and its subtasks, open, in the same place, with their dates `shift` days on.
    @MainActor
    private static func copied(_ item: Item, shift: Int, in context: ModelContext, at now: Date) -> Item {
        let copy = Item(title: item.title, bucket: item.bucket)
        copy.createdAt = now
        copy.modifiedAt = now
        copy.body = item.body
        copy.kind = item.kind
        copy.sortOrder = item.sortOrder
        copy.source = item.source
        copy.waitingOn = item.waitingOn
        copy.scheduledDate = item.day(.scheduled)?.adding(days: shift).storedDate
        copy.scheduledTime = item.scheduledTime.map { Calendar.current.date(byAdding: .day, value: shift, to: $0) ?? $0 }
        copy.dueDate = item.day(.due)?.adding(days: shift).storedDate
        copy.followUpDate = item.day(.followUp)?.adding(days: shift).storedDate
        copy.timeEstimate = item.timeEstimate
        copy.energy = item.energy
        copy.isSequential = item.isSequential
        context.insert(copy)
        copy.area = item.area
        copy.contexts = item.contexts
        for subtask in item.children ?? [] where subtask.bucket != .trash && subtask.status != .dropped {
            copied(subtask, shift: shift, in: context, at: now).parent = copy
        }
        return copy
    }

    @MainActor
    private static func find(_ id: UUID, in context: ModelContext) -> Item? {
        try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.id == id })).first
    }
}

extension Item {
    /// The ID of the copy that follows this one in its repeat: the same on every device, so two
    /// devices that both see it done make one copy between them.
    public var nextCopyID: UUID {
        UUID(hashing: "next copy of \(id.uuidString)")
    }
}

extension UUID {
    /// A UUID made from `text` by hashing it: the same for the same text on every device.
    init(hashing text: String) {
        var digest = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        self.init(
            uuid: (
                digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7], digest[8], digest[9], digest[10],
                digest[11], digest[12], digest[13], digest[14], digest[15]
            ))
    }
}

extension Clarifier {
    /// Marks `items` done, with their open steps, each that repeats making its next copy; or, when
    /// they're all done, opens them again, taking back the copies that are still open. The undo is
    /// for marking done; opening them has none, as marking them done again undoes it.
    @MainActor
    public static func toggleDone(_ items: [Item], today: LocalDate, in context: ModelContext, at now: Date = .now) -> (reopened: Bool, undo: Undo?) {
        guard !items.isEmpty else { return (false, nil) }
        if items.allSatisfy({ $0.status == .done }) {
            for item in items {
                item.reopen(at: now)
                RepeatCopies.takeBack(after: item, in: context, at: now)
            }
            return (true, nil)
        }
        let touched = items + items.flatMap { $0.descendants + $0.ancestors }
        var seen = Set<UUID>()
        let records: [any SyncModel] =
            touched.filter { seen.insert($0.id).inserted } + items.compactMap { $0.status == .open ? $0.repeatRule : nil }
        let before = Undo(records, title: items[0].title)
        var made: [RecordID] = []
        for item in items where item.status == .open {
            item.markDone(at: now)
            if let copy = RepeatCopies.makeNext(after: item, closedOn: today, in: context, at: now) { made.append(copy.recordID) }
        }
        return (false, Undo(before: before.before, made: made, title: before.title))
    }
}

extension RepeatCopies {
    /// Closes each of `items` that repeats without marking it done, and makes its next copy, as
    /// done would. The skipped copy is dropped. Nil when none of them repeats.
    @MainActor
    public static func skip(_ items: [Item], today: LocalDate, in context: ModelContext, at now: Date = .now) -> Clarifier.Undo? {
        let skipping = items.filter { $0.status == .open && $0.repeatRule?.rule != nil }
        guard let first = skipping.first else { return nil }
        let records: [any SyncModel] = skipping + skipping.compactMap(\.repeatRule)
        let before = Clarifier.Undo(records, title: first.title)
        var made: [RecordID] = []
        for item in skipping {
            if let copy = makeNext(after: item, closedOn: today, in: context, at: now) { made.append(copy.recordID) }
            item.status = .dropped
            item.modifiedAt = now
        }
        return Clarifier.Undo(before: before.before, made: made, title: before.title)
    }

    /// Gives `item`, which already repeats, `rule`, described as `text`, and moves it to the new
    /// rule's first date on or after `today`, its other dates by as many days. With `thisOneOnly`,
    /// only the item moves, and its repeat stays as it was, kept to the days it fell on.
    @MainActor
    public static func change(
        _ item: Item, to rule: RepeatRule, text: String, thisOneOnly: Bool, today: LocalDate, in context: ModelContext, at now: Date = .now
    ) {
        let first = rule.firstDate(onOrAfter: today)
        if thisOneOnly {
            item.pinRepeat(at: now)
        } else {
            item.setRepeat(rule, text: text, in: context, at: now)
        }
        guard let first else { return }
        move(item, to: first, at: now)
        item.hideUntil = rule.hideUntil(for: first)?.storedDate
    }

    /// Moves the item's repeat date to `day`, and its other dates by as many days, or schedules it
    /// for `day` when it has no date.
    @MainActor
    static func move(_ item: Item, to day: LocalDate, at now: Date) {
        guard let base = item.repeatBase else {
            item.scheduledDate = day.storedDate
            item.modifiedAt = now
            return
        }
        let shift = base.days(to: day)
        guard shift != 0 else { return }
        item.scheduledDate = item.day(.scheduled)?.adding(days: shift).storedDate
        item.scheduledTime = item.scheduledTime.map { Calendar.current.date(byAdding: .day, value: shift, to: $0) ?? $0 }
        item.dueDate = item.day(.due)?.adding(days: shift).storedDate
        item.followUpDate = item.day(.followUp)?.adding(days: shift).storedDate
        item.modifiedAt = now
    }
}

extension Item {
    /// Gives the item `rule`, described as `text`, or stops it repeating when `rule` is nil. The
    /// repeat's `modifiedAt` changes only when it does.
    @MainActor
    public func setRepeat(_ rule: RepeatRule?, text: String, in context: ModelContext, at now: Date = .now) {
        guard let rule else {
            if let repetition = repeatRule { context.delete(repetition) }
            return
        }
        if let repetition = repeatRule {
            guard repetition.rule != rule || repetition.naturalText != text else { return }
            repetition.rule = rule
            repetition.naturalText = text
            repetition.modifiedAt = now
        } else {
            let repetition = Repetition()
            repetition.rule = rule
            repetition.naturalText = text
            repetition.createdAt = now
            repetition.modifiedAt = now
            context.insert(repetition)
            repeatRule = repetition
        }
    }
}
