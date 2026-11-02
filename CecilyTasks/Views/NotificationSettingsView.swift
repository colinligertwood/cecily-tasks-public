import SwiftData
import SwiftUI
import TasksCore
import UserNotifications

#if os(iOS)
    import UIKit
#endif

/// Which notifications are on, the time of day for due dates and follow-ups, the weekly review's
/// reminder, and a way to the system's settings when notifications are turned off there.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settings: [AppSettings]
    @State private var isAllowed = true

    var body: some View {
        Form {
            if !isAllowed {
                Section {
                    Text("Notifications are turned off for Cecily Tasks in System Settings.")
                    Button("Open System Settings") { openSystemSettings() }
                }
            }
            if let record = settings.first {
                Section {
                    Toggle("Scheduled Times", isOn: binding(record, \.notifyScheduled))
                    Toggle("Due Dates", isOn: binding(record, \.notifyDue))
                    Toggle("Follow-Ups", isOn: binding(record, \.notifyFollowUps))
                } footer: {
                    Text("Scheduled times notify at the time. Due dates and follow-ups notify on the day.")
                }
                Section {
                    DatePicker(
                        "Time for Due Dates and Follow-Ups", selection: time(record, \.dueNotificationTime), displayedComponents: .hourAndMinute
                    )
                    .disabled(!record.notifyDue && !record.notifyFollowUps)
                }
                Section {
                    Toggle("Weekly Review", isOn: binding(record, \.weeklyReviewReminder))
                    Picker("Day", selection: weekday(record)) {
                        ForEach(Self.weekdays, id: \.self) { weekday in
                            Text(Calendar.current.weekdaySymbols[weekday - 1]).tag(weekday)
                        }
                    }
                    .disabled(!record.weeklyReviewReminder)
                    DatePicker("Time", selection: time(record, \.weeklyReviewTime), displayedComponents: .hourAndMinute)
                        .disabled(!record.weeklyReviewReminder)
                } footer: {
                    Text("A reminder each week to go through your lists, unless a review is open or was finished that day or the day before.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task(id: scenePhase) {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            isAllowed = status != .denied
        }
    }

    private func binding(_ record: AppSettings, _ setting: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding {
            record[keyPath: setting]
        } set: { isOn in
            guard isOn != record[keyPath: setting] else { return }
            record[keyPath: setting] = isOn
            record.modifiedAt = .now
            model.save()
        }
    }

    /// The week's days, 1 for Sunday, from the first day of the week.
    private static var weekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func weekday(_ record: AppSettings) -> Binding<Int> {
        Binding {
            record.weeklyReviewWeekday
        } set: { weekday in
            guard weekday != record.weeklyReviewWeekday else { return }
            record.weeklyReviewWeekday = weekday
            record.modifiedAt = .now
            model.save()
        }
    }

    /// A time setting, minutes after midnight, as a moment today for the picker.
    private func time(_ record: AppSettings, _ setting: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: .now)
        return Binding {
            calendar.date(byAdding: .minute, value: record[keyPath: setting], to: midnight) ?? midnight
        } set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            guard minutes != record[keyPath: setting] else { return }
            record[keyPath: setting] = minutes
            record.modifiedAt = .now
            model.save()
        }
    }

    private func openSystemSettings() {
        #if os(macOS)
            let address = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        #else
            let address = UIApplication.openNotificationSettingsURLString
        #endif
        if let url = URL(string: address) { openURL(url) }
    }
}

#Preview(traits: .previewRecords) {
    NavigationStack { NotificationSettingsView() }
}
