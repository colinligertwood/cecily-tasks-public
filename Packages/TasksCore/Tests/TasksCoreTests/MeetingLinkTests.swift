import Foundation
import Testing

@testable import TasksCore

/// Finding the link that joins an event's video meeting.
struct MeetingLinkTests {
    @Test(arguments: [
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d", "Teams"),
        ("https://us02web.zoom.us/j/123456789?pwd=abc", "Zoom"),
        ("https://meet.google.com/abc-defg-hij", "Google Meet"),
        ("https://acme.webex.com/meet/noor", "Webex"),
        ("https://facetime.apple.com/join#v=1&p=abc", "FaceTime"),
        ("https://meet.goto.com/123456789", "GoTo Meeting"),
    ])
    func eachServiceIsKnown(link: String, service: String) {
        #expect(MeetingLink.find(in: ["Join: \(link)"]) == MeetingLink(service: service, url: URL(string: link)!))
    }

    @Test func theLinkComesFirstThenTheLocationThenTheNotes() {
        let found = MeetingLink.find(in: [
            "https://example.com/agenda", "Room 4.02; https://meet.google.com/abc-defg-hij",
            "<a href=\"https://us02web.zoom.us/j/1\">Join</a>",
        ])
        #expect(found?.service == "Google Meet")
        #expect(MeetingLink.find(in: [nil, "Room 4.02", "Agenda: https://example.com"]) == nil)
    }

    @Test func htmlNotesAndSafeLinksAreRead() {
        let notes = #"<a href="https://teams.microsoft.com/l/meetup-join/x?context=a&amp;b=2">Join the meeting now</a>"#
        #expect(MeetingLink.find(in: [notes])?.url.absoluteString == "https://teams.microsoft.com/l/meetup-join/x?context=a&b=2")
        let wrapped = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fus02web.zoom.us%2Fj%2F42&data=abc"
        #expect(MeetingLink.find(in: [wrapped]) == MeetingLink(service: "Zoom", url: URL(string: "https://us02web.zoom.us/j/42")!))
    }
}
