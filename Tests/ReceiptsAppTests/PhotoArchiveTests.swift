import XCTest
@testable import ReceiptsApp

/// The firm requirement: the server deletes a photo only when told a matching checksum, so the archive must
/// never confirm unless the file it SAVED hashes to the server's sha256.
final class PhotoArchiveTests: XCTestCase {
    /// Uploads one photo and lets the server finish extracting it.
    private func uploaded(_ h: SyncHarness, status: String = "done", seed: UInt8 = 1) async throws -> (uuid: String, data: Data) {
        let photo = try await h.addPendingPhoto(seed: seed)
        h.server.offline = false
        _ = await h.engine.uploadOne(uuid: photo.uuid)   // upload only: the archive run is the test's business
        if status != "queued" { h.server.finishExtraction(photo.uuid, status: status, error: status == "failed" ? "refused" : nil) }
        return (photo.uuid, photo.data)
    }

    private func archiveFile(_ h: SyncHarness, _ uuid: String) -> URL? {
        let all = FileManager.default.enumerator(at: h.paths.archiveDir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return all.first { $0.lastPathComponent == "\(uuid).jpg" }
    }

    private func stray(_ h: SyncHarness) -> [URL] {
        (FileManager.default.enumerator(at: h.paths.archiveDir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".part") }
    }

    func testVerifiedCopyIsConfirmedWithTheChecksumOfTheSavedFile() async throws {
        let h = try SyncHarness()
        let photo = try await uploaded(h)
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        XCTAssertEqual(report.archive?.archived, [photo.uuid])

        XCTAssertEqual(h.server.confirmCalls.count, 1)
        let call = h.server.confirmCalls[0]
        XCTAssertEqual(call.sha256, Sha256.hex(photo.data))
        XCTAssertEqual(call.deviceId, "macbook-archive")
        XCTAssertFalse(call.acceptFailed)
        let file = try XCTUnwrap(archiveFile(h, photo.uuid))
        XCTAssertEqual(try Data(contentsOf: file), photo.data)
        XCTAssertEqual(h.server.receipts[photo.uuid]?.photoLocation, "archived")
        XCTAssertNil(h.server.photos[photo.uuid], "the server deleted its copy")
        XCTAssertGreaterThan(h.server.archiveSyncCalls, 0)
        XCTAssertTrue(stray(h).isEmpty)

        // the receipt shows the archived file from now on; the outbox copy is gone
        let source = try await h.receiptField(photo.uuid, "source_image")
        XCTAssertEqual(source, "receipts_archive/\(file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)/\(file.deletingLastPathComponent().lastPathComponent)/\(photo.uuid).jpg")
        let location = try await h.receiptField(photo.uuid, "photo_location")
        XCTAssertEqual(location, "archived")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.outboxDir.appendingPathComponent("\(photo.uuid).jpg").path))
    }

    func testChecksumMismatchOfTheDownloadNeverConfirms() async throws {
        let h = try SyncHarness()
        let photo = try await uploaded(h)
        h.server.corruptDownloads = true
        let report = await h.engine.syncNow()
        XCTAssertTrue(h.server.confirmCalls.isEmpty, "a corrupted copy must never be confirmed")
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.errors.contains { $0.contains("checksum") }, "\(report.errors)")
        XCTAssertNil(archiveFile(h, photo.uuid), "no corrupt file is left under the final name")
        XCTAssertNotNil(h.server.photos[photo.uuid], "the server still holds the photo")
        XCTAssertTrue(stray(h).isEmpty)

        // retried later, with a good download, it archives
        h.server.corruptDownloads = false
        let retry = await h.engine.syncNow()
        XCTAssertEqual(retry.archive?.archived, [photo.uuid])
        XCTAssertEqual(h.server.confirmCalls.count, 1)
    }

    /// The re-read of the saved file is what is hashed: if the disk returns other bytes than were handed over, no confirm.
    func testCorruptedReadBackNeverConfirms() async throws {
        let h = try SyncHarness(fileSystem: CorruptingReadFS())
        let photo = try await uploaded(h)
        let report = await h.engine.syncNow()
        XCTAssertTrue(h.server.confirmCalls.isEmpty)
        XCTAssertFalse(report.succeeded)
        XCTAssertNil(archiveFile(h, photo.uuid))
        XCTAssertNotNil(h.server.photos[photo.uuid])
    }

    func testDiskFullNeverConfirmsAndLeavesNothingBehind() async throws {
        let h = try SyncHarness(fileSystem: DiskFullFS())
        let photo = try await uploaded(h)
        let report = await h.engine.syncNow()
        XCTAssertTrue(h.server.confirmCalls.isEmpty)
        XCTAssertTrue(report.errors.contains { $0.contains("could not save") }, "\(report.errors)")
        XCTAssertNil(archiveFile(h, photo.uuid))
        XCTAssertNotNil(h.server.photos[photo.uuid])
        // the rest of the sync was not affected
        XCTAssertGreaterThan(h.server.archiveSyncCalls, 0)
    }

    func testPhotoOfAnUnfinishedExtractionIsSavedButNotConfirmed() async throws {
        let h = try SyncHarness()
        let photo = try await uploaded(h, status: "queued")
        let report = await h.engine.syncNow()
        XCTAssertTrue(h.server.confirmCalls.isEmpty, "the server's rules do not allow it yet, so it is not even asked")
        XCTAssertEqual(report.archive?.savedWaiting, [photo.uuid])
        XCTAssertNotNil(archiveFile(h, photo.uuid), "the verified copy is kept")
        XCTAssertNotNil(h.server.photos[photo.uuid])

        // later, when the extraction finished: confirmed from the copy already on disk (no second download)
        let downloads = h.server.downloadCalls
        h.server.finishExtraction(photo.uuid)
        let later = await h.engine.syncNow()
        XCTAssertEqual(later.archive?.archived, [photo.uuid])
        XCTAssertEqual(h.server.downloadCalls, downloads)
    }

    func testFailedExtractionIsOnlyConfirmedAfterTheUsersExplicitChoice() async throws {
        let h = try SyncHarness()
        let photo = try await uploaded(h, status: "failed")
        let report = await h.engine.syncNow()
        XCTAssertTrue(h.server.confirmCalls.isEmpty, "accept_failed is never sent automatically")
        XCTAssertEqual(report.archive?.savedWaiting, [photo.uuid])

        let id = try await h.store.localID(forUUID: photo.uuid)!
        try await h.store.setAcceptFailed(localID: id, true)
        let accepted = await h.engine.syncNow()
        XCTAssertEqual(accepted.archive?.archived, [photo.uuid])
        XCTAssertEqual(h.server.confirmCalls.count, 1)
        XCTAssertTrue(h.server.confirmCalls[0].acceptFailed)
    }

    func testAcceptFailedIsNotSentForAReceiptThatIsNotFailed() async throws {
        let h = try SyncHarness()
        let photo = try await uploaded(h, status: "done")
        let id = try await h.store.localID(forUUID: photo.uuid)!
        try await h.store.setAcceptFailed(localID: id, true)
        _ = await h.engine.syncNow()
        XCTAssertEqual(h.server.confirmCalls.count, 1)
        XCTAssertFalse(h.server.confirmCalls[0].acceptFailed)
    }

    func testServerSideMismatchAnswerIsAFailureNotASuccess() async throws {
        let h = try SyncHarness()
        let photo = try await uploaded(h)
        h.server.failures["confirm"] = .http(status: 409, code: "sha256_mismatch", message: "kept", extra: [:])
        let report = await h.engine.syncNow()
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.archive?.archived, [])
        let location = try await h.receiptField(photo.uuid, "photo_location")
        XCTAssertNotEqual(location, "archived")
        XCTAssertNotNil(archiveFile(h, photo.uuid), "the saved copy is kept, never deleted before a success answer")
    }

    func testNothingPendingStillReportsTheRun() async throws {
        let h = try SyncHarness()
        _ = await h.engine.syncNow()
        XCTAssertEqual(h.server.archiveSyncCalls, 1)
    }

    func testMissingLocalPhotoIsAStateNotACrash() async throws {
        // a receipt that says archived, with no file on this Mac, is simply a row without a path: nothing throws
        let h = try SyncHarness()
        let ids = h.seedExtractedReceipt()
        var r = h.server.receipts[ids.receipt]!
        r.photoLocation = "archived"
        h.server.seedReceipt(r)
        let report = await h.engine.syncNow()
        XCTAssertTrue(report.succeeded, "\(report.errors)")
        let source = try await h.receiptField(ids.receipt, "source_image")
        XCTAssertNil(source)
    }
}

// MARK: - File systems that misbehave

private struct CorruptingReadFS: ArchiveFileSystem {
    func writeAtomically(_ data: Data, to url: URL) throws { try AtomicFile.write(data, to: url) }
    func read(_ url: URL) throws -> Data {
        var d = try Data(contentsOf: url)
        if !d.isEmpty { d[d.startIndex] ^= 0x01 }
        return d
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

private struct DiskFullFS: ArchiveFileSystem {
    func writeAtomically(_ data: Data, to url: URL) throws {
        throw AtomicFile.WriteError(operation: "write", path: url.path, errnoValue: ENOSPC)
    }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
