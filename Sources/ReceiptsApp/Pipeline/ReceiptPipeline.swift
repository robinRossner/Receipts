import Foundation

enum PipelineFileError: Error, LocalizedError {
    case moveFailed(String)
    var errorDescription: String? {
        switch self {
        case .moveFailed(let msg): return msg
        }
    }
}

/// Result of running one photo through the full pipeline - mirrors the dict process_receipt()
/// returns in receipt_pipeline.py.
struct ProcessResult: Sendable {
    var success: Bool
    var receiptId: Int?
    var errorMessage: String?
}

/// Ports receipt_pipeline.py: orchestrates scan -> extract -> categorize -> store -> organize
/// for one receipt photo.
enum ReceiptPipeline {
    static let debugDump = true

    // ---- Store name canonicalization, copied verbatim from receipt_pipeline.py ----

    private static let storeNameMap: [String: String] = [
        "edeka": "Edeka",
        "aldi sud": "Aldi Süd",
        "aldi süd": "Aldi Süd",
        "aldi nord": "Aldi Nord",
        "dm-drogerie markt": "dm",
        "dm": "dm",
        "rewe": "Rewe",
        "lidl": "Lidl",
        "penny-markt gmbh": "Penny",
        "penny": "Penny",
        "rossmann": "Rossmann",
        "kaufland": "Kaufland",
    ]

    static func canonicalizeStore(_ raw: String?) -> String {
        guard let raw else { return "Unknown" }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Unknown" }
        return storeNameMap[trimmed.lowercased()] ?? trimmed
    }

    static func slugify(_ text: String?) -> String {
        var s = (text ?? "unknown-store").lowercased()
        if let regex = try? NSRegularExpression(pattern: "[^a-z0-9]+") {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "-")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "unknown-store" : s
    }

    /// Moves the uploaded photo into archiveDir/YYYY/MM/date_store_id.ext - mirrors
    /// organize_image(). Throws (rather than swallowing the error) so the caller can log a
    /// warning and leave source_image pointing at the original path, same as the Python version.
    static func organizeImage(imagePath: String, store: String?, date: String?, receiptId: Int, archiveDir: URL) throws -> String {
        let src = URL(fileURLWithPath: imagePath)

        var year = "unsorted", month = "unsorted"
        if let date {
            let parts = date.split(separator: "-")
            if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty,
               parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) {
                year = String(parts[0])
                month = String(parts[1])
            }
        }

        let destDir = archiveDir.appendingPathComponent(year, isDirectory: true).appendingPathComponent(month, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let ext = src.pathExtension.isEmpty ? "jpg" : src.pathExtension
        let datePart = year != "unsorted" ? (date ?? "unknown-date") : "unknown-date"
        let destPath = destDir.appendingPathComponent("\(datePart)_\(slugify(store))_\(receiptId).\(ext)")

        if FileManager.default.fileExists(atPath: destPath.path) {
            try FileManager.default.removeItem(at: destPath)
        }
        try FileManager.default.moveItem(at: src, to: destPath)
        return destPath.path
    }

    /// Re-derives computed_sum and the sum-mismatch review reason after a manual item
    /// add/edit/delete - mirrors recompute_receipt_totals().
    static func recomputeReceiptTotals(db: Database, receiptId: Int) async throws {
        let sumRow = try await db.queryOne(
            "SELECT COALESCE(SUM(total_price), 0) FROM line_items WHERE receipt_id = ?", [.from(receiptId)]
        )
        let computedSum = sumRow?.double(0) ?? 0

        guard let receiptRow = try await db.queryOne(
            "SELECT total, review_reasons FROM receipts WHERE id = ?", [.from(receiptId)]
        ) else { return }

        let total = receiptRow.double(0)
        var reasons = decodeStringArray(receiptRow.string(1)).filter { !$0.contains("sum to") }
        if let total {
            let diff = round2(abs(computedSum - total))
            if diff > 0.02 {
                reasons.append("Item prices sum to \(round2(computedSum)), but printed total is \(total) (difference: \(diff)). Check raw_text per item.")
            }
        }

        try await db.run(
            "UPDATE receipts SET computed_sum = ?, review_reasons = ?, needs_review = ? WHERE id = ?",
            [.from(round2(computedSum)), .text(encodeStringArray(reasons)), .from(!reasons.isEmpty), .from(receiptId)]
        )
    }

    /// Runs one receipt through the full pipeline and stores it - mirrors process_receipt().
    static func processReceipt(imagePath: String, db: Database, env: AppEnvironment, taxonomy: Taxonomy) async -> ProcessResult {
        do {
            let warped = try DocumentScanner.scan(imagePath: imagePath)
            var extracted = try await ReceiptExtractor.extractAndValidate(image: warped)
            extracted.store = canonicalizeStore(extracted.store)

            if debugDump {
                let stem = URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent
                let debugPath = env.debugDir.appendingPathComponent("\(stem).json")
                if let data = extracted.toJSONData() {
                    try? data.write(to: debugPath)
                }
            }

            let now = isoNow()
            let receiptId = try await db.run(
                """
                INSERT INTO receipts
                (store, date, time, total, computed_sum, needs_review, review_reasons, source_image, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.from(extracted.store), .from(extracted.date), .from(extracted.time),
                 .from(extracted.total), .from(extracted.computedSum), .from(extracted.needsReview),
                 .text(encodeStringArray(extracted.reviewReasons)), .text(imagePath), .text(now)]
            )
            let receiptIdInt = Int(receiptId)

            do {
                let organizedPath = try organizeImage(
                    imagePath: imagePath, store: extracted.store, date: extracted.date,
                    receiptId: receiptIdInt, archiveDir: env.archiveDir
                )
                try await db.run("UPDATE receipts SET source_image = ? WHERE id = ?", [.text(organizedPath), .from(receiptIdInt)])
            } catch {
                // Don't let a file-move problem lose an otherwise-good extraction.
                print("Warning: could not organize image file (\(error)); left at original path.")
            }

            for item in extracted.items {
                let itemName = item.name ?? item.rawText ?? ""
                let dictEntry = try await ItemCategorizer.getOrCreateItem(
                    db: db, rawName: itemName, taxonomy: taxonomy, storeName: extracted.store, logURL: env.classificationLogURL
                )
                try await db.run(
                    """
                    INSERT INTO line_items
                    (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.from(receiptIdInt), .from(dictEntry.id), .from(item.rawText), .text(itemName),
                     .from(item.quantity ?? 1.0), .from(item.unitPrice ?? 0.0), .from(item.totalPrice ?? 0.0),
                     .from(item.priceNormalized)]
                )
            }

            return ProcessResult(success: true, receiptId: receiptIdInt, errorMessage: nil)
        } catch {
            return ProcessResult(success: false, receiptId: nil, errorMessage: error.localizedDescription)
        }
    }
}
