import Foundation
import SwiftData
import TasksCore
import UserNotifications

#if os(macOS)
    import AppKit
#endif

/// Keeps the pending notifications the same as `NotificationPlan`'s: removes those no longer
/// wanted or changed, and adds the rest. It asks for permission the first time there's something
/// to notify. Tapping a notification opens its item, or the weekly review's starts the review.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// The model whose item a tapped notification opens.
    weak var model: AppModel?

    private let center = UNUserNotificationCenter.current()
    private var pending: Task<Void, Never>?
    nonisolated private static let itemKey = "itemID"
    /// Running under tests or in a preview, which mustn't ask for permission or leave notifications
    /// behind.
    private static let isTesting =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    /// Brings the pending notifications up to date with the items in `context`, a second after the
    /// last call, so a run of saves updates them once.
    func update(from context: ModelContext) {
        guard !Self.isTesting else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await apply(plan(context))
        }
    }

    private func plan(_ context: ModelContext) -> [PlannedNotification] {
        let open = ItemStatus.open.rawValue
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.statusRaw == open }))) ?? []
        let record = try? context.fetch(FetchDescriptor<AppSettings>()).first
        let settings = record.map(NotificationSettings.init) ?? NotificationSettings()
        let reviews = (try? context.fetch(FetchDescriptor<ReviewRecord>())) ?? []
        let reminders = NotificationPlan.reviewReminders(
            reviews, reminder: record.map(ReviewReminder.init) ?? ReviewReminder(), now: .now,
            boundary: DayBoundary(minutes: record?.dayBoundaryTime ?? DayBoundary().minutes), in: .current)
        let itemsLimit = NotificationPlan.limit - reminders.count
        return reminders + NotificationPlan.notifications(items, settings: settings, now: .now, in: .current).prefix(itemsLimit)
    }

    private func apply(_ planned: [PlannedNotification]) async {
        if !planned.isEmpty, await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let wanted = Dictionary(planned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = await center.pendingNotificationRequests()
        let stale = existing.filter { request in wanted[request.identifier].map { !Self.matches(request, $0) } ?? true }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: stale)
        let kept = Set(existing.map(\.identifier)).subtracting(stale)
        for notification in planned where !kept.contains(notification.id) {
            try? await center.add(Self.request(for: notification))
        }
    }

    private static func request(for notification: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if let itemID = notification.itemID { content.userInfo = [itemKey: itemID.uuidString] }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notification.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
    }

    private static func matches(_ request: UNNotificationRequest, _ notification: PlannedNotification) -> Bool {
        let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        return request.content.title == notification.title && request.content.body == notification.body && date == notification.date
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo[Self.itemKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            #if os(macOS)
                MainWindow.open()
            #endif
            if let id { model?.openItem = id } else { model?.startReview() }
        }
    }
}
