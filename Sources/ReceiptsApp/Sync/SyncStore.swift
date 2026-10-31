import Foundation

/// Where sync keeps files. A plain value (not AppEnvironment) so the sync code does not depend on app folders
/// beyond these three.
struct SyncPaths: Sendable {
    let appSupportDir: URL
    let archiveDir: URL
    /// Prepared JPEGs that wait for (or just completed) their upload. Uploads must retry with the SAME bytes.
    var outboxDir: URL { appSupportDir.appendingPathComponent("uploads_outbox", isDirectory: true) }

    /// Same rule as `AppEnvironment.resolveImagePath`: stored paths are relative to the app-support dir.
    func resolve(_ stored: String?) -> URL? {
        guard let stored, !stored.isEmpty else { return nil }
        return stored.hasPrefix("/") ? URL(fileURLWithPath: stored) : appSupportDir.appendingPathComponent(stored)
    }

    func stored(_ url: URL) -> String {
        let prefix = appSupportDir.path.hasSuffix("/") ? appSupportDir.path : appSupportDir.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }
}

/// Everything the batch of local changes to send holds, plus the clock values it was read with: a row that is
/// edited again while the push is in flight keeps its dirty mark.
struct PushBatch: Sendable {
    var dictionary: [WireDictionaryEntry] = []
    var receipts: [WireReceipt] = []
    var lineItems: [WireLineItem] = []
    /// `entity:uuid` -> the `updated_at` that was sent.
    var stamps: [String: String] = [:]
    var isEmpty: Bool { dictionary.isEmpty && receipts.isEmpty && lineItems.isEmpty }
    var count: Int { dictionary.count + receipts.count + lineItems.count }

    static func key(_ entity: PushResult.Entity, _ id: String) -> String { "\(entity.rawValue):\(id)" }
}

struct PushSummary: Sendable, Equatable {
    var applied = 0
    var stale = 0
    var rejected: [String] = []
}

struct ApplySummary: Sendable, Equatable {
    var dictionary = 0
    var receipts = 0
    var lineItems = 0
    var deletedLocally = 0
    /// Line items whose receipt or dictionary entry is unknown (the server sent inconsistent data); skipped.
    var unresolved = 0
}

struct PendingUpload: Sendable, Equatable {
    var uuid: String
    var localID: Int
    var photoPath: String?
    var createdAt: String?
}

/// Local persistence of the sync engine, over the app's `Database`. Foundation + SQLite only.
struct SyncStore: Sendable {
    let db: Database
    let paths: SyncPaths

    // MARK: - Meta (cursor, timestamps)

    func meta(_ key: String) async throws -> String? {
        try await db.queryOne("SELECT value FROM sync_meta WHERE key = ?", [.text(key)])?.string(0)
    }

