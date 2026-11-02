import Foundation

/// An event's location as worth showing beside its rooms and its Join button: without the rooms'
/// names, which booking a room puts there, or the meeting's service ("Microsoft Teams Meeting") or
/// link. Several places are separated by ";", and the parts of one by ",".
public enum EventLocation {
    /// What's left of `location`, or nil when nothing is.
    public static func shown(_ location: String, rooms: [EventPerson], meeting: MeetingLink?) -> String? {
        let roomNames = Set(rooms.flatMap { [$0.name, $0.email] }.compactMap { $0.map(fold) })
        var meetingNames: Set<String> = []
        if let service = meeting?.service {
            meetingNames = Set([service, "\(service) Meeting", "Microsoft \(service)", "Microsoft \(service) Meeting"].map(fold))
        }
        let meetingHost = meeting?.url.host()?.lowercased()
        func isKept(_ part: String) -> Bool {
            let folded = fold(part)
            if folded.isEmpty || roomNames.contains(folded) || meetingNames.contains(folded) { return false }
            if let meetingHost, let host = URL(string: part.trimmingCharacters(in: .whitespaces))?.host()?.lowercased(),
                host == meetingHost || host.hasSuffix("." + meetingHost) || meetingHost.hasSuffix("." + host)
            {
                return false
            }
            return true
        }
        let places = location.split(separator: ";").compactMap { place -> String? in
            let place = String(place)
            guard isKept(place) else { return nil }
            let parts = place.split(separator: ",").map(String.init)
            let kept = parts.filter(isKept).map { $0.trimmingCharacters(in: .whitespaces) }
            return kept.isEmpty ? nil : kept.joined(separator: ", ")
        }
        return places.isEmpty ? nil : places.joined(separator: "; ")
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
