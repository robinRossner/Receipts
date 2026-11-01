import Foundation

/// A single receipt line, joined with its item_dictionary categorization.
/// Mirrors get_receipt_detail's item_rows join in api.py.
struct LineItemDetail: Identifiable, Hashable {
    let id: Int
    let itemDictionaryId: Int
    var rawText: String?
    var nameDe: String?
    var quantity: Double
    var unitPrice: Double
    var totalPrice: Double
    var translationEn: String?
    var category: String
    var subcategory: String
    var itemGroup: String
    var needsReview: Bool
    /// The categoriser found no good category and filed the item under Other > Miscellaneous > General until the user
    /// resolves it (see ReceiptStore+Flagged). Defaults keep existing initialisers working.
    var categoryFlagged: Bool = false
    var suggestedCategory: String? = nil
    var suggestedParent: String? = nil
}

/// A dictionary entry describing one canonical product (item_dictionary table).
struct ItemDictionaryEntry {
    let id: Int
    var canonicalName: String
    var displayNameDe: String?
    var translationEn: String?
    var category: String
    var subcategory: String
    var itemGroup: String
    var aliases: [String]
    var isManualOverride: Bool
    var needsReview: Bool
    var timesSeen: Int
    var createdAt: String
    var lastSeenAt: String
    /// "No good category": see `LineItemDetail.categoryFlagged`. `suggestedParent` is "Category" or "Category > Subcategory".
    var categoryFlagged: Bool = false
    var suggestedCategory: String? = nil
    var suggestedParent: String? = nil
}
