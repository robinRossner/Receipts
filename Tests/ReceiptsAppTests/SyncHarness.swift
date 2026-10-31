import Foundation
import XCTest
@testable import ReceiptsApp

/// A temp data dir, a real SQLite `Database`, the sync store and engine, and a fake server.
final class SyncHarness {
    let dir: URL
    let db: Database
    let paths: SyncPaths
    let store: SyncStore
    let server: FakeReceiptsServer
    let engine: SyncEngine

    init(legacy: Bool = false, fileSystem: ArchiveFileSystem = DiskFileSystem(), server: FakeReceiptsServer = FakeReceiptsServer()) throws {
        dir = try makeTempDir()
        if legacy { try LegacyDB.create(at: dir.appendingPathComponent("receipts.db").path, LegacyDB.populateSample) }
        db = try openTempDatabase(in: dir)
        let archive = dir.appendingPathComponent("receipts_archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        paths = SyncPaths(appSupportDir: dir, archiveDir: archive)
        store = SyncStore(db: db, paths: paths)
        self.server = server
        engine = SyncEngine(api: server, store: store, config: SyncConfig(cursorKey: "cursor:test"), fileSystem: fileSystem)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A receipt for a prepared photo waiting in the outbox, like the upload flow creates.
    @discardableResult
    func addPendingPhoto(seed: UInt8 = 1, created: Date = Date()) async throws -> (uuid: String, id: Int, data: Data) {
        let uuid = LegacyIDs.newUUID()
        let data = fakePhoto(seed)
        try FileManager.default.createDirectory(at: paths.outboxDir, withIntermediateDirectories: true)
        let file = paths.outboxDir.appendingPathComponent("\(uuid).jpg")
        try data.write(to: file)
        let id = try await store.insertPendingUpload(uuid: uuid, createdAt: created, photoPath: paths.stored(file), imageHash: nil)
        return (uuid, id, data)
    }

    func row(_ sql: String, _ params: [SQLiteValue] = []) async throws -> SQLRow? { try await db.queryOne(sql, params) }

    func receiptField(_ uuid: String, _ column: String) async throws -> String? {
        try await db.scalarString("SELECT \(column) FROM receipts WHERE uuid = ?", [.text(uuid)])
    }

    func count(_ table: String, where clause: String = "1 = 1") async throws -> Int {
        try await db.scalarInt("SELECT COUNT(*) FROM \(table) WHERE \(clause)") ?? -1
    }

    /// A completed server-side receipt (as another device or the extraction would have produced it).
    func seedExtractedReceipt(id: String = LegacyIDs.newUUID(), store: String = "Rewe", stamp: String = "2026-04-01T10:00:00.000Z",
                              dictionaryId: String = LegacyIDs.newUUID(), itemId: String = LegacyIDs.newUUID(), canonical: String = "brot") -> (receipt: String, item: String, dictionary: String) {
        server.seedDictionary(WireDictionaryEntry(id: dictionaryId, canonicalName: canonical, displayNameDe: canonical.capitalized, translationEn: "bread",
                                                  category: "Food", subcategory: "Bakery", itemGroup: "Bread", aliases: [], isManualOverride: false,
                                                  needsReview: false, timesSeen: 1, createdAt: stamp, lastSeenAt: stamp, updatedAt: stamp))
        server.seedReceipt(WireReceipt(id: id, store: store, date: "2026-04-01", total: 2.5, computedSum: 2.5, createdAt: stamp, photoLocation: "none",
                                       extractionStatus: "done", updatedAt: stamp))
        server.seedItem(WireLineItem(id: itemId, receiptId: id, itemDictionaryId: dictionaryId, position: 0, rawText: "BROT", nameDe: "Brot", quantity: 1,
                                     unitPrice: 2.5, totalPrice: 2.5, priceNormalized: false, updatedAt: stamp))
        return (id, itemId, dictionaryId)
    }
}
