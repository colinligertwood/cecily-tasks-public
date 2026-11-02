import Foundation

/// Where filing puts an item, and what it fills in on the way.
public struct ClarifyOutcome: Hashable, Sendable {
    public enum Destination: Hashable, Sendable {
        case trash
        case someday
        case reference
        /// Done there and then, in under two minutes.
        case doneNow
        case waiting(person: String, followUp: LocalDate?)
        /// Tied to a day, and optionally a time (minutes after midnight).
        case scheduled(date: LocalDate, time: Int?)
        case action
    }

    public enum ProjectChoice: Hashable, Sendable {
        case existing(UUID)
        /// A new task, with more subtasks besides this one.
        case new(title: String, moreActions: [String])
    }

    public var destination: Destination
    /// The title rewritten as a concrete next step, if it was.
    public var title: String?
    public var project: ProjectChoice?
    /// Contexts by id; nil leaves them as they are.
    public var contexts: [UUID]?
    public var timeEstimate: TimeEstimate?
    public var energy: Energy?
    public var dueDate: LocalDate?
    public var hideUntil: LocalDate?
    public var repeatRule: RepeatRule?
    public var area: UUID?
    /// Seconds a "do it now" took.
    public var secondsTaken: Int?

    public init(_ destination: Destination) {
        self.destination = destination
    }
}
