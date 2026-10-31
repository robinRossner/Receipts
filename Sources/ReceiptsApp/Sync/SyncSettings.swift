import Foundation

/// The cloud sync settings: switch, server URL (UserDefaults) and the token (Keychain, never UserDefaults). With
/// `enabled` false the app behaves exactly as before sync existed and nothing here is used.
struct SyncSettings: Equatable, Sendable {
    enum Keys {
        static let enabled = "sync.enabled"
        static let serverURL = "sync.serverURL"
        /// When sync was switched on (the 30 day reminder counts from here until the first sync).
        static let enabledSince = "sync.enabledSince"
    }

    var enabled = false
    var serverURL = ""
    var token: String?

    var apiBase: URL? { ServerURL.apiBase(from: serverURL) }
    var isConfigured: Bool { apiBase != nil && !(token ?? "").isEmpty }

    static func load(from defaults: UserDefaults = .standard, token: String? = KeychainStore.read(.receiptsAPIToken)) -> SyncSettings {
        SyncSettings(
            enabled: defaults.bool(forKey: Keys.enabled),
            serverURL: defaults.string(forKey: Keys.serverURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            token: token
        )
    }

    static func enabledSince(in defaults: UserDefaults = .standard) -> Date? {
        let t = defaults.double(forKey: Keys.enabledSince)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}

/// "Has this Mac not synced for 30 days?" - the reminder for the photo archive (the server reminds too, but it can
/// only reach the phone through ntfy, so the Mac reminds itself).
enum SyncReminder {
    static let days = 30

    /// The moment the reminder is due: 30 days after the last successful sync, or after sync was switched on.
    static func dueDate(lastSync: Date?, enabledSince: Date?) -> Date? {
        guard let reference = lastSync ?? enabledSince else { return nil }
        return reference.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    static func isOverdue(lastSync: Date?, enabledSince: Date?, now: Date = Date()) -> Bool {
        guard let due = dueDate(lastSync: lastSync, enabledSince: enabledSince) else { return false }
        return now >= due
    }
}

protocol ReminderScheduling {
    /// Replaces any earlier reminder.
    func schedule(at date: Date, title: String, body: String)
    func cancel()
}

struct NoReminders: ReminderScheduling {
    func schedule(at date: Date, title: String, body: String) {}
    func cancel() {}
}
