import Foundation

/// What a device may do besides the sync every client does (upload, push, pull, status, photo download).
///
/// The Mac is the permanent photo archive: it is the only device that may tell the server to delete its copy of a
/// photo (`archive-confirm`, with `accept_failed` when the user gave up on a receipt) and that reports archive runs
/// (`archive/sync`). The iPhone is NOT the archive: if it ever confirmed a photo it had only cached, the server
/// would delete the only permanent copy. So this is not a matter of leaving out a call; the engine wraps its API in
/// `CapabilityGuardedAPI`, which refuses those calls for a device without `archivesPhotos`, and the archive code
/// paths check the capability too. Tests pin both (`CapabilityTests`).
struct SyncCapabilities: Sendable, Equatable {
    /// May call `archive/pending`, `archive-confirm` (incl. `accept_failed`) and `archive/sync`; runs the archive protocol.
    var archivesPhotos: Bool
    /// Keeps uploaded photos in a bounded local cache and downloads server photos on demand (the phone's copy is a
    /// convenience, never the archive).
    var cachesPhotos: Bool
    /// Upper bound of the photo cache.
    var photoCacheBytes: Int

    static let archiveDevice = SyncCapabilities(archivesPhotos: true, cachesPhotos: false, photoCacheBytes: 0)
    static let mobile = SyncCapabilities(archivesPhotos: false, cachesPhotos: true, photoCacheBytes: 300 * 1_000_000)
}

/// Forwards every call to `base`, except the archive calls, which throw `ReceiptsAPIError.notPermitted` unless the
/// device has the `archivesPhotos` capability. `SyncEngine` always talks to the server through this wrapper.
struct CapabilityGuardedAPI: ReceiptsAPI {
    let base: ReceiptsAPI
    let capabilities: SyncCapabilities

    private func requireArchive(_ what: String) throws {
        guard capabilities.archivesPhotos else {
            throw ReceiptsAPIError.notPermitted("This device is not the photo archive and must not call \(what).")
        }
    }

    func health() async throws { try await base.health() }
    func status() async throws -> ServerStatus { try await base.status() }
    func uploadPhoto(id: String, data: Data, mediaType: String, createdAt: Date?) async throws -> UploadResponse {
        try await base.uploadPhoto(id: id, data: data, mediaType: mediaType, createdAt: createdAt)
    }
    func retryExtraction(id: String) async throws { try await base.retryExtraction(id: id) }
    func push(_ request: PushRequest) async throws -> PushResponse { try await base.push(request) }
    func pull(since: String?, limit: Int) async throws -> PullResponse { try await base.pull(since: since, limit: limit) }
    func downloadPhoto(path: String) async throws -> DownloadedPhoto { try await base.downloadPhoto(path: path) }

    func archivePending() async throws -> [ArchivePendingPhoto] {
        try requireArchive("archive/pending")
        return try await base.archivePending()
    }

    func archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Bool) async throws -> ArchiveConfirmResponse {
        try requireArchive("archive-confirm")
        return try await base.archiveConfirm(id: id, sha256: sha256, deviceId: deviceId, acceptFailed: acceptFailed)
    }

    func archiveSync(deviceId: String) async throws {
        try requireArchive("archive/sync")
        try await base.archiveSync(deviceId: deviceId)
    }
}
