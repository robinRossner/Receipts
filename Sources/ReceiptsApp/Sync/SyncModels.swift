import Foundation

// Wire types of docs/api/receipts.md. JSON is snake_case; the coders below convert. Timestamps stay
// strings (see SyncDate: compare instants, not text).

enum WireCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

struct WireDictionaryEntry: Codable, Equatable, Sendable {
    var id: String
    var legacyId: Int?
    var canonicalName: String
    var displayNameDe: String?
    var translationEn: String?
    var category: String?
    var subcategory: String?
    var itemGroup: String?
    var aliases: [String]
    var isManualOverride: Bool
    var needsReview: Bool
    var timesSeen: Int?
    var createdAt: String?
    var lastSeenAt: String?
    var updatedAt: String
    var deletedAt: String?

    /// What a push may carry: the server ignores the rest, and omitting it keeps the request small.
    func forPush() -> WireDictionaryEntry {
        var c = self
        c.legacyId = nil; c.timesSeen = nil; c.createdAt = nil; c.lastSeenAt = nil
        return c
    }
}

struct WireReceipt: Codable, Equatable, Sendable {
    var id: String
    var legacyId: Int?
    var store: String?
    var date: String?
    var time: String?
    var total: Double?
    var computedSum: Double?
    var needsReview: Bool
    var reviewReasons: [String]
    var reviewedAt: String?
    var createdAt: String?
    var photoLocation: String?
    var photoSha256: String?
    var photoBytes: Int?
    var photoMediaType: String?
    var uploadedAt: String?
    var archivedAt: String?
    var extractionStatus: String?
    var extractionAttempts: Int?
    var extractionError: String?
    var extractionProvider: String?
    var extractionCompletedAt: String?
    var updatedAt: String
    var deletedAt: String?

    /// Client-writable fields only. `photoLocation` is read by the server only when it does not know
    /// the receipt yet and then only accepts `none` or `archived` (a push saying `server` is rejected).
    func forPush(photoLocation: String) -> WireReceipt {
        WireReceipt(id: id, store: store, date: date, time: time, total: total, computedSum: computedSum,
                    needsReview: needsReview, reviewReasons: reviewReasons, reviewedAt: reviewedAt,
                    photoLocation: photoLocation, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    init(id: String, store: String? = nil, date: String? = nil, time: String? = nil, total: Double? = nil,
         computedSum: Double? = nil, needsReview: Bool = false, reviewReasons: [String] = [], reviewedAt: String? = nil,
         createdAt: String? = nil, photoLocation: String? = nil, photoSha256: String? = nil, extractionStatus: String? = nil,
         extractionError: String? = nil, updatedAt: String, deletedAt: String? = nil) {
        self.id = id; self.store = store; self.date = date; self.time = time; self.total = total
        self.computedSum = computedSum; self.needsReview = needsReview; self.reviewReasons = reviewReasons
        self.reviewedAt = reviewedAt; self.createdAt = createdAt; self.photoLocation = photoLocation
        self.photoSha256 = photoSha256; self.extractionStatus = extractionStatus; self.extractionError = extractionError
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

struct WireLineItem: Codable, Equatable, Sendable {
    var id: String
    var legacyId: Int?
    var receiptId: String
    var itemDictionaryId: String
    var position: Int
    var rawText: String?
    var nameDe: String?
    var quantity: Double
    var unitPrice: Double
    var totalPrice: Double
    var priceNormalized: Bool
    var updatedAt: String
    var deletedAt: String?

    func forPush() -> WireLineItem {
        var c = self
        c.legacyId = nil
        return c
    }
}

// MARK: - Push / pull

struct PushRequest: Codable, Sendable {
    var deviceId: String
    var dictionary: [WireDictionaryEntry] = []
    var receipts: [WireReceipt] = []
    var lineItems: [WireLineItem] = []

    var isEmpty: Bool { dictionary.isEmpty && receipts.isEmpty && lineItems.isEmpty }
}

struct PushResult: Codable, Equatable, Sendable {
    enum Entity: String, Codable, Sendable { case dictionary, receipt, lineItem = "line_item" }
    enum Status: String, Codable, Sendable { case applied, stale, rejected }
    var entity: Entity
    var id: String?
    var status: Status
    var reason: String?
}

struct PushResponse: Codable, Sendable {
    var serverTime: String
    var results: [PushResult]
}

struct PullResponse: Codable, Sendable {
    var cursor: String
    var hasMore: Bool
    var serverTime: String?
    var taxonomyVersion: String?
    var dictionary: [WireDictionaryEntry]
    var receipts: [WireReceipt]
    var lineItems: [WireLineItem]
}

// MARK: - Upload, archive, status

struct UploadResponse: Codable, Sendable {
    var created: Bool
    var receipt: WireReceipt
}

struct ArchivePendingPhoto: Codable, Equatable, Sendable {
    var id: String
    var sha256: String
    var bytes: Int?
    var mediaType: String?
    var uploadedAt: String?
    var extractionStatus: String?
    var archivable: Bool
    var blockedReason: String?
    var download: String
}

struct ArchivePendingResponse: Codable, Sendable {
    var count: Int
    var photos: [ArchivePendingPhoto]
}

struct ArchiveConfirmRequest: Codable, Sendable {
    var sha256: String
    var deviceId: String
    var acceptFailed: Bool?
}

struct ArchiveConfirmResponse: Codable, Equatable, Sendable {
    var status: String   // archived | already_archived
    var receiptId: String
}

struct ArchiveSyncRequest: Codable, Sendable {
    var deviceId: String
}

struct DownloadedPhoto: Sendable {
    var data: Data
    var mediaType: String?
    /// The server's `X-Content-SHA256` header. Informational: the archive compares the sha256 of the file it wrote.
    var headerSHA256: String?
}

/// `GET /status`: what the banner shows. Unknown extra fields are ignored.
struct ServerStatus: Codable, Equatable, Sendable {
    struct Queue: Codable, Equatable, Sendable {
        var queued: Int = 0
        var processing: Int = 0
        var done: Int = 0
        var failed: Int = 0
    }
    struct LLM: Codable, Equatable, Sendable {
        var provider: String?
        var credentialConfigured: Bool?
    }
    var serverTime: String?
    var lastArchiveSyncAt: String?
    var archiveDeviceId: String?
    var unarchivedCount: Int
    var unarchivedBytes: Int
    var oldestUnarchivedAt: String?
    var diskFreeBytes: Int?
    var diskTotalBytes: Int?
    var archiveReminderDays: Int?
    var diskWarningFreeMb: Int?
    var archiveOverdue: Bool
    var diskWarning: Bool
    var queue: Queue?
    var llm: LLM?
}
