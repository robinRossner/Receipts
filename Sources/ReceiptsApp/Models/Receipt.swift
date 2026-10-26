import Foundation

/// Row shape for the sidebar list (GET /receipts in the old API).
struct ReceiptSummary: Identifiable, Hashable {
    let id: Int
    var store: String?
    var date: String?
    var time: String?
    var total: Double?
    var needsReview: Bool
    var reviewedAt: String?
}

/// Full receipt + its line items (GET /receipts/{id} in the old API).
struct ReceiptDetail: Identifiable {
    let id: Int
    var store: String?
    var date: String?
    var time: String?
    var total: Double?
    var computedSum: Double?
    var needsReview: Bool
    var reviewReasons: [String]
    var sourceImage: String?
    var reviewedAt: String?
    var items: [LineItemDetail]

    var hasSumMismatch: Bool {
        reviewReasons.contains { $0.contains("sum to") }
    }
}
