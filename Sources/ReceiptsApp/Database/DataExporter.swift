import Foundation

/// CSV / JSON export of receipts and line items (soft-deleted receipts excluded).
enum DataExporter {
    enum Format: String, CaseIterable, Identifiable {
        case standard = "Standard (comma, . decimals)"
        case germanExcel = "German Excel (semicolon, , decimals)"
        var id: String { rawValue }
        var delimiter: String { self == .standard ? "," : ";" }
        func number(_ v: Double?) -> String {
            guard let v else { return "" }
            let s = trimmedMoney(v)
            return self == .standard ? s : s.replacingOccurrences(of: ".", with: ",")
        }
        private func trimmedMoney(_ v: Double) -> String {
            // Up to 3 decimals (quantities such as 0.532 kg), no trailing zeros beyond 2.
            var s = String(format: "%.3f", v)
            if s.hasSuffix("0") { s.removeLast() }
            return s
        }
    }

    private static func quote(_ field: String, _ format: Format) -> String {
        var f = field
        // Spreadsheet formula injection guard for text starting with = + @ (item names come from OCR).
        if let c = f.first, "=+@".contains(c) { f = "'" + f }
        if f.contains(format.delimiter) || f.contains("\"") || f.contains("\n") || f.contains("\r") {
            return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return f
    }

    private static func csv(header: [String], rows: [[String]], format: Format) -> Data {
        var out = "\u{FEFF}"   // UTF-8 BOM so Excel detects the encoding (umlauts)
        out += header.map { quote($0, format) }.joined(separator: format.delimiter) + "\r\n"
        for r in rows { out += r.map { quote($0, format) }.joined(separator: format.delimiter) + "\r\n" }
        return Data(out.utf8)
    }

    private static func filter(_ start: String?, _ end: String?) -> (String, [SQLiteValue]) {
        var sql = "", p: [SQLiteValue] = []
        if let start { sql += " AND r.date >= ?"; p.append(.text(start)) }
        if let end { sql += " AND r.date <= ?"; p.append(.text(end)) }
        return (sql, p)
    }

    static func lineItemsCSV(db: Database, start: String?, end: String?, format: Format) async throws -> Data {
        let (f, params) = filter(start, end)
        let rows = try await db.query("""
            SELECT r.date, r.time, r.store, r.id, li.name_de, d.translation_en, d.category, d.subcategory, d.item_group,
                   li.quantity, li.unit_price, li.total_price
            FROM line_items li
            JOIN receipts r ON li.receipt_id = r.id
            JOIN item_dictionary d ON li.item_dictionary_id = d.id
            WHERE r.deleted_at IS NULL\(f) ORDER BY r.date, r.id, li.id
            """, params)
        let body = rows.map { r in
            [r.string(0) ?? "", r.string(1) ?? "", r.string(2) ?? "", String(r.int(3) ?? 0), r.string(4) ?? "", r.string(5) ?? "",
             r.string(6) ?? "", r.string(7) ?? "", r.string(8) ?? "",
             format.number(r.double(9)), format.number(r.double(10)), format.number(r.double(11))]
        }
        return csv(header: ["date", "time", "store", "receipt_id", "item_name_de", "item_name_en", "category", "subcategory",
                            "item_group", "quantity", "unit_price", "total_price"], rows: body, format: format)
    }

    static func receiptsCSV(db: Database, start: String?, end: String?, format: Format) async throws -> Data {
        let (f, params) = filter(start, end)
        let rows = try await db.query("""
            SELECT r.id, r.date, r.time, r.store, r.total, r.computed_sum, r.needs_review, r.reviewed_at
            FROM receipts r WHERE r.deleted_at IS NULL\(f) ORDER BY r.date, r.id
            """, params)
        let body = rows.map { r in
            [String(r.int(0) ?? 0), r.string(1) ?? "", r.string(2) ?? "", r.string(3) ?? "", format.number(r.double(4)),
             format.number(r.double(5)), r.bool(6) ? "1" : "0", r.string(7) ?? ""]
        }
        return csv(header: ["id", "date", "time", "store", "total", "computed_sum", "needs_review", "reviewed_at"], rows: body, format: format)
    }

    /// Everything that isn't soft-deleted: receipts with nested line items, plus the dictionary.
    static func everythingJSON(db: Database) async throws -> Data {
        func v(_ s: String?) -> Any { s ?? NSNull() }
        func v(_ d: Double?) -> Any { d ?? NSNull() }
        let receiptRows = try await db.query("""
            SELECT id, store, date, time, total, computed_sum, needs_review, review_reasons, reviewed_at, created_at
            FROM receipts WHERE deleted_at IS NULL ORDER BY date, id
            """)
        let itemRows = try await db.query("""
            SELECT li.receipt_id, li.id, li.item_dictionary_id, li.raw_text, li.name_de, li.quantity, li.unit_price, li.total_price
            FROM line_items li JOIN receipts r ON r.id = li.receipt_id WHERE r.deleted_at IS NULL ORDER BY li.id
            """)
        var itemsByReceipt: [Int: [[String: Any]]] = [:]
        for r in itemRows {
            itemsByReceipt[r.int(0) ?? 0, default: []].append([
                "id": r.int(1) ?? 0, "item_dictionary_id": r.int(2) ?? 0, "raw_text": v(r.string(3)), "name_de": v(r.string(4)),
                "quantity": v(r.double(5)), "unit_price": v(r.double(6)), "total_price": v(r.double(7)),
            ])
        }
        let receipts: [[String: Any]] = receiptRows.map { r in
            let id = r.int(0) ?? 0
            return ["id": id, "store": v(r.string(1)), "date": v(r.string(2)), "time": v(r.string(3)), "total": v(r.double(4)),
                    "computed_sum": v(r.double(5)), "needs_review": r.bool(6), "review_reasons": decodeStringArray(r.string(7)),
                    "reviewed_at": v(r.string(8)), "created_at": v(r.string(9)), "items": itemsByReceipt[id] ?? []]
        }
        let dictRows = try await db.query("""
            SELECT id, canonical_name, display_name_de, translation_en, category, subcategory, item_group, aliases, is_manual_override, times_seen
            FROM item_dictionary ORDER BY id
            """)
        let dictionary: [[String: Any]] = dictRows.map { r in
            ["id": r.int(0) ?? 0, "canonical_name": v(r.string(1)), "display_name_de": v(r.string(2)), "translation_en": v(r.string(3)),
             "category": v(r.string(4)), "subcategory": v(r.string(5)), "item_group": v(r.string(6)),
             "aliases": decodeStringArray(r.string(7)), "is_manual_override": r.bool(8), "times_seen": r.int(9) ?? 0]
        }
        let root: [String: Any] = ["exported_at": isoNow(), "receipts": receipts, "item_dictionary": dictionary]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
