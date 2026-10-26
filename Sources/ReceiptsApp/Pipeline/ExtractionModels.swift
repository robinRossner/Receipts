import Foundation

/// Lenient type coercion for values coming out of an LLM's JSON - mirrors safe_float() in
/// scan_and_parse_receipt.py, which exists because vision models occasionally emit "1.99"
/// as a string, or omit a field entirely, instead of a clean number.
enum JSONCoerce {
    static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }
    static func int(_ any: Any?) -> Int? {
        double(any).map { Int($0) }
    }
    static func string(_ any: Any?) -> String? {
        any as? String
    }
}

/// One item line as extracted by the vision LLM - mirrors an entry in the "items" array from
/// scan_and_parse_receipt.py's PROMPT_TEMPLATE, plus the price_normalized flag validation adds.
struct ExtractedItem {
    var rawText: String?
    var name: String?
    var quantity: Double?
    var unitPrice: Double?
    var totalPrice: Double?
    var priceNormalized: Bool = false

    init(dict: [String: Any]) {
        rawText = JSONCoerce.string(dict["raw_text"])
        name = JSONCoerce.string(dict["name"])
        quantity = JSONCoerce.double(dict["quantity"])
        unitPrice = JSONCoerce.double(dict["unit_price"])
        totalPrice = JSONCoerce.double(dict["total_price"])
    }
}

/// A full receipt as extracted (and then validated) - mirrors the dict scan_and_parse_receipt.py
/// builds and mutates through parse_json_response() -> validate_receipt().
struct ExtractedReceipt {
    var store: String?
    var date: String?
    var time: String?
    var items: [ExtractedItem]
    var total: Double?
    var printedItemCount: Int?
    var computedSum: Double = 0
    var needsReview: Bool = false
    var reviewReasons: [String] = []
    /// Which provider/model answered the extraction call (LLMResponse.providerId).
    var providerId: String?

    init(dict: [String: Any]) {
        store = JSONCoerce.string(dict["store"])
        date = JSONCoerce.string(dict["date"])
        time = JSONCoerce.string(dict["time"])
        let rawItems = dict["items"] as? [[String: Any]] ?? []
        items = rawItems.map(ExtractedItem.init(dict:))
        total = JSONCoerce.double(dict["total"])
        printedItemCount = JSONCoerce.int(dict["printed_item_count"])
    }

    /// For the debug_output/ dump - mirrors the DEBUG_DUMP JSON written by process_receipt().
    /// `extra` adds pipeline metadata (e.g. which provider classified each item).
    func toJSONData(extra: [String: Any] = [:]) -> Data? {
        let itemDicts: [[String: Any]] = items.map { item in
            var d: [String: Any] = [:]
            d["raw_text"] = item.rawText ?? NSNull()
            d["name"] = item.name ?? NSNull()
            d["quantity"] = item.quantity ?? NSNull()
            d["unit_price"] = item.unitPrice ?? NSNull()
            d["total_price"] = item.totalPrice ?? NSNull()
            d["price_normalized"] = item.priceNormalized
            return d
        }
        var dict: [String: Any] = [
            "extraction_provider": providerId ?? NSNull(),
            "store": store ?? NSNull(),
            "date": date ?? NSNull(),
            "time": time ?? NSNull(),
            "items": itemDicts,
            "total": total ?? NSNull(),
            "printed_item_count": printedItemCount ?? NSNull(),
            "computed_sum": computedSum,
            "needs_review": needsReview,
            "review_reasons": reviewReasons,
        ]
        dict.merge(extra) { _, new in new }
        guard JSONSerialization.isValidJSONObject(dict) else { return nil }
        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
    }
}
