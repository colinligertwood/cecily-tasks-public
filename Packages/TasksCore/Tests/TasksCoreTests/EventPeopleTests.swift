import Foundation
import Testing

@testable import TasksCore

/// Who's invited to an event, in the order the inspector lists them.
struct EventPeopleTests {
    func person(
        _ name: String?, _ email: String? = nil, _ reply: EventPerson.Reply = .accepted, isYou: Bool = false, isRoom: Bool = false
    ) -> EventPerson {
        EventPerson(name: name, email: email, reply: reply, isYou: isYou, isRoom: isRoom)
    }

    @Test func theOrganizerComesFirstThenEachReplyInAlphabeticalOrder() {
        let noor = person("Noor Shah", "noor@example.com")
        let people = EventPeople(
            organizer: noor,
            attendees: [
                person("Sam Okafor", "sam@example.com", .declined), person("lena", "lena@example.com"),
                person("Noor Shah", "NOOR@example.com"), person(nil, "ops@example.com", .noResponse),
                person("Ana Ruiz", "ana@example.com"), person("Tom Price", "tom@example.com", .maybe),
            ])
        #expect(people.organizer == noor)
        #expect(people.groups.map(\.reply) == [.accepted, .maybe, .declined, .noResponse], "groups with no one are left out")
        #expect(people.groups.map { $0.people.map(\.displayName) } == [["Ana Ruiz", "lena"], ["Tom Price"], ["Sam Okafor"], ["ops@example.com"]])
    }

    @Test func emptyGroupsAreLeftOut() {
        let people = EventPeople(organizer: nil, attendees: [person("Ana Ruiz", nil, .maybe)])
        #expect(people.organizer == nil && people.groups.map(\.reply) == [.maybe])
        #expect(person("  ", " ").displayName == "Unknown")
    }

    @Test func roomsAreListedApartAndYouAreFound() {
        let people = EventPeople(
            organizer: person("Noor Shah", "noor@example.com"),
            attendees: [
                person("Room 4.02", "room402@example.com", isRoom: true), person("Robin", "robin@example.com", .maybe, isYou: true),
                person("Projector", "av@example.com", .noResponse, isRoom: true), person("Ana Ruiz", "ana@example.com"),
            ])
        #expect(people.rooms.map(\.displayName) == ["Projector", "Room 4.02"])
        #expect(people.groups.flatMap(\.people).map(\.displayName) == ["Ana Ruiz", "Robin"])
        #expect(people.you?.reply == .maybe)
        #expect(EventPeople(organizer: person("Robin", isYou: true), attendees: []).you == nil, "the organiser doesn't reply")
    }

    @Test func anOccurrenceHasTheSameSelectionIDEachTime() {
        let calendar = Calendar(identifier: .gregorian)
        func event(_ id: String) -> CalendarEvent {
            CalendarEvent(id: id, title: "1:1", start: .now, end: .now, isAllDay: false, calendarID: "work", reach: .always, in: calendar)
        }
        #expect(event("a-1").selectionID == event("a-1").selectionID)
        #expect(event("a-1").selectionID != event("a-2").selectionID)
    }
}
