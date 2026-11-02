import Foundation

/// The link that joins an event's video meeting, and the service it's on.
public struct MeetingLink: Equatable, Sendable {
    /// "Teams", "Zoom", "Google Meet".
    public let service: String
    public let url: URL

    /// The services whose links join a meeting, by the end of their host's name.
    private static let services: [(host: String, name: String)] = [
        ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"), ("zoom.us", "Zoom"), ("zoomgov.com", "Zoom"),
        ("meet.google.com", "Google Meet"), ("webex.com", "Webex"), ("facetime.apple.com", "FaceTime"),
        ("gotomeeting.com", "GoTo Meeting"), ("meet.goto.com", "GoTo Meeting"),
    ]

    /// The first meeting link in `texts`, in their order: an event's link, location and notes.
    /// A link wrapped by Outlook's Safe Links is read as the link it wraps.
    public static func find(in texts: [String?]) -> MeetingLink? {
        for text in texts.compactMap(\.self) {
            for link in EventNotes.links(in: text) {
                let written = link.url.absoluteString.replacing("&amp;", with: "&")
                guard let url = URL(string: written).map(unwrapped), let host = url.host()?.lowercased() else { continue }
                if let service = services.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }) {
                    return MeetingLink(service: service.name, url: url)
                }
            }
        }
        return nil
    }

    /// `url`, or the link it wraps when it's one of Outlook's Safe Links.
    private static func unwrapped(_ url: URL) -> URL {
        guard url.host()?.lowercased().hasSuffix("safelinks.protection.outlook.com") == true,
            let wrapped = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
            let inner = URL(string: wrapped)
        else { return url }
        return inner
    }
}