    func setMeta(_ key: String, _ value: String?) async throws {
        if let value {
            try await db.run("INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try await db.run("DELETE FROM sync_meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Counters for the UI and the scheduler

    /// Local changes not yet acknowledged by the server (what an "after edits" sync is for).
    func unsentChangeCount() async throws -> Int {
        let row = try await db.queryOne("""
            SELECT (SELECT COUNT(*) FROM receipts WHERE sync_state = 'dirty' AND uuid IS NOT NULL
                        AND COALESCE(extraction_status, '') NOT IN ('pending_upload', 'upload_failed'))
                 + (SELECT COUNT(*) FROM line_items WHERE sync_state = 'dirty' AND uuid IS NOT NULL)
                 + (SELECT COUNT(*) FROM item_dictionary WHERE sync_state = 'dirty' AND uuid IS NOT NULL)
                 + (SELECT COUNT(*) FROM sync_tombstones WHERE pushed = 0)
            """)
        return row?.int(0) ?? 0
    }

    /// Receipts the server is still working on or that wait for their upload (the app polls while > 0).
    func inFlightCount() async throws -> Int {
        try await db.queryOne("""
            SELECT COUNT(*) FROM receipts WHERE deleted_at IS NULL
            AND extraction_status IN ('pending_upload', 'queued', 'processing')
            """)?.int(0) ?? 0
    }

    // MARK: - Push

    /// One chunk of the local changes of ONE entity kind (live records and tombstones). The engine sends all
    /// dictionary entries, then all receipts, then all line items, so references always exist on the server.
    func collectPush(_ entity: PushResult.Entity, limit: Int = 400) async throws -> PushBatch {
        let pathsCopy = paths
        return try await db.transaction { c in
            var batch = PushBatch()
            switch entity {
            case .dictionary: batch.dictionary = try Self.dirtyDictionary(c, limit: limit)
            case .receipt: batch.receipts = try Self.dirtyReceipts(c, paths: pathsCopy, limit: limit)
            case .lineItem: batch.lineItems = try Self.dirtyLineItems(c, limit: limit)
            }
            try Self.addTombstones(c, entity: entity, to: &batch, limit: limit)
            for d in batch.dictionary { batch.stamps[PushBatch.key(.dictionary, d.id)] = d.updatedAt }
            for r in batch.receipts { batch.stamps[PushBatch.key(.receipt, r.id)] = r.updatedAt }
            for l in batch.lineItems { batch.stamps[PushBatch.key(.lineItem, l.id)] = l.updatedAt }
            return batch
        }
    }

    private static func dirtyDictionary(_ c: SQLConnection, limit: Int) throws -> [WireDictionaryEntry] {
        try c.query("""
            SELECT uuid, canonical_name, display_name_de, translation_en, category, subcategory, item_group, aliases,
                   is_manual_override, needs_review, updated_at
            FROM item_dictionary WHERE sync_state = 'dirty' AND uuid IS NOT NULL ORDER BY id LIMIT ?
            """, [.from(limit)]).map { r in
            WireDictionaryEntry(
                id: r.string(0) ?? "", canonicalName: r.string(1) ?? "", displayNameDe: r.string(2), translationEn: r.string(3),
                category: r.string(4), subcategory: r.string(5), itemGroup: r.string(6), aliases: decodeStringArray(r.string(7)),
                isManualOverride: r.bool(8), needsReview: r.bool(9), updatedAt: r.string(10) ?? SyncDate.now()
            ).forPush()
        }
    }

    private static func dirtyReceipts(_ c: SQLConnection, paths: SyncPaths, limit: Int) throws -> [WireReceipt] {
        try c.query("""
            SELECT uuid, store, date, time, total, computed_sum, needs_review, review_reasons, reviewed_at, updated_at,
                   deleted_at, photo_location, source_image
            FROM receipts
            WHERE sync_state = 'dirty' AND uuid IS NOT NULL AND COALESCE(extraction_status, '') NOT IN ('pending_upload', 'upload_failed')
            ORDER BY id LIMIT ?
            """, [.from(limit)]).map { r in
            // Only read by the server when it does not know the receipt yet; it accepts `none` or `archived` only.
            // A photo that lives on this Mac (file really there) counts as archived, like the Python migration does.
            let hasFile = paths.resolve(r.string(12)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let location = (r.string(11) == "archived" || (r.string(11) == nil && hasFile)) && hasFile ? "archived" : "none"
            return WireReceipt(
                id: r.string(0) ?? "", store: r.string(1), date: r.string(2), time: r.string(3), total: r.double(4),
                computedSum: r.double(5), needsReview: r.bool(6), reviewReasons: decodeStringArray(r.string(7)),
                reviewedAt: r.string(8), updatedAt: r.string(9) ?? SyncDate.now(), deletedAt: r.string(10)
            ).forPush(photoLocation: location)
        }
    }

    private static func dirtyLineItems(_ c: SQLConnection, limit: Int) throws -> [WireLineItem] {
        try c.query("""
            SELECT li.uuid, r.uuid, d.uuid, li.position, li.raw_text, li.name_de, li.quantity, li.unit_price,
                   li.total_price, li.price_normalized, li.updated_at
            FROM line_items li
            JOIN receipts r ON r.id = li.receipt_id
            JOIN item_dictionary d ON d.id = li.item_dictionary_id
            WHERE li.sync_state = 'dirty' AND li.uuid IS NOT NULL AND r.uuid IS NOT NULL AND d.uuid IS NOT NULL
              AND COALESCE(r.extraction_status, '') NOT IN ('pending_upload', 'upload_failed')
            ORDER BY li.id LIMIT ?
            """, [.from(limit)]).map { r in
            WireLineItem(
                id: r.string(0) ?? "", receiptId: r.string(1) ?? "", itemDictionaryId: r.string(2) ?? "",
                position: r.int(3) ?? 0, rawText: r.string(4), nameDe: r.string(5), quantity: r.double(6) ?? 1,
                unitPrice: r.double(7) ?? 0, totalPrice: r.double(8) ?? 0, priceNormalized: r.bool(9),
                updatedAt: r.string(10) ?? SyncDate.now()
            ).forPush()
        }
    }

    /// Hard deletes become tombstone records built from the payload the delete trigger saved.
    private static func addTombstones(_ c: SQLConnection, entity kind: PushResult.Entity, to batch: inout PushBatch, limit: Int) throws {
        let rows = try c.query("SELECT entity, uuid, payload, deleted_at FROM sync_tombstones WHERE pushed = 0 AND entity = ? ORDER BY deleted_at LIMIT ?",
                               [.text(kind.rawValue), .from(limit)])
        for row in rows {
            guard let entity = row.string(0), let uuid = row.string(1), let payloadText = row.string(2), let deleted = row.string(3),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(payloadText.utf8))) as? [String: Any] else { continue }
            func str(_ k: String) -> String? { obj[k] as? String }
            func dbl(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
            func flag(_ k: String) -> Bool { ((obj[k] as? NSNumber)?.intValue ?? 0) != 0 }
            switch entity {
            case "line_item":
                guard let receipt = str("receipt_id"), let dict = str("item_dictionary_id") else {
                    try c.run("DELETE FROM sync_tombstones WHERE entity = ? AND uuid = ?", [.text(entity), .text(uuid)])
                    continue
                }
                batch.lineItems.append(WireLineItem(
                    id: uuid, receiptId: receipt, itemDictionaryId: dict, position: (obj["position"] as? NSNumber)?.intValue ?? 0,
                    rawText: str("raw_text"), nameDe: str("name_de"), quantity: dbl("quantity") ?? 1, unitPrice: dbl("unit_price") ?? 0,
                    totalPrice: dbl("total_price") ?? 0, priceNormalized: flag("price_normalized"), updatedAt: deleted, deletedAt: deleted))
                batch.stamps[PushBatch.key(.lineItem, uuid)] = deleted
            case "receipt":
                batch.receipts.append(WireReceipt(
                    id: uuid, store: str("store"), date: str("date"), time: str("time"), total: dbl("total"),
                    computedSum: dbl("computed_sum"), needsReview: flag("needs_review"),
                    reviewReasons: decodeStringArray(str("review_reasons")), reviewedAt: str("reviewed_at"),
                    updatedAt: deleted, deletedAt: deleted).forPush(photoLocation: flag("has_photo") ? "archived" : "none"))
                batch.stamps[PushBatch.key(.receipt, uuid)] = deleted
            case "dictionary":
                batch.dictionary.append(WireDictionaryEntry(
                    id: uuid, canonicalName: str("canonical_name") ?? "", displayNameDe: str("display_name_de"),
                    translationEn: str("translation_en"), category: str("category"), subcategory: str("subcategory"),
                    itemGroup: str("item_group"), aliases: decodeStringArray(str("aliases_json")),
                    isManualOverride: flag("is_manual_override"), needsReview: flag("needs_review"), updatedAt: deleted, deletedAt: deleted))
                batch.stamps[PushBatch.key(.dictionary, uuid)] = deleted
            default: break
            }
        }
    }

    /// Marks what the server acknowledged (`applied` or `stale`: either way our copy is no longer ahead of it) as
    /// synced, but only rows that were not edited again in the meantime; keeps `rejected` ones out of the dirty set
    /// (with the reason) until the user edits them again. Tombstones are forgotten, except receipts', which stay as
    /// the record of a permanent delete so that a later pull does not bring the receipt back.
    func applyPushResults(batch: PushBatch, response: PushResponse) async throws -> PushSummary {
        try await db.transaction { c in
            var summary = PushSummary()
            for result in response.results {
                guard let id = result.id else {
                    if result.status == .rejected { summary.rejected.append(result.reason ?? "rejected") }
                    continue
                }
                let table: String
                switch result.entity {
                case .dictionary: table = "item_dictionary"
                case .receipt: table = "receipts"
                case .lineItem: table = "line_items"
                }
                let stamp = batch.stamps[PushBatch.key(result.entity, id)]
                switch result.status {
                case .applied, .stale:
                    if result.status == .applied { summary.applied += 1 } else { summary.stale += 1 }
                    if let stamp {
                        try c.run("UPDATE \(table) SET sync_state = 'synced', sync_error = NULL WHERE uuid = ? AND sync_state = 'dirty' AND updated_at = ?",
                                  [.text(id), .text(stamp)])
                    }
                case .rejected:
                    let reason = result.reason ?? "rejected"
                    summary.rejected.append("\(result.entity.rawValue) \(id): \(reason)")
                    if let stamp {
                        try c.run("UPDATE \(table) SET sync_state = 'rejected', sync_error = ? WHERE uuid = ? AND sync_state = 'dirty' AND updated_at = ?",
                                  [.text(reason), .text(id), .text(stamp)])
                    }
                }
                if result.entity == .receipt {
                    try c.run("UPDATE sync_tombstones SET pushed = 1 WHERE entity = 'receipt' AND uuid = ?", [.text(id)])
                } else {
                    try c.run("DELETE FROM sync_tombstones WHERE entity = ? AND uuid = ? AND deleted_at = ?",
                              [.text(result.entity.rawValue), .text(id), .text(stamp ?? "")])
                }
            }
            return summary
        }
    }

    // MARK: - Pull

    /// Applies pulled pages (already merged: the last version of a record wins) in ONE transaction, with change
    /// tracking switched off so the sync's own writes are not mistaken for edits.
    func applyPull(dictionary: [WireDictionaryEntry], receipts: [WireReceipt], lineItems: [WireLineItem]) async throws -> ApplySummary {
        try await db.transaction { c in
            try c.run("INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('applying', '1')")
            var summary = ApplySummary()
            try PullApplier(c: c).run(dictionary: dictionary, receipts: receipts, lineItems: lineItems, into: &summary)
            try c.run("INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('applying', '0')")
            return summary
        }
    }

    // MARK: - Uploads

    /// A receipt for a photo that is prepared but not uploaded yet. It is `synced` (nothing to push: the upload
    /// creates the server's receipt) and invisible to push until the upload succeeded.
    func insertPendingUpload(uuid: String, createdAt: Date, photoPath: String, imageHash: String?) async throws -> Int {
        let stamp = SyncDate.string(from: createdAt)
        return Int(try await db.run("""
            INSERT INTO receipts (uuid, created_at, updated_at, source_image, image_hash, sync_state, photo_location,
                                  extraction_status, needs_review, review_reasons)
            VALUES (?, ?, ?, ?, ?, 'synced', 'server', 'pending_upload', 0, '[]')
            """, [.text(uuid), .text(stamp), .text(stamp), .text(photoPath), .from(imageHash)]))
    }

    func pendingUploads() async throws -> [PendingUpload] {
        try await db.query("""
            SELECT uuid, id, source_image, created_at FROM receipts
            WHERE extraction_status = 'pending_upload' AND uuid IS NOT NULL ORDER BY id
            """).map { PendingUpload(uuid: $0.string(0) ?? "", localID: $0.int(1) ?? 0, photoPath: $0.string(2), createdAt: $0.string(3)) }
    }

    func pendingUpload(uuid: String) async throws -> PendingUpload? {
        try await pendingUploads().first { $0.uuid == uuid }
    }

    /// The server has the photo: take over what it says about the receipt (status, sha) without touching content.
    func markUploaded(uuid: String, server: WireReceipt) async throws {
        try await db.run("""
            UPDATE receipts SET extraction_status = ?, extraction_error = ?, photo_location = ?, photo_sha256 = ?,
                updated_at = ?, sync_state = 'synced', sync_error = NULL WHERE uuid = ?
            """, [.text(server.extractionStatus ?? "queued"), .from(server.extractionError), .text(server.photoLocation ?? "server"),
                  .from(server.photoSha256), .text(server.updatedAt), .text(uuid)])
    }

    /// `permanent`: the server will never take these bytes (not an image, too large): needs the user.
    func markUploadFailed(uuid: String, message: String, permanent: Bool) async throws {
        try await db.run("UPDATE receipts SET extraction_error = ?, extraction_status = ? WHERE uuid = ?",
                         [.text(message), .text(permanent ? "upload_failed" : "pending_upload"), .text(uuid)])
    }

    /// Back into the upload queue (user pressed Retry on an `upload_failed` receipt).
    func requeueUpload(localID: Int) async throws {
        try await db.run("UPDATE receipts SET extraction_status = 'pending_upload', extraction_error = NULL WHERE id = ? AND extraction_status = 'upload_failed'", [.from(localID)])
    }

    /// Drops a local receipt that never reached the server (the server already has the same photo).
    /// Returns its photo path. No tombstone: the server never heard of this uuid.
    func discardLocalReceipt(uuid: String) async throws -> String? {
        try await db.transaction { c in
            let path = try c.queryOne("SELECT source_image FROM receipts WHERE uuid = ?", [.text(uuid)])?.string(0)
            try c.run("INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('applying', '1')")
            try c.run("DELETE FROM line_items WHERE receipt_id IN (SELECT id FROM receipts WHERE uuid = ?)", [.text(uuid)])
            try c.run("DELETE FROM receipts WHERE uuid = ?", [.text(uuid)])
            try c.run("INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('applying', '0')")
            return path
        }
    }

    func localID(forUUID uuid: String) async throws -> Int? {
        try await db.queryOne("SELECT id FROM receipts WHERE uuid = ?", [.text(uuid)])?.int(0)
    }

    // MARK: - Archive

    struct ArchiveInfo: Sendable, Equatable {
        var localID: Int
        var sourceImage: String?
        var acceptFailed: Bool
        var photoLocation: String?
    }

    func archiveInfo(uuid: String) async throws -> ArchiveInfo? {
        try await db.queryOne("SELECT id, source_image, archive_accept_failed, photo_location FROM receipts WHERE uuid = ?", [.text(uuid)])
            .map { ArchiveInfo(localID: $0.int(0) ?? 0, sourceImage: $0.string(1), acceptFailed: $0.bool(2), photoLocation: $0.string(3)) }
    }

    /// The verified copy is on disk: the receipt now shows it from there. (Does not claim `archived`: the server decides.)
    func setLocalPhoto(uuid: String, path: String) async throws {
        try await db.run("UPDATE receipts SET source_image = ? WHERE uuid = ?", [.text(path), .text(uuid)])
    }

    func markArchived(uuid: String, path: String) async throws {
        try await db.run("UPDATE receipts SET source_image = ?, photo_location = 'archived' WHERE uuid = ?", [.text(path), .text(uuid)])
    }

    /// The user's explicit "give up on this failed receipt and archive its photo" (the only way `accept_failed` is sent).
    func setAcceptFailed(localID: Int, _ value: Bool) async throws {
        try await db.run("UPDATE receipts SET archive_accept_failed = ? WHERE id = ?", [.from(value), .from(localID)])
    }

    func uuid(forLocalReceipt id: Int) async throws -> String? {
        try await db.queryOne("SELECT uuid FROM receipts WHERE id = ?", [.from(id)])?.string(0)
    }
}

// MARK: - Applying a pull

/// The body of `SyncStore.applyPull`, on a synchronous connection inside the transaction.
private struct PullApplier {
    let c: SQLConnection

    func run(dictionary: [WireDictionaryEntry], receipts: [WireReceipt], lineItems: [WireLineItem], into summary: inout ApplySummary) throws {
        // 1. dictionary (live), 2. receipts, 3. line items, 4. dictionary tombstones last: a merge delivers the
        // line items' new dictionary id and the merged-away entry's tombstone together.
        for entry in dictionary where entry.deletedAt == nil { try upsertDictionary(entry, &summary) }
        for receipt in receipts { try upsertReceipt(receipt, &summary) }
        for item in lineItems { try upsertLineItem(item, &summary) }
        for entry in dictionary where entry.deletedAt != nil { try tombstoneDictionary(entry, &summary) }
    }

    // MARK: helpers

    private func localTombstone(_ entity: String, _ uuid: String) throws -> (deleted: Date?, pushed: Bool)? {
        guard let row = try c.queryOne("SELECT deleted_at, pushed FROM sync_tombstones WHERE entity = ? AND uuid = ?", [.text(entity), .text(uuid)]) else { return nil }
        return (SyncDate.parse(row.string(0)), row.bool(1))
    }

    private func id(of table: String, uuid: String) throws -> Int? {
        try c.queryOne("SELECT id FROM \(table) WHERE uuid = ?", [.text(uuid)])?.int(0)
    }

    // MARK: dictionary

    private func upsertDictionary(_ e: WireDictionaryEntry, _ summary: inout ApplySummary) throws {
        let serverStamp = SyncDate.parse(e.updatedAt)
        if let t = try localTombstone("dictionary", e.id),
           SyncMerge.localDeleteWins(deletedAt: t.deleted, serverUpdatedAt: serverStamp) { return }
        let aliases = encodeStringArray(e.aliases)
        let local = try c.queryOne("SELECT id, sync_state, updated_at FROM item_dictionary WHERE uuid = ?", [.text(e.id)])
        guard let local, let localId = local.int(0) else {
            try insertDictionary(e, aliases: aliases)
            summary.dictionary += 1
            return
        }
        // server-owned counters always follow the server
        try c.run("UPDATE item_dictionary SET times_seen = ?, last_seen_at = COALESCE(?, last_seen_at) WHERE id = ?",
                  [.from(e.timesSeen ?? 1), .from(e.lastSeenAt), .from(localId)])
        let decision = SyncMerge.decide(localUpdatedAt: SyncDate.parse(local.string(2)), dirty: local.string(1) == "dirty", serverUpdatedAt: serverStamp)
        guard decision == .takeServer else { return }
        // a different local row may hold the name (a local-only entry the server never heard of)
        try freeName(e.canonicalName, except: localId)
        try c.run("""
            UPDATE item_dictionary SET canonical_name = ?, display_name_de = ?, translation_en = ?, category = ?, subcategory = ?,
                item_group = ?, aliases = ?, is_manual_override = ?, needs_review = ?, updated_at = ?, sync_state = 'synced', sync_error = NULL
            WHERE id = ?
            """, [.text(e.canonicalName), .from(e.displayNameDe), .from(e.translationEn), .from(e.category), .from(e.subcategory),
                  .from(e.itemGroup), .text(aliases), .from(e.isManualOverride), .from(e.needsReview), .text(e.updatedAt), .from(localId)])
        summary.dictionary += 1
    }

    private func insertDictionary(_ e: WireDictionaryEntry, aliases: String) throws {
        let clash = try c.queryOne("SELECT id FROM item_dictionary WHERE canonical_name = ?", [.text(e.canonicalName)])?.int(0)
        if let clash {
            // The name belongs to a different local row (never synced under this uuid). Park its name, add the server's
            // entry and move the clashing row's items over; the clash is then gone and nothing is duplicated.
            try c.run("UPDATE item_dictionary SET canonical_name = canonical_name || ' #moved-' || id WHERE id = ?", [.from(clash)])
        }
        let newId = try c.run("""
            INSERT INTO item_dictionary (uuid, canonical_name, display_name_de, translation_en, category, subcategory, item_group, aliases,
                is_manual_override, needs_review, times_seen, created_at, last_seen_at, updated_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
            """, [.text(e.id), .text(e.canonicalName), .from(e.displayNameDe), .from(e.translationEn), .from(e.category), .from(e.subcategory),
                  .from(e.itemGroup), .text(aliases), .from(e.isManualOverride), .from(e.needsReview), .from(e.timesSeen ?? 1),
                  .from(e.createdAt ?? e.updatedAt), .from(e.lastSeenAt ?? e.updatedAt), .text(e.updatedAt)])
        if let clash {
            // the moved items are a local change as far as the server is concerned
            try c.run("UPDATE line_items SET item_dictionary_id = ?, sync_state = 'dirty', updated_at = ? WHERE item_dictionary_id = ?",
                      [.integer(newId), .text(SyncDate.now()), .from(clash)])
            try c.run("DELETE FROM item_dictionary WHERE id = ?", [.from(clash)])
        }
    }

    /// Makes `name` free for the entry `except` by parking another row that holds it.
    private func freeName(_ name: String, except id: Int) throws {
        if let other = try c.queryOne("SELECT id FROM item_dictionary WHERE canonical_name = ? AND id != ?", [.text(name), .from(id)])?.int(0) {
            try c.run("UPDATE item_dictionary SET canonical_name = canonical_name || ' #moved-' || id WHERE id = ?", [.from(other)])
        }
    }

    private func tombstoneDictionary(_ e: WireDictionaryEntry, _ summary: inout ApplySummary) throws {
        guard let row = try c.queryOne("SELECT id, sync_state, updated_at FROM item_dictionary WHERE uuid = ?", [.text(e.id)]),
              let localId = row.int(0) else { return }
        let decision = SyncMerge.decide(localUpdatedAt: SyncDate.parse(row.string(2)), dirty: row.string(1) == "dirty", serverUpdatedAt: SyncDate.parse(e.updatedAt))
        guard decision == .takeServer else { return }
        let used = try c.queryOne("SELECT COUNT(*) FROM line_items WHERE item_dictionary_id = ?", [.from(localId)])?.int(0) ?? 0
        guard used == 0 else { return }   // still referenced by a local item: keep it rather than break the item
        try c.run("DELETE FROM item_dictionary WHERE id = ?", [.from(localId)])
        summary.deletedLocally += 1
    }

    // MARK: receipts

    private func upsertReceipt(_ r: WireReceipt, _ summary: inout ApplySummary) throws {
        // a receipt the user deleted permanently stays gone
        if try localTombstone("receipt", r.id) != nil { return }
        let reasons = encodeStringArray(r.reviewReasons)
        guard let local = try c.queryOne("SELECT id, sync_state, updated_at FROM receipts WHERE uuid = ?", [.text(r.id)]),
              let localId = local.int(0) else {
            try c.run("""
                INSERT INTO receipts (uuid, store, date, time, total, computed_sum, needs_review, review_reasons, created_at, reviewed_at, deleted_at,
                    updated_at, photo_location, photo_sha256, extraction_status, extraction_error, sync_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
                """, [.text(r.id), .from(r.store), .from(r.date), .from(r.time), .from(r.total), .from(r.computedSum), .from(r.needsReview),
                      .text(reasons), .from(r.createdAt ?? r.updatedAt), .from(r.reviewedAt), .from(r.deletedAt), .text(r.updatedAt),
                      .from(r.photoLocation), .from(r.photoSha256), .from(r.extractionStatus), .from(r.extractionError)])
            summary.receipts += 1
            return
        }
        // server-owned fields always follow the server, next to a local edit too
        try c.run("UPDATE receipts SET photo_location = ?, photo_sha256 = ?, extraction_status = ?, extraction_error = ? WHERE id = ?",
                  [.from(r.photoLocation), .from(r.photoSha256), .from(r.extractionStatus), .from(r.extractionError), .from(localId)])
        let decision = SyncMerge.decide(localUpdatedAt: SyncDate.parse(local.string(2)), dirty: local.string(1) == "dirty", serverUpdatedAt: SyncDate.parse(r.updatedAt))
        guard decision == .takeServer else { return }
        try c.run("""
            UPDATE receipts SET store = ?, date = ?, time = ?, total = ?, computed_sum = ?, needs_review = ?, review_reasons = ?,
                reviewed_at = ?, deleted_at = ?, updated_at = ?, sync_state = 'synced', sync_error = NULL WHERE id = ?
            """, [.from(r.store), .from(r.date), .from(r.time), .from(r.total), .from(r.computedSum), .from(r.needsReview), .text(reasons),
                  .from(r.reviewedAt), .from(r.deletedAt), .text(r.updatedAt), .from(localId)])
        summary.receipts += 1
    }

    // MARK: line items

    private func upsertLineItem(_ l: WireLineItem, _ summary: inout ApplySummary) throws {
        let serverStamp = SyncDate.parse(l.updatedAt)
        if try receiptIsPurged(l.receiptId) { return }
        if let t = try localTombstone("line_item", l.id), SyncMerge.localDeleteWins(deletedAt: t.deleted, serverUpdatedAt: serverStamp) { return }
        let local = try c.queryOne("SELECT id, sync_state, updated_at FROM line_items WHERE uuid = ?", [.text(l.id)])
        let decision = SyncMerge.decide(localUpdatedAt: SyncDate.parse(local?.string(2)), dirty: local?.string(1) == "dirty", serverUpdatedAt: serverStamp)
        guard decision == .takeServer else { return }
        if l.deletedAt != nil {
            if let localId = local?.int(0) {
                try c.run("DELETE FROM line_items WHERE id = ?", [.from(localId)])
                summary.deletedLocally += 1
            }
            return
        }
        guard let receiptId = try id(of: "receipts", uuid: l.receiptId), let dictId = try id(of: "item_dictionary", uuid: l.itemDictionaryId) else {
            summary.unresolved += 1
            return
        }
        if let localId = local?.int(0) {
            try c.run("""
                UPDATE line_items SET receipt_id = ?, item_dictionary_id = ?, position = ?, raw_text = ?, name_de = ?, quantity = ?, unit_price = ?,
                    total_price = ?, price_normalized = ?, updated_at = ?, sync_state = 'synced', sync_error = NULL WHERE id = ?
                """, [.from(receiptId), .from(dictId), .from(l.position), .from(l.rawText), .from(l.nameDe), .from(l.quantity), .from(l.unitPrice),
                      .from(l.totalPrice), .from(l.priceNormalized), .text(l.updatedAt), .from(localId)])
        } else {
            try c.run("""
                INSERT INTO line_items (uuid, receipt_id, item_dictionary_id, position, raw_text, name_de, quantity, unit_price, total_price,
                    price_normalized, updated_at, sync_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
                """, [.text(l.id), .from(receiptId), .from(dictId), .from(l.position), .from(l.rawText), .from(l.nameDe), .from(l.quantity),
                      .from(l.unitPrice), .from(l.totalPrice), .from(l.priceNormalized), .text(l.updatedAt)])
        }
        summary.lineItems += 1
    }

    private func receiptIsPurged(_ uuid: String) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sync_tombstones WHERE entity = 'receipt' AND uuid = ?", [.text(uuid)]) != nil
    }
}
