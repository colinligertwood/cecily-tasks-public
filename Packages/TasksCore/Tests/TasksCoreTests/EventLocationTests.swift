import Foundation
import Testing

@testable import TasksCore

struct EventLocationTests {
    static let rooms = [
        EventPerson(name: "Room 4.01", email: "room401@example.com", reply: .accepted, isRoom: true),
        EventPerson(name: "Boardroom", email: "boardroom@example.com", reply: .noResponse, isRoom: true),
    ]
    static let teams = MeetingLink(service: "Teams", url: URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!)

    @Test(
        arguments: [
            ("Room 4.01", nil),
            ("Room 4.01; Boardroom", nil),
            ("room 4.01 ", nil),
            ("Room 4.01; 1 Main Street, Springfield", "1 Main Street, Springfield"),
            ("Boardroom, Level 3", "Level 3"),
            ("Microsoft Teams Meeting", nil),
            ("Room 4.01; Microsoft Teams Meeting", nil),
            ("https://teams.microsoft.com/l/meetup-join/abc", nil),
            ("Café Nero", "Café Nero"),
            ("Zoom Meeting", "Zoom Meeting"),
        ] as [(String, String?)])
    func roomsAndTheMeetingAreLeftOut(_ location: String, _ expected: String?) {
        #expect(EventLocation.shown(location, rooms: Self.rooms, meeting: Self.teams) == expected)
    }

    @Test func withNoMeetingItsServiceStays() {
        #expect(EventLocation.shown("Microsoft Teams Meeting", rooms: [], meeting: nil) == "Microsoft Teams Meeting")
    }
}
