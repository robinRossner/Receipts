import Foundation
@testable import ReceiptsApp

/// An in-memory stand-in for the receipts backend that follows docs/api/receipts.md closely enough for the sync
/// engine's tests (the real server is exercised by the e2e test): per-record last write wins on push, change sequence
/// cursor on pull, photo storage, and the archive rules (sha match + extraction done / accept_failed).
final class FakeReceiptsServer: ReceiptsAPI, @unchecked Sendable {
    private let lock = NSLock()

    // data
    var receipts: [String: WireReceipt] = [:]
    var items: [String: WireLineItem] = [:]
    var dictionary: [String: WireDictionaryEntry] = [:]
    var photos: [String: Data] = [:]
    /// User-added category paths (append-only, like the real server's).
    var taxonomyAdditions: [WireTaxonomyAddition] = []
    /// Simulates a server from before the flagged-categories feature: pulls carry neither the flag fields nor the additions.
    var legacyServer = false
    private var seq: [String: Int] = [:]
    private var counter = 0

    // scripting / observation
    var offline = false
    var failures: [String: ReceiptsAPIError] = [:]      // method name -> error (once)
    var corruptDownloads = false
    var pushLog: [PushRequest] = []
    var confirmCalls: [(id: String, sha256: String, deviceId: String, acceptFailed: Bool)] = []
    var archiveSyncCalls = 0
    var archivePendingCalls = 0
    var downloadCalls = 0
    var uploadCalls: [String] = []
    var pullSinceLog: [String?] = []
    var forcedStatus: ServerStatus?

    private func guarded<T>(_ name: String, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if offline { throw ReceiptsAPIError.transport("offline") }
        if let error = failures.removeValue(forKey: name) { throw error }
        return try body()
    }

    private func bump(_ key: String) { counter += 1; seq[key] = counter }
    private func now() -> String { SyncDate.now() }
    private func newer(_ a: String, than b: String) -> Bool { (SyncDate.parse(a) ?? .distantPast) > (SyncDate.parse(b) ?? .distantPast) }

    // MARK: seeding helpers (act as "another device" or the extraction worker)

    func seedReceipt(_ r: WireReceipt) { lock.lock(); receipts[r.id] = r; bump("receipt:" + r.id); lock.unlock() }
    func seedItem(_ l: WireLineItem) { lock.lock(); items[l.id] = l; bump("line_item:" + l.id); lock.unlock() }
    func seedDictionary(_ d: WireDictionaryEntry) { lock.lock(); dictionary[d.id] = d; bump("dictionary:" + d.id); lock.unlock() }

    /// What the extraction worker does: fill the receipt without touching updated_at.
    func finishExtraction(_ id: String, store: String = "Edeka", status: String = "done", error: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard var r = receipts[id] else { return }
        r.store = store; r.extractionStatus = status; r.extractionError = error
        if status == "done" { r.date = "2026-03-01"; r.total = 5.0; r.computedSum = 5.0 }
        receipts[id] = r
        bump("receipt:" + id)
    }

    // MARK: ReceiptsAPI

    func health() async throws { try guarded("health") {} }

    func status() async throws -> ServerStatus {
        try guarded("status") {
            if let forcedStatus { return forcedStatus }
            let pending = receipts.values.filter { $0.photoLocation == "server" }
            return ServerStatus(unarchivedCount: pending.count, unarchivedBytes: 0, archiveOverdue: false, diskWarning: false)
        }
    }

    func uploadPhoto(id: String, data: Data, mediaType: String, createdAt: Date?) async throws -> UploadResponse {
        try guarded("upload") {
            uploadCalls.append(id)
            let sha = Sha256.hex(data)
            if let existing = receipts[id] {
                if existing.photoSha256 == sha || existing.photoLocation == "archived" { return UploadResponse(created: false, receipt: existing) }
                throw ReceiptsAPIError.http(status: 409, code: "photo_conflict", message: "other bytes", extra: [:])
            }
            if let dup = receipts.values.first(where: { $0.photoSha256 == sha }) {
                throw ReceiptsAPIError.http(status: 409, code: "duplicate_image", message: "dup", extra: ["duplicate_of": dup.id])
            }
            let stamp = createdAt.map(SyncDate.string(from:)) ?? now()
            var r = WireReceipt(id: id, createdAt: stamp, photoLocation: "server", photoSha256: sha, extractionStatus: "queued", updatedAt: stamp)
            r.photoBytes = data.count
            receipts[id] = r
            photos[id] = data
            bump("receipt:" + id)
            return UploadResponse(created: true, receipt: r)
        }
    }

