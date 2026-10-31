import Foundation

/// Outcome of one archive run.
struct ArchiveReport: Sendable, Equatable {
    /// Receipt uuids whose server copy was released (the server answered `archived` / `already_archived`).
    var archived: [String] = []
    /// Verified copies on this Mac that the server may not release yet (extraction pending / failed).
    var savedWaiting: [String] = []
    var failures: [String] = []
    var listed = 0
}

/// The Mac is the permanent photo archive (docs/api/receipts.md, "Photo archive (laptop)"). For every photo the
/// server still holds: download, write atomically into the archive folder, read the saved file back and hash
/// IT, and only when that equals the server's checksum and the server's rules allow it, `archive-confirm`.
/// The server deletes its copy only on that confirmation, so every doubt here means: do not confirm, try again later.
struct PhotoArchiver: Sendable {
    let api: ReceiptsAPI
    let store: SyncStore
    let fileSystem: ArchiveFileSystem
    let deviceId: String

    private var paths: SyncPaths { store.paths }

    /// Throws only when the server cannot be reached / refuses us (the whole run is pointless then); a problem
    /// with one photo is recorded in the report and the run goes on.
    func run() async throws -> ArchiveReport {
        var report = ArchiveReport()
        let pending = try await api.archivePending()
        report.listed = pending.count
        for photo in pending {
            do {
                try await archive(photo, into: &report)
            } catch let error as ReceiptsAPIError where error.isConnectionLevel {
                throw error
            } catch {
                report.failures.append("\(photo.id): \(error.localizedDescription)")
            }
        }
        // "At the end of every run (also when nothing was pending)": lets the server's 30 day reminder know we ran.
        do { try await api.archiveSync(deviceId: deviceId) } catch let error as ReceiptsAPIError where error.isConnectionLevel {
            throw error
        } catch { report.failures.append("archive/sync: \(error.localizedDescription)") }
        return report
    }

    // MARK: - One photo

    static func fileExtension(mediaType: String?) -> String {
        mediaType?.lowercased().contains("png") == true ? "png" : "jpg"
    }

    /// `receipts_archive/<yyyy>/<MM>/<uuid>.<ext>`, the folder from the server's upload time (always known, never
    /// changes), the name from the uuid (unique, independent of what the extraction finds).
    func destination(for photo: ArchivePendingPhoto) -> URL {
        let date = SyncDate.parse(photo.uploadedAt) ?? Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = cal.dateComponents([.year, .month], from: date)
        return paths.archiveDir
            .appendingPathComponent(String(format: "%04d", parts.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month ?? 1), isDirectory: true)
            .appendingPathComponent("\(photo.id).\(Self.fileExtension(mediaType: photo.mediaType))")
    }

    private func archive(_ photo: ArchivePendingPhoto, into report: inout ArchiveReport) async throws {
        let expected = photo.sha256.lowercased()
        let info = try await store.archiveInfo(uuid: photo.id)
        let dest = destination(for: photo)

        // 1. A verified copy may already be on disk from an earlier run that could not confirm yet.
        var savedSHA: String?
        if fileSystem.exists(dest), let existing = try? fileSystem.read(dest), Sha256.hex(existing) == expected {
            savedSHA = expected
        }

        // 2. Otherwise download, write atomically, read back from disk, hash the saved file.
        if savedSHA == nil {
            let download: DownloadedPhoto
            do { download = try await api.downloadPhoto(path: photo.download) } catch let error as ReceiptsAPIError {
                if error.code == "photo_archived" { return }   // released meanwhile (another run): nothing to do
                throw error
            }
            do {
                try fileSystem.writeAtomically(download.data, to: dest)   // throws on a full disk: nothing is confirmed
            } catch {
                throw ArchiveError.writeFailed(error.localizedDescription)
            }
            let readBack = try fileSystem.read(dest)
            let actual = Sha256.hex(readBack)
            guard actual == expected else {
                fileSystem.remove(dest)   // never leave a copy that is not the server's photo under the final name
                throw ArchiveError.checksumMismatch(expected: expected, actual: actual)
            }
            savedSHA = actual
        }
        guard let savedSHA else { return }

        // The receipt can show the verified copy from here, whether or not the server may release its own yet.
        let storedPath = paths.stored(dest)
        if let info, info.sourceImage != storedPath {
            try? await store.setLocalPhoto(uuid: photo.id, path: storedPath)
        }

        // 3. Confirm only when the server's rules allow it: extraction done, or failed AND the user gave up on it.
        let userAcceptedFailure = info?.acceptFailed == true && photo.extractionStatus == "failed"
        guard photo.archivable || userAcceptedFailure else {
            report.savedWaiting.append(photo.id)
            return
        }
        do {
            _ = try await api.archiveConfirm(id: photo.id, sha256: savedSHA, deviceId: deviceId, acceptFailed: userAcceptedFailure)
        } catch let error as ReceiptsAPIError {
            if error.code == "extraction_pending" || error.code == "extraction_failed" {
                report.savedWaiting.append(photo.id)   // the list was stale; keep the saved copy, confirm later
                return
            }
            throw error
        }
        try await store.markArchived(uuid: photo.id, path: storedPath)
        removeOutboxCopy(previous: info?.sourceImage, keeping: storedPath)
        report.archived.append(photo.id)
    }

    /// The prepared upload copy is redundant once the archive copy is confirmed.
    private func removeOutboxCopy(previous: String?, keeping: String) {
        guard let previous, previous != keeping, let url = paths.resolve(previous),
              url.deletingLastPathComponent().standardizedFileURL.path == paths.outboxDir.standardizedFileURL.path else { return }
        fileSystem.remove(url)
    }

    enum ArchiveError: Error, LocalizedError, Equatable {
        case writeFailed(String)
        case checksumMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let m): return "could not save the photo (\(m)); not confirmed, will retry"
            case .checksumMismatch: return "the saved photo does not match the server's checksum; not confirmed, will retry"
            }
        }
    }
}
