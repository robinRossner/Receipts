import Foundation

/// Last-write-wins between a local record and the server's copy of it (docs/api/receipts.md, "Client
/// rules when applying a pulled record"). Pure, so it is tested without a database.
enum SyncMerge {
    enum Decision: Equatable {
        /// Replace the local copy (content and clock) with the server's and mark it synced.
        case takeServer
        /// Keep the local edit (it is pushed); only the server-owned fields are refreshed.
        case keepLocal
    }

    /// - Parameters:
    ///   - local: nil when the record is unknown locally.
    ///   - dirty: the local copy has an edit the server has not acknowledged.
    ///
    /// Rules: no local copy or no unsent local edit -> the server's copy wins. With an unsent edit the newer
    /// `updated_at` wins, like the server's own push rule (a pushed record replaces the stored one only if
    /// STRICTLY newer), so a tie goes to the server: pushing our copy would be answered `stale` anyway.
    static func decide(localUpdatedAt local: Date?, dirty: Bool, serverUpdatedAt server: Date?) -> Decision {
        guard let local, dirty else { return .takeServer }
        guard let server else { return .keepLocal }
        return local > server ? .keepLocal : .takeServer
    }

    /// Same, for a local row that was hard deleted (a tombstone waiting to be pushed): the delete wins over a
    /// server record that is not newer than the deletion.
    static func localDeleteWins(deletedAt: Date?, serverUpdatedAt: Date?) -> Bool {
        guard let deletedAt else { return false }
        guard let serverUpdatedAt else { return true }
        return deletedAt >= serverUpdatedAt
    }
}
