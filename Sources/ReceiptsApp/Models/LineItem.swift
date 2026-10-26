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
}
