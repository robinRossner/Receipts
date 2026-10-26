import Foundation

/// Mirrors GET /stats/summary's response tree in api.py.
struct StatsSummary {
    var total: Double
    var categories: [CategoryStat]
}

struct CategoryStat: Identifiable {
    var id: String { category }
    var category: String
    var total: Double
    var subcategories: [SubcategoryStat]
}

struct SubcategoryStat: Identifiable {
    var id: String { subcategory }
    var subcategory: String
    var total: Double
    var itemGroups: [ItemGroupStat]
}

struct ItemGroupStat: Identifiable {
    var id: String { itemGroup }
    var itemGroup: String
    var total: Double
}

/// Mirrors GET /stats/item-group's response in api.py.
struct PurchaseRow: Identifiable {
    var id: Int { lineItemReceiptKey }
    var date: String?
    var store: String?
    var translationEn: String?
    var nameDe: String?
    var quantity: Double
    var unitPrice: Double
    var totalPrice: Double
    var receiptId: Int
    var itemDictionaryId: Int

    /// Purchase rows have no own id column (they're a join projection), synthesize one.
    private var lineItemReceiptKey: Int { receiptId * 1_000_000 + itemDictionaryId }
}

struct ItemGroupDetail {
    var category: String
    var subcategory: String
    var itemGroup: String
    var total: Double
    var purchases: [PurchaseRow]
}

/// One bar segment of the spending-over-time chart.
struct MonthCategoryTotal: Identifiable {
    var id: String { month + "|" + category }
    var month: String      // "yyyy-MM"
    var category: String
    var total: Double
}

struct StoreTotal: Identifiable {
    var id: String { store }
    var store: String
    var total: Double
}

/// One purchase of an item, for the price-history chart.
struct PricePoint: Identifiable {
    let id = UUID()
    var date: Date
    var item: String
    var unitPrice: Double
}
