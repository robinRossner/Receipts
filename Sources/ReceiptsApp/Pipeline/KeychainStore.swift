import Foundation
import Security

/// Secrets (Claude API key, `claude setup-token` token, the receipts server token) live in the macOS
/// Keychain as generic passwords - never in UserDefaults, logs or the debug dump.
enum KeychainStore {
    static let service = "ReceiptsApp"

    enum Account: String {
        case anthropicAPIKey = "anthropic-api-key"
        case claudeOAuthToken = "claude-oauth-token"
        /// Bearer token of the receipts backend (`RECEIPTS_API_TOKEN`) for cloud sync.
        case receiptsAPIToken = "receipts-api-token"
    }

    private static func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    static func read(_ account: Account) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func contains(_ account: Account) -> Bool { read(account) != nil }

    /// Replaces any existing value. Returns false (and logs the OSStatus) on failure.
    @discardableResult
    static func save(_ value: String, for account: Account) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(account) }
        SecItemDelete(baseQuery(account) as CFDictionary)
        var item = baseQuery(account)
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { print("Keychain save failed for \(account.rawValue): OSStatus \(status)") }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: Account) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
