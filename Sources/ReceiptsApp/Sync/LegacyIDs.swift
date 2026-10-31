import CryptoKit
import Foundation

/// The stable UUIDs the Mac app's pre-sync rows get. MUST give exactly what
/// `backend/apps/receipts/migrate_mac_data.py` (`uid()`) gives the same rows, otherwise the first
/// sync would see every receipt as new and duplicate it: `uuid5(NAMESPACE, "mac:<kind>:<row id>")`.
/// `LegacyIDsTests` pins known values produced by the Python function.
enum LegacyIDs {
    /// `NAMESPACE` in migrate_mac_data.py.
    static let namespace = UUID(uuidString: "0b8f3c52-6d1e-4c7a-9a4e-2f5d8e1b7c63")!

    enum Kind: String {
        case dictionary
        case receipt
        case lineItem = "line_item"
    }

    static func uuid(_ kind: Kind, _ rowID: Int) -> String {
        uuid5(namespace: namespace, name: "mac:\(kind.rawValue):\(rowID)")
    }

    /// RFC 4122 version 5 (SHA-1), lowercase canonical text like Python's `str(uuid.uuid5(...))`.
    static func uuid5(namespace: UUID, name: String) -> String {
        var input = Data()
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        input.append(Data(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let a = hex.prefix(8), b = hex.dropFirst(8).prefix(4), c = hex.dropFirst(12).prefix(4)
        let d = hex.dropFirst(16).prefix(4), e = hex.dropFirst(20)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }

    /// A fresh random UUID in the wire form (lowercase).
    static func newUUID() -> String { UUID().uuidString.lowercased() }
}