    func retryExtraction(id: String) async throws {
        try guarded("retry") {
            guard var r = receipts[id] else { throw ReceiptsAPIError.http(status: 404, code: "receipt_not_found", message: nil, extra: [:]) }
            r.extractionStatus = "queued"; r.extractionError = nil
            receipts[id] = r; bump("receipt:" + id)
        }
    }

    func push(_ request: PushRequest) async throws -> PushResponse {
        try guarded("push") {
            pushLog.append(request)
            var results: [PushResult] = []
            for a in request.taxonomyAdditions ?? [] {
                if taxonomyAdditions.contains(where: { $0.label.lowercased() == a.label.lowercased() }) {
                    results.append(.init(entity: .taxonomyAddition, id: a.label, status: .stale))
                } else {
                    taxonomyAdditions.append(a)
                    results.append(.init(entity: .taxonomyAddition, id: a.label, status: .applied))
                }
            }
            for d in request.dictionary {
                if let old = dictionary[d.id], !newer(d.updatedAt, than: old.updatedAt) { results.append(.init(entity: .dictionary, id: d.id, status: .stale)); continue }
                if d.deletedAt == nil, dictionary.values.contains(where: { $0.canonicalName == d.canonicalName && $0.id != d.id && $0.deletedAt == nil }) {
                    results.append(.init(entity: .dictionary, id: d.id, status: .rejected, reason: "canonical_name already used")); continue
                }
                var merged = d
                // Same rule as the real server (docs/api/receipts.md, "Flagged categories"): an absent flag keeps the stored
                // value, unless the category changed (then the flag is resolved); a cleared flag drops the suggestion.
                if let old = dictionary[d.id], d.categoryFlagged == nil {
                    let same = old.category == d.category && old.subcategory == d.subcategory && old.itemGroup == d.itemGroup
                    merged.categoryFlagged = same ? old.categoryFlagged : false
                    merged.suggestedCategory = same ? old.suggestedCategory : nil
                    merged.suggestedParent = same ? old.suggestedParent : nil
                }
                if merged.categoryFlagged != true { merged.suggestedCategory = nil; merged.suggestedParent = nil }
                merged.timesSeen = dictionary[d.id]?.timesSeen ?? 1
                dictionary[d.id] = merged; bump("dictionary:" + d.id)
                results.append(.init(entity: .dictionary, id: d.id, status: .applied))
            }
            for r in request.receipts {
                if let old = receipts[r.id], !newer(r.updatedAt, than: old.updatedAt) { results.append(.init(entity: .receipt, id: r.id, status: .stale)); continue }
                if !["none", "archived"].contains(r.photoLocation ?? "none") {
                    results.append(.init(entity: .receipt, id: r.id, status: .rejected, reason: "invalid: photo_location")); continue
                }
                var merged = receipts[r.id] ?? WireReceipt(id: r.id, createdAt: r.updatedAt, photoLocation: r.photoLocation, extractionStatus: "done", updatedAt: r.updatedAt)
                merged.store = r.store; merged.date = r.date; merged.time = r.time; merged.total = r.total; merged.computedSum = r.computedSum
                merged.needsReview = r.needsReview; merged.reviewReasons = r.reviewReasons; merged.reviewedAt = r.reviewedAt
                merged.deletedAt = r.deletedAt; merged.updatedAt = r.updatedAt
                receipts[r.id] = merged; bump("receipt:" + r.id)
                results.append(.init(entity: .receipt, id: r.id, status: .applied))
            }
            for l in request.lineItems {
                guard receipts[l.receiptId] != nil else { results.append(.init(entity: .lineItem, id: l.id, status: .rejected, reason: "unknown receipt_id")); continue }
                guard dictionary[l.itemDictionaryId] != nil else { results.append(.init(entity: .lineItem, id: l.id, status: .rejected, reason: "unknown item_dictionary_id")); continue }
                if let old = items[l.id], !newer(l.updatedAt, than: old.updatedAt) { results.append(.init(entity: .lineItem, id: l.id, status: .stale)); continue }
                items[l.id] = l; bump("line_item:" + l.id)
                results.append(.init(entity: .lineItem, id: l.id, status: .applied))
            }
            return PushResponse(serverTime: now(), results: results)
        }
    }

