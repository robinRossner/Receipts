import Foundation
import UserNotifications

/// The 30 day reminder as a local notification. A notification scheduled for the due date fires even when the app is not
/// running; every successful sync replaces it with a new one 30 days later. Needs a real app bundle (a bare
/// `swift run` binary has none and is skipped).
struct UserNotificationReminder: ReminderScheduling {
    private let identifier = "receipts.sync.reminder"

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func schedule(at date: Date, title: String, body: String) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let interval = max(date.timeIntervalSinceNow, 60)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    func cancel() {
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
