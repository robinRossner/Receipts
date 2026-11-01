import Foundation

/// Store paths both apps' review screens use: review reasons for the list rows, confirming without moving the selection,
/// and the truthful way back for the `Undo` snackbar. Every write goes through the same tables,
/// so the sync triggers stamp and push it like any other edit, and last write wins carries an undo to the server even
/// when the original change was already pushed.
extension ReceiptStore {
    /// A line item as it was just before it was deleted, enough to put it back.
    struct DeletedLineItem: Equatable {
        let receiptId: Int
        let itemDictionaryId: Int
        let rawText: String?
        let nameDe: String?
        let quantity: Double?
        let unitPrice: Double?
        let totalPrice: Double?
        let priceNormalized: Int?
        let position: Int?
        let uuid: String?
    }

    func clearReceiptFilters() {
        searchText = ""
        dateRange = .all
        storeFilter = nil
    }

    /// Review reasons of the flagged, unreviewed receipts by id, for the inline line on a list row.
    func reviewReasonsByReceipt() async -> [Int: [String]] {
        do {
            let rows = try await db.query("""
                SELECT id, review_reasons FROM receipts
                WHERE deleted_at IS NULL AND reviewed_at IS NULL AND needs_review = 1
                """)
            var out: [Int: [String]] = [:]
            for row in rows {
                guard let id = row.int(0) else { continue }
                out[id] = decodeStringArray(row.string(1))
            }
            return out
        } catch {
            report("Loading review reasons", error)
            return [:]
        }
    }

    /// Marks one receipt reviewed and reloads the list. Unlike `confirmReceipt` this does not load another receipt, so
    /// the swipe on a list row and the detail screen decide for themselves what comes next.
    func markReviewed(id: Int) async {
        do {
            try await db.run("UPDATE receipts SET reviewed_at = ? WHERE id = ?", [.text(isoNow()), .from(id)])
        } catch { report("Confirming receipt", error) }
        await refreshList()
    }

    /// What "Confirm all without flags" affects: unflagged receipts that are finished. A receipt still being
    /// read is left out: once confirmed, the server treats it as the user's version and keeps the extraction out.
    var confirmableWithoutFlagsCount: Int {
        receipts.filter { $0.reviewedAt == nil && !$0.needsReview && $0.processing == nil }.count
    }

    func confirmAllFinishedWithoutFlags() async {
        do {
            try await db.run(
                """
                UPDATE receipts SET reviewed_at = ?
                WHERE reviewed_at IS NULL AND deleted_at IS NULL AND needs_review = 0
                  AND (review_reasons IS NULL OR review_reasons IN ('', '[]'))
                  AND (extraction_status IS NULL OR extraction_status NOT IN ('pending_upload', 'upload_failed', 'queued', 'processing', 'failed'))
                """,
                [.text(isoNow())]
            )
        } catch { report("Confirming receipts", error) }
        await refreshList()
        if let id = selectedReceiptID { await loadReceiptDetail(id: id) }
    }

    /// Undo of `markReviewed`: back to unreviewed.
    func markUnreviewed(id: Int) async {
        do {
            try await db.run("UPDATE receipts SET reviewed_at = NULL WHERE id = ?", [.from(id)])
        } catch { report("Undoing the confirmation", error) }
        await refreshList()
        if selectedReceiptID == id { await loadReceiptDetail(id: id) }
    }

    /// Deletes a line item like `deleteLineItem` and returns what is needed to undo it.
    func deleteLineItemForUndo(lineItemId: Int, receiptId: Int) async -> DeletedLineItem? {
        var snapshot: DeletedLineItem?
        do {
            if let row = try await db.queryOne("""
                SELECT item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized, position, uuid
                FROM line_items WHERE id = ?
                """, [.from(lineItemId)]), let dictionaryId = row.int(0) {
                snapshot = DeletedLineItem(
                    receiptId: receiptId, itemDictionaryId: dictionaryId, rawText: row.string(1), nameDe: row.string(2),
                    quantity: row.double(3), unitPrice: row.double(4), totalPrice: row.double(5),
                    priceNormalized: row.int(6), position: row.int(7), uuid: row.string(8)
                )
            }
        } catch { report("Deleting item", error) }
        await deleteLineItem(lineItemId: lineItemId, receiptId: receiptId)
        return snapshot
    }

    /// Undo of a line item delete: the same record back at the same place. An unsent tombstone is withdrawn; one that
    /// already reached the server is outdone by this newer copy (last write wins, `deleted_at: null` undeletes).
    func restoreDeletedLineItem(_ item: DeletedLineItem) async {
        do {
            try await db.transaction { conn in
                if let uuid = item.uuid {
                    try conn.run("DELETE FROM sync_tombstones WHERE entity = 'line_item' AND uuid = ?", [.text(uuid)])
                }
                try conn.run("""
                    INSERT INTO line_items
                    (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized,
                     uuid, position, updated_at, sync_state)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'dirty')
                    """, [.from(item.receiptId), .from(item.itemDictionaryId), .from(item.rawText), .from(item.nameDe),
                          .from(item.quantity), .from(item.unitPrice), .from(item.totalPrice), .from(item.priceNormalized),
                          .from(item.uuid), .from(item.position ?? 0)])
            }
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: item.receiptId)
        } catch { report("Restoring item", error) }
        await refreshList()
        if selectedReceiptID == item.receiptId { await loadReceiptDetail(id: item.receiptId) }
    }
}
