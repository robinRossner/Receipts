import Foundation

/// Mirrors production `ReceiptProcessing` (Models/Receipt.swift). nil on a receipt means an ordinary finished one.
public enum LabProcessing: Hashable, Sendable {
    case waitingForUpload(String?)
    case uploadFailed(String?)
    case processing
    case failed(String?)

    public var label: String {
        switch self {
        case .waitingForUpload: return "Waiting to upload"
        case .uploadFailed: return "Upload failed"
        case .processing: return "Reading receipt on the server…"
        case .failed: return "Could not read this receipt"
        }
    }

    public var isActive: Bool {
        switch self {
        case .waitingForUpload, .processing: return true
        case .uploadFailed, .failed: return false
        }
    }
}

/// Mirrors production `LineItemDetail`. `nameDe` is the German text from the receipt, `translationEn` the English one.
public struct LabLineItem: Identifiable, Hashable, Sendable {
    public let id: Int
    /// Same value = same product. Production groups repeats of a product in a bracket with "2×".
    public let itemDictionaryId: Int
    public var rawText: String?
    public var nameDe: String?
    public var quantity: Double
    public var unitPrice: Double
    public var translationEn: String?
    public var category: String
    public var subcategory: String
    public var itemGroup: String
    public var needsReview: Bool

    public var totalPrice: Double { ((quantity * unitPrice) * 100).rounded() / 100 }

    public init(id: Int, itemDictionaryId: Int, rawText: String?, nameDe: String?, quantity: Double, unitPrice: Double,
                translationEn: String?, category: String, subcategory: String, itemGroup: String, needsReview: Bool = false) {
        self.id = id; self.itemDictionaryId = itemDictionaryId; self.rawText = rawText; self.nameDe = nameDe
        self.quantity = quantity; self.unitPrice = unitPrice; self.translationEn = translationEn
        self.category = category; self.subcategory = subcategory; self.itemGroup = itemGroup; self.needsReview = needsReview
    }
}

/// Production's `ReceiptSummary` (list row) and `ReceiptDetail` (detail screen) in one type.
public struct LabReceipt: Identifiable, Hashable, Sendable {
    public let id: Int
    public var store: String?
    /// "yyyy-MM-dd", shown as is in production.
    public var date: String?
    /// "HH:mm"
    public var time: String?
    /// The printed total.
    public var total: Double?
    public var needsReview: Bool
    public var reviewReasons: [String]
    /// nil = goes under "Needs review", set = under "Reviewed".
    public var reviewedAt: String?
    public var items: [LabLineItem]
    public var processing: LabProcessing?
    /// "server", "archived" or nil. "Re-run extraction…" exists only for "server".
    public var photoLocation: String?
    /// Shown instead of the photo when there is none to display.
    public var photoNote: String?

    /// "Items total" in the detail footer.
    public var computedSum: Double? {
        items.isEmpty ? nil : (items.reduce(0) { $0 + $1.totalPrice } * 100).rounded() / 100
    }

    /// Items grouped as production shows them: repeats of a product together, first appearance order.
    public var groupedItems: [[LabLineItem]] {
        var order: [Int] = []
        var groups: [Int: [LabLineItem]] = [:]
        for item in items {
            if groups[item.itemDictionaryId] == nil { order.append(item.itemDictionaryId) }
            groups[item.itemDictionaryId, default: []].append(item)
        }
        return order.map { groups[$0]! }
    }

    public init(id: Int, store: String?, date: String?, time: String?, total: Double?, needsReview: Bool = false,
                reviewReasons: [String] = [], reviewedAt: String? = nil, items: [LabLineItem] = [],
                processing: LabProcessing? = nil, photoLocation: String? = "server", photoNote: String? = nil) {
        self.id = id; self.store = store; self.date = date; self.time = time; self.total = total
        self.needsReview = needsReview; self.reviewReasons = reviewReasons; self.reviewedAt = reviewedAt
        self.items = items; self.processing = processing; self.photoLocation = photoLocation; self.photoNote = photoNote
    }
}

/// Mirrors production `UploadJob` as the upload panel shows it.
public struct LabUploadJob: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case queued, scanning, uploading, uploaded(Int), duplicate(Int), failed(String), cancelled

        public var text: String {
            switch self {
            case .queued: return "Waiting"
            case .scanning: return "Scanning…"
            case .uploading: return "Uploading…"
            case .uploaded(let id): return "Uploaded (receipt #\(id)); the server is reading it"
            case .duplicate(let id): return "Already imported (receipt #\(id))"
            case .failed(let message): return message
            case .cancelled: return "Cancelled"
            }
        }

        public var isFinished: Bool {
            switch self {
            case .queued, .scanning, .uploading: return false
            default: return true
            }
        }

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    public let id: Int
    public var fileName: String
    public var state: State

    public init(id: Int, fileName: String, state: State) { self.id = id; self.fileName = fileName; self.state = state }
}

// MARK: Stats (mirrors production Models/Stats.swift)

public struct LabItemGroupStat: Identifiable, Hashable, Sendable {
    public var id: String { itemGroup }
    public var itemGroup: String
    public var total: Double
}

public struct LabSubcategoryStat: Identifiable, Hashable, Sendable {
    public var id: String { subcategory }
    public var subcategory: String
    public var total: Double
    public var itemGroups: [LabItemGroupStat]
}

public struct LabCategoryStat: Identifiable, Hashable, Sendable {
    public var id: String { category }
    public var category: String
    public var total: Double
    public var subcategories: [LabSubcategoryStat]
}

public struct LabStatsSummary: Hashable, Sendable {
    public var total: Double
    public var categories: [LabCategoryStat]
}

public struct LabPurchaseRow: Identifiable, Hashable, Sendable {
    public var id: Int { receiptId * 1_000_000 + lineItemId }
    public var lineItemId: Int
    public var date: String?
    public var store: String?
    public var translationEn: String?
    public var nameDe: String?
    public var quantity: Double
    public var unitPrice: Double
    public var totalPrice: Double
    public var receiptId: Int
}

/// One bar segment of "SPENDING BY MONTH".
public struct LabMonthCategoryTotal: Identifiable, Hashable, Sendable {
    public var id: String { month + "|" + category }
    /// "yyyy-MM"
    public var month: String
    public var category: String
    public var total: Double
    /// First day of the month, for chart axes.
    public var date: Date { LabFormat.date(month + "-01") ?? .distantPast }
}

public struct LabStoreTotal: Identifiable, Hashable, Sendable {
    public var id: String { store }
    public var store: String
    public var total: Double
}

/// One point of "PRICE HISTORY".
public struct LabPricePoint: Identifiable, Hashable, Sendable {
    public var id: String { item + dateString }
    public var dateString: String
    public var item: String
    public var unitPrice: Double
    public var date: Date { LabFormat.date(dateString) ?? .distantPast }
}

/// The range modes of the Overview tab, labels as in production.
public enum LabRange: String, CaseIterable, Identifiable, Sendable {
    case month = "Month", year = "Year", custom = "Custom", all = "All time"
    public var id: String { rawValue }
}

// MARK: Formatting (same output as production)

public enum LabFormat {
    /// "€12.34", or "—" for nil. Production format: euro sign first, dot as decimal separator.
    public static func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "€%.2f", value)
    }

    /// 2 -> "2", 0.482 -> "0.482".
    public static func quantity(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var s = String(format: "%.3f", value)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    public static func date(_ string: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
}