    func pull(since: String?, limit: Int) async throws -> PullResponse {
        try guarded("pull") {
            pullSinceLog.append(since)
            let from = since.flatMap { $0.hasPrefix("c") ? Int($0.dropFirst()) : nil } ?? 0
            let all = seq.filter { $0.value > from }.sorted { $0.value < $1.value }
            let page = Array(all.prefix(limit))
            var d: [WireDictionaryEntry] = [], r: [WireReceipt] = [], l: [WireLineItem] = []
            for (key, _) in page {
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0] {
                case "dictionary":
                    var entry = dictionary[parts[1]]!
                    if legacyServer { entry.categoryFlagged = nil; entry.suggestedCategory = nil; entry.suggestedParent = nil }
                    d.append(entry)
                case "receipt": r.append(receipts[parts[1]]!)
                default: l.append(items[parts[1]]!)
                }
            }
            let cursor = page.last.map { "c\($0.value)" } ?? since ?? "c0"
            return PullResponse(cursor: cursor, hasMore: all.count > page.count, serverTime: now(), taxonomyVersion: nil, dictionary: d, receipts: r, lineItems: l,
                                taxonomyAdditions: legacyServer ? nil : taxonomyAdditions)
        }
    }

    func archivePending() async throws -> [ArchivePendingPhoto] {
        try guarded("archivePending") {
            archivePendingCalls += 1
            return receipts.values.filter { $0.photoLocation == "server" }.sorted { $0.id < $1.id }.map { r in
                let status = r.extractionStatus ?? "queued"
                return ArchivePendingPhoto(
                    id: r.id, sha256: r.photoSha256 ?? "", bytes: r.photoBytes, mediaType: "image/jpeg", uploadedAt: r.createdAt,
                    extractionStatus: status, archivable: status == "done",
                    blockedReason: status == "done" ? nil : (status == "failed" ? "extraction_failed" : "extraction_pending"),
                    download: "/api/v1/receipts/\(r.id)/photo")
            }
        }
    }

    func downloadPhoto(path: String) async throws -> DownloadedPhoto {
        try guarded("download") {
            downloadCalls += 1
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            guard var data = photos[id] else { throw ReceiptsAPIError.http(status: 410, code: "photo_archived", message: nil, extra: [:]) }
            if corruptDownloads { data[data.startIndex] ^= 0xFF }
            return DownloadedPhoto(data: data, mediaType: "image/jpeg", headerSHA256: receipts[id]?.photoSha256)
        }
    }

    func archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Bool) async throws -> ArchiveConfirmResponse {
        try guarded("confirm") {
            confirmCalls.append((id, sha256, deviceId, acceptFailed))
            guard var r = receipts[id] else { throw ReceiptsAPIError.http(status: 404, code: "receipt_not_found", message: nil, extra: [:]) }
            if r.photoLocation == "archived" { return ArchiveConfirmResponse(status: "already_archived", receiptId: id) }
            guard sha256 == r.photoSha256 else { throw ReceiptsAPIError.http(status: 409, code: "sha256_mismatch", message: nil, extra: [:]) }
            switch r.extractionStatus {
            case "done": break
            case "failed": if !acceptFailed { throw ReceiptsAPIError.http(status: 409, code: "extraction_failed", message: nil, extra: [:]) }
            default: throw ReceiptsAPIError.http(status: 409, code: "extraction_pending", message: nil, extra: [:])
            }
            r.photoLocation = "archived"; r.archivedAt = now()
            receipts[id] = r; photos[id] = nil; bump("receipt:" + id)
            return ArchiveConfirmResponse(status: "archived", receiptId: id)
        }
    }

    func archiveSync(deviceId: String) async throws { try guarded("archiveSync") { archiveSyncCalls += 1 } }
}

/// A fixed JPEG-looking blob (the fake server never decodes images).
func fakePhoto(_ seed: UInt8 = 1, size: Int = 600) -> Data {
    var d = Data([0xFF, 0xD8, 0xFF, 0xE0])
    d.append(contentsOf: (0..<size).map { UInt8(truncatingIfNeeded: Int($0) &* 31 &+ Int(seed)) })
    d.append(contentsOf: [0xFF, 0xD9])
    return d
}
