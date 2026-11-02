import Foundation

/// Someone or something invited to a calendar event, and their reply.
public struct EventPerson: Hashable, Sendable, Identifiable {
    public enum Reply: CaseIterable, Sendable {
        case accepted
        case maybe
        case declined
        case noResponse
    }

    public let name: String?
    public let email: String?
    public let reply: Reply
    /// The person whose calendar it is.
    public let isYou: Bool
    public let isOptional: Bool
    /// A room or equipment booked for the event, rather than a person.
    public let isRoom: Bool

    public init(name: String?, email: String?, reply: Reply, isYou: Bool = false, isOptional: Bool = false, isRoom: Bool = false) {
        self.name = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.email = email?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.reply = reply
        self.isYou = isYou
        self.isOptional = isOptional
        self.isRoom = isRoom
    }

    /// Their name, or their email address when there's no name.
    public var displayName: String { name ?? email ?? "Unknown" }

    public var id: String { (email ?? "") + "|" + displayName }
}

/// An event's people: the organiser, then everyone else invited under their reply, in the order
/// of `EventPerson.Reply`, each group in alphabetical order, and the rooms on their own. Groups
/// with no one are left out, and the organiser isn't listed again among the others.
public struct EventPeople: Sendable {
    public struct Group: Sendable, Identifiable {
        public let reply: EventPerson.Reply
        public let people: [EventPerson]
        public var id: EventPerson.Reply { reply }
    }

    public let organizer: EventPerson?
    public let groups: [Group]
    /// In alphabetical order.
    public let rooms: [EventPerson]
    /// The person whose calendar it is, when they're invited and not the organiser.
    public let you: EventPerson?

    public init(organizer: EventPerson?, attendees: [EventPerson]) {
        let others = attendees.filter { person in
            guard let organizer else { return true }
            if let email = person.email, let theirs = organizer.email { return email.lowercased() != theirs.lowercased() }
            return person.displayName != organizer.displayName
        }
        func alphabetical(_ people: [EventPerson]) -> [EventPerson] {
            people.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        let people = others.filter { !$0.isRoom }
        self.organizer = organizer
        groups = EventPerson.Reply.allCases.compactMap { reply in
            let replied = alphabetical(people.filter { $0.reply == reply })
            return replied.isEmpty ? nil : Group(reply: reply, people: replied)
        }
        rooms = alphabetical(others.filter(\.isRoom))
        you = people.first(where: \.isYou)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
