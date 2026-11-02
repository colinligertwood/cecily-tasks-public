import SwiftUI
import TasksCore

#if os(iOS)
    import UIKit
#endif

/// Calendar events on Agenda: whether they're shown, how often the calendars are checked for
/// changes, and for each calendar, by account, how far ahead. With no access to the calendars, a way to System Settings to allow it.
struct CalendarSettings: View {
    private let feed = CalendarFeed.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle("Show Calendar Events on Agenda", isOn: Binding(get: { feed.isOn }, set: { feed.setOn($0) }))
            } footer: {
                Text("Always shows a calendar's events on every day ahead. This Week shows them only on the next seven days and this week.")
            }
            Section {
                Picker("Check for Changes", selection: Binding(get: { feed.checkMinutes }, set: { feed.setCheckMinutes($0) })) {
                    ForEach(CalendarFeed.checkIntervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "Every Minute" : "Every \(minutes) Minutes").tag(minutes)
                    }
                }
                .disabled(!feed.isOn)
            } footer: {
                Text(
                    "Cecily Tasks asks your device to check your calendar accounts this often. How quickly changes arrive depends on each account's own setting for refreshing calendars."
                )
            }
            if feed.isOn, feed.access == .notAsked {
                Section {
                    Text("Cecily Tasks needs access to your calendars to show their events.")
                    Button("Allow Access…") { feed.askIfNeeded() }
                }
            }
            if feed.isOn, feed.access == .refused {
                Section {
                    Text("Cecily Tasks isn't allowed to see your calendars.")
                    Button("Open System Settings") { if let url = Self.privacySettings { openURL(url) } }
                }
            }
            ForEach(accounts, id: \.self) { account in
                Section(account.isEmpty ? "Other" : account) {
                    ForEach(feed.calendars.filter { $0.account == account }) { calendar in
                        Picker(
                            selection: Binding(get: { calendar.reach }, set: { feed.setReach($0, of: calendar.id) })
                        ) {
                            Text("Always").tag(CalendarReach.always)
                            Text("This Week").tag(CalendarReach.thisWeek)
                            Text("Off").tag(CalendarReach.off)
                        } label: {
                            Label {
                                Text(calendar.title)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(calendar.color)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendars")
        .onAppear { feed.refresh() }
    }

    private var accounts: [String] {
        feed.calendars.map(\.account).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private static var privacySettings: URL? {
        #if os(macOS)
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        #else
            URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}
