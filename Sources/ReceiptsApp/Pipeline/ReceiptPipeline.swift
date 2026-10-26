import Foundation
import CryptoKit

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
    /// Set when the file's bytes match an already-imported (non-deleted) receipt; nothing was written.
    var duplicateOf: Int?
    /// The task was cancelled before anything was committed; staging file removed, nothing written.
    var cancelled = false
}

/// Stage the pipeline is in, reported through processReceipt's progress callback.
enum ProcessStage: Sendable {
    case scanning, extracting, categorizing, saving
}

/// Ports receipt_pipeline.py: orchestrates scan -> extract -> categorize -> store -> organize
/// for one receipt photo.
enum ReceiptPipeline {
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

    /// SHA-256 of the original file bytes, hex-encoded.
    static func sha256Hex(ofFileAt path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs one receipt through the full pipeline and stores it - mirrors process_receipt().
    /// Order: hash/duplicate-check -> scan -> extract -> categorize every item -> ONE
    /// transaction for the receipt row + all line items -> move the image into the archive.
    /// `imagePath` is the uploads_incoming staging copy; it is deleted on every outcome except
    /// "imported but archive move failed" (then the receipt row still points at it).
    static func processReceipt(imagePath: String, db: Database, env: AppEnvironment, taxonomy: Taxonomy, services: PipelineServices,
                               progress: (@Sendable (ProcessStage) -> Void)? = nil) async -> ProcessResult {
        var keepStagingFile = false
        defer {
            if !keepStagingFile { try? FileManager.default.removeItem(atPath: imagePath) }
        }
        do {
            let imageHash = try sha256Hex(ofFileAt: imagePath)
            if let dup = try await db.queryOne(
                "SELECT id FROM receipts WHERE image_hash = ? AND deleted_at IS NULL ORDER BY id LIMIT 1", [.text(imageHash)]
            ), let dupId = dup.int(0) {
                return ProcessResult(success: false, receiptId: nil, errorMessage: "Already imported (receipt #\(dupId))", duplicateOf: dupId)
            }

            progress?(.scanning)
            let warped = try DocumentScanner.scan(imagePath: imagePath)
            try Task.checkCancellation()
            progress?(.extracting)
            var extracted = try await ReceiptExtractor.extractAndValidate(image: warped, provider: services.extraction)
            extracted.store = canonicalizeStore(extracted.store)

            let debugPath = env.debugDir.appendingPathComponent(
                "\(URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent).json"
            )
            if services.debugDump, let data = extracted.toJSONData() {
                try? data.write(to: debugPath)
            }

            // Categorize everything before writing anything: one dictionary load and one batched
            // LLM call for the whole receipt. item_dictionary upserts happen here, outside the
            // receipt transaction - it's a shared cache, so entries created for a receipt that
            // later fails are harmless.
            try Task.checkCancellation()
            progress?(.categorizing)
            let itemNames = extracted.items.map { $0.name ?? $0.rawText ?? "" }
            let (dictEntries, classificationProviders) = try await ItemCategorizer.resolveItems(
                db: db, rawNames: itemNames, taxonomy: taxonomy, storeName: extracted.store,
                logURL: env.classificationLogURL, provider: services.classification
            )
            let categorized: [(item: ExtractedItem, name: String, dictId: Int)] = zip(extracted.items, zip(itemNames, dictEntries))
                .map { ($0, $1.0, $1.1.id) }

            if services.debugDump, let data = extracted.toJSONData(extra: ["classification_providers": classificationProviders]) {
                try? data.write(to: debugPath)
            }

            // Same store + date + total (and time, when both have one) as a live receipt:
            // still import it, but flag it.
            if let date = extracted.date, let total = extracted.total,
               let dup = try await db.queryOne(
                """
                SELECT id FROM receipts
                WHERE deleted_at IS NULL AND store = ? AND date = ? AND ABS(total - ?) < 0.005
                  AND (time IS NULL OR ? IS NULL OR time = ?)
                ORDER BY id LIMIT 1
                """,
                [.from(extracted.store), .text(date), .from(total), .from(extracted.time), .from(extracted.time)]
               ), let dupId = dup.int(0) {
                extracted.reviewReasons.append("Possible duplicate of receipt #\(dupId)")
                extracted.needsReview = true
            }

            // Last cancellation point: once the transaction starts, the receipt is written in full.
            try Task.checkCancellation()
            progress?(.saving)
            let now = isoNow()
            let receiptIdInt = try await db.transaction { conn -> Int in
                let receiptId = try conn.run(
                    """
                    INSERT INTO receipts
                    (store, date, time, total, computed_sum, needs_review, review_reasons, source_image, created_at, image_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.from(extracted.store), .from(extracted.date), .from(extracted.time),
                     .from(extracted.total), .from(extracted.computedSum), .from(extracted.needsReview),
                     .text(encodeStringArray(extracted.reviewReasons)), .text(imagePath), .text(now), .text(imageHash)]
                )
                for entry in categorized {
                    try conn.run(
                        """
                        INSERT INTO line_items
                        (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.integer(receiptId), .from(entry.dictId), .from(entry.item.rawText), .text(entry.name),
                         .from(entry.item.quantity ?? 1.0), .from(entry.item.unitPrice ?? 0.0), .from(entry.item.totalPrice ?? 0.0),
                         .from(entry.item.priceNormalized)]
                    )
                }
                return Int(receiptId)
            }

            // Committed. Now archive the image; the row currently points at the staging path.
            do {
                let organizedPath = try organizeImage(
                    imagePath: imagePath, store: extracted.store, date: extracted.date,
                    receiptId: receiptIdInt, archiveDir: env.archiveDir
                )
                do {
                    try await db.run(
                        "UPDATE receipts SET source_image = ? WHERE id = ?",
                        [.text(env.storedImagePath(for: organizedPath)), .from(receiptIdInt)]
                    )
                } catch {
                    // File moved but the row still says staging: put the file back so they agree.
                    print("Warning: could not record archived image path (\(error)); restoring staging file.")
                    if (try? FileManager.default.moveItem(atPath: organizedPath, toPath: imagePath)) == nil {
                        print("Warning: could not restore \(organizedPath) to \(imagePath).")
                    }
                    keepStagingFile = true
                }
            } catch {
                // Don't let a file-move problem lose an otherwise-good extraction: the row keeps
                // pointing at the staging file, which we therefore must not delete.
                print("Warning: could not organize image file (\(error)); left at \(imagePath).")
                keepStagingFile = true
            }

            return ProcessResult(success: true, receiptId: receiptIdInt, errorMessage: nil)
        } catch {
            if error is CancellationError || Task.isCancelled {
                return ProcessResult(success: false, receiptId: nil, errorMessage: "Cancelled", cancelled: true)
            }
            return ProcessResult(success: false, receiptId: nil, errorMessage: error.localizedDescription)
        }
    }
}
