import Foundation

/// Ports every endpoint from api.py into plain async methods that SwiftUI views call directly -
/// no HTTP, no JSON serialization boundary, no CORS, since there's no separate server process
/// anymore. `@Published` state drives the UI the same way the dashboard's re-fetch-and-render
/// calls did.
@MainActor
final class ReceiptStore: ObservableObject {
    let env: AppEnvironment
    let db: Database
    let taxonomy: Taxonomy
    /// LLM providers + pipeline switches, rebuilt from LLMSettings whenever Settings change.
    private(set) var services: PipelineServices

    struct HighlightRequest: Equatable {
        let receiptId: Int
        let itemDictionaryId: Int
        let token: UUID
    }

    /// Outcome of one file in a batch upload.
    struct UploadResult: Identifiable {
        enum Outcome {
            case success(receiptId: Int)
            case duplicate(receiptId: Int)
            case failure(String)
        }
        let id = UUID()
        let fileName: String
        let outcome: Outcome
    }

    @Published var receipts: [ReceiptSummary] = []
    @Published var selectedReceipt: ReceiptDetail?
    @Published var isProcessingUpload = false
    @Published var uploadProgressLabel: String?
    @Published var uploadResults: [UploadResult] = []
    @Published var deletedReceipts: [ReceiptSummary] = []
    /// Last failed database/file operation, shown as a dismissible banner in ContentView.
    @Published var lastError: String?
    /// From the selected AI backend's readiness() check; shown in the top bar.
    @Published var providerWarning: String?
    @Published var highlightRequest: HighlightRequest?

    /// Mirrors goToReceiptItem() in dashboard.html: jump to the Review tab, load the receipt,
    /// and let the view scroll to + briefly highlight the matching item group.
    func jumpToItem(receiptId: Int, itemDictionaryId: Int) async {
        await loadReceiptDetail(id: receiptId)
        highlightRequest = HighlightRequest(receiptId: receiptId, itemDictionaryId: itemDictionaryId, token: UUID())
    }

    init(env: AppEnvironment, db: Database, taxonomy: Taxonomy, settings: LLMSettings = .load()) {
        self.env = env
        self.db = db
        self.taxonomy = taxonomy
        self.settings = settings
        self.services = ProviderFactory.makeServices(settings: settings, env: env)
    }

    private func report(_ action: String, _ error: Error) {
        lastError = "\(action) failed: \(error)"
    }

    // MARK: - AI backend

    private var settings: LLMSettings
    private var readinessTask: Task<Void, Never>?

    /// Asks the selected backend whether it's usable (Ollama: starts `ollama serve`, checks models).
    func checkProviderReadiness() async {
        let health = services.health
        providerWarning = await health.readiness().warningMessage
    }

    /// Called by SettingsView after any change: rebuilds the providers from the stored settings
    /// and, if anything backend-related changed, re-checks readiness (debounced, since text
    /// fields report every keystroke). Receipts already processing keep their old services.
    func applySettings() {
        let newSettings = LLMSettings.load()
        guard newSettings != settings else { return }
        var backendOnly = newSettings
        backendOnly.debugDump = settings.debugDump
        let backendChanged = backendOnly != settings
        settings = newSettings
        services = ProviderFactory.makeServices(settings: newSettings, env: env)
        guard backendChanged else { return }
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.checkProviderReadiness()
        }
    }

    // MARK: - Listing / detail (GET /receipts, GET /receipts/{id})

    func refreshList() async {
        do {
            receipts = try await fetchSummaries(deleted: false)
            deletedReceipts = try await fetchSummaries(deleted: true)
        } catch {
            report("Loading receipts", error)
        }
    }

    private func fetchSummaries(deleted: Bool) async throws -> [ReceiptSummary] {
        let rows = try await db.query("""
            SELECT id, store, date, time, total, needs_review, reviewed_at
            FROM receipts WHERE deleted_at IS \(deleted ? "NOT NULL" : "NULL")
            ORDER BY \(deleted ? "deleted_at DESC" : "date DESC, id DESC")
            """)
        return rows.map { row in
            ReceiptSummary(
                id: row.int(0) ?? 0, store: row.string(1), date: row.string(2), time: row.string(3),
                total: row.double(4), needsReview: row.bool(5), reviewedAt: row.string(6)
            )
        }
    }

    func loadReceiptDetail(id: Int) async {
        do {
            selectedReceipt = try await fetchReceiptDetail(id: id)
        } catch {
            selectedReceipt = nil
            report("Loading receipt #\(id)", error)
        }
    }

    private func fetchReceiptDetail(id: Int) async throws -> ReceiptDetail? {
        guard let row = try await db.queryOne("""
            SELECT id, store, date, time, total, computed_sum, needs_review, review_reasons, source_image, reviewed_at
            FROM receipts WHERE id = ? AND deleted_at IS NULL
            """, [.from(id)]) else { return nil }

        let itemRows = try await db.query("""
            SELECT li.id, li.item_dictionary_id, li.raw_text, li.name_de,
                   li.quantity, li.unit_price, li.total_price,
                   d.translation_en, d.category, d.subcategory, d.item_group, d.needs_review
            FROM line_items li JOIN item_dictionary d ON li.item_dictionary_id = d.id
            WHERE li.receipt_id = ? ORDER BY li.id
            """, [.from(id)])

        let items = itemRows.map { r in
            LineItemDetail(
                id: r.int(0) ?? 0, itemDictionaryId: r.int(1) ?? 0, rawText: r.string(2), nameDe: r.string(3),
                quantity: r.double(4) ?? 0, unitPrice: r.double(5) ?? 0, totalPrice: r.double(6) ?? 0,
                translationEn: r.string(7), category: r.string(8) ?? "", subcategory: r.string(9) ?? "",
                itemGroup: r.string(10) ?? "", needsReview: r.bool(11)
            )
        }

        return ReceiptDetail(
            id: row.int(0) ?? 0, store: row.string(1), date: row.string(2), time: row.string(3),
            total: row.double(4), computedSum: row.double(5), needsReview: row.bool(6),
            reviewReasons: decodeStringArray(row.string(7)), sourceImage: env.resolveImagePath(row.string(8)), reviewedAt: row.string(9),
            items: items
        )
    }

    // MARK: - Upload (POST /receipts/upload)

    /// Processes one or more receipt photos, in order. Multiple files (from a multi-select or
    /// a multi-file drop) are handled sequentially rather than in parallel, both so the
    /// "Reading receipt N of M" progress label is meaningful and so a burst of uploads doesn't
    /// hammer the AI backend with concurrent requests it has to queue anyway.
    func upload(fileURLs: [URL]) async {
        guard !fileURLs.isEmpty else { return }
        isProcessingUpload = true
        uploadResults = []
        defer {
            isProcessingUpload = false
            uploadProgressLabel = nil
        }

        for (index, url) in fileURLs.enumerated() {
            uploadProgressLabel = fileURLs.count > 1
                ? "Reading receipt \(index + 1) of \(fileURLs.count)…"
                : "Reading receipt…"
            await uploadOne(fileURL: url)
        }
    }

    /// Copies the picked file into a staging folder (mirrors INCOMING_FOLDER in api.py) and
    /// runs the full pipeline on it. The actual pipeline work (Vision document scanning, JPEG
    /// encoding, LLM calls) runs in a detached task rather than inline here - `upload` is a
    /// method on this `@MainActor` store, and that CPU-bound work has no `await` points of its
    /// own to yield at, so running it directly here would freeze the entire UI (every button
    /// and text field, including on receipts you're not even touching) for the whole duration.
    private func uploadOne(fileURL: URL) async {
        let ext = fileURL.pathExtension.isEmpty ? "jpg" : fileURL.pathExtension
        let stagingDir = env.appSupportDir.appendingPathComponent("uploads_incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let tempPath = stagingDir.appendingPathComponent("\(UUID().uuidString).\(ext)")

        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.copyItem(at: fileURL, to: tempPath)
        } catch {
            try? FileManager.default.removeItem(at: tempPath)
            uploadResults.append(UploadResult(
                fileName: fileURL.lastPathComponent, outcome: .failure("Couldn't read the file: \(error.localizedDescription)")
            ))
            return
        }

        let db = db
        let env = env
        let taxonomy = taxonomy
        let services = services
        let imagePath = tempPath.path
        let result = await Task.detached(priority: .userInitiated) {
            await ReceiptPipeline.processReceipt(imagePath: imagePath, db: db, env: env, taxonomy: taxonomy, services: services)
        }.value

        if let dupId = result.duplicateOf {
            uploadResults.append(UploadResult(fileName: fileURL.lastPathComponent, outcome: .duplicate(receiptId: dupId)))
            return
        }
        guard result.success, let receiptId = result.receiptId else {
            uploadResults.append(UploadResult(
                fileName: fileURL.lastPathComponent,
                outcome: .failure("\(result.errorMessage ?? "Unknown error"). Try a clearer, flatter photo.")
            ))
            return
        }
        uploadResults.append(UploadResult(fileName: fileURL.lastPathComponent, outcome: .success(receiptId: receiptId)))
        await refreshList()
        await loadReceiptDetail(id: receiptId)
    }

    // MARK: - Mutations

    func confirmReceipt(id: Int) async {
        do {
            try await db.run("UPDATE receipts SET reviewed_at = ? WHERE id = ?", [.text(isoNow()), .from(id)])
        } catch { report("Confirming receipt", error) }
        await refreshList()
        await loadReceiptDetail(id: id)
    }

    func correctItem(itemDictionaryId: Int, category: String, subcategory: String, itemGroup: String, translationEn: String?, forReceipt receiptId: Int) async {
        do {
            try await db.run(
                """
                UPDATE item_dictionary
                SET category = ?, subcategory = ?, item_group = ?,
                    translation_en = COALESCE(?, translation_en),
                    is_manual_override = 1, needs_review = 0
                WHERE id = ?
                """,
                [.text(category), .text(subcategory), .text(itemGroup), .from(translationEn), .from(itemDictionaryId)]
            )
        } catch { report("Saving category", error) }
        await loadReceiptDetail(id: receiptId)
    }

    func updateLineItem(lineItemId: Int, quantity: Double, unitPrice: Double, receiptId: Int) async {
        let totalPrice = round2(quantity * unitPrice)
        do {
            try await db.run(
                "UPDATE line_items SET quantity = ?, unit_price = ?, total_price = ? WHERE id = ?",
                [.from(quantity), .from(unitPrice), .from(totalPrice), .from(lineItemId)]
            )
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: receiptId)
        } catch { report("Updating item", error) }
        await refreshList()
        await loadReceiptDetail(id: receiptId)
    }

    func deleteLineItem(lineItemId: Int, receiptId: Int) async {
        do {
            try await db.run("DELETE FROM line_items WHERE id = ?", [.from(lineItemId)])
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: receiptId)
        } catch { report("Deleting item", error) }
        await refreshList()
        await loadReceiptDetail(id: receiptId)
    }

    func addItem(receiptId: Int, name: String, quantity: Double, unitPrice: Double, rawText: String?) async {
        do {
            guard let row = try await db.queryOne("SELECT store FROM receipts WHERE id = ?", [.from(receiptId)]) else { return }
            let store = row.string(0)
            let totalPrice = round2(quantity * unitPrice)
            let entry = try await ItemCategorizer.getOrCreateItem(
                db: db, rawName: name, taxonomy: taxonomy, storeName: store, logURL: env.classificationLogURL,
                provider: services.classification
            )
            try await db.run(
                """
                INSERT INTO line_items
                (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """,
                [.from(receiptId), .from(entry.id), .text(rawText ?? name), .text(name), .from(quantity), .from(unitPrice), .from(totalPrice)]
            )
            try await ReceiptPipeline.recomputeReceiptTotals(db: db, receiptId: receiptId)
        } catch { report("Adding item", error) }
        await refreshList()
        await loadReceiptDetail(id: receiptId)
    }

    /// Soft delete: hides the receipt everywhere (lists, stats, duplicate checks) but keeps the
    /// rows and the archived image, so it can be restored from "Recently deleted".
    func deleteReceipt(id: Int) async {
        do {
            try await db.run("UPDATE receipts SET deleted_at = ? WHERE id = ?", [.text(isoNow()), .from(id)])
        } catch { report("Deleting receipt", error) }
        if selectedReceipt?.id == id { selectedReceipt = nil }
        await refreshList()
    }

    func restoreReceipt(id: Int) async {
        do {
            try await db.run("UPDATE receipts SET deleted_at = NULL WHERE id = ?", [.from(id)])
        } catch { report("Restoring receipt", error) }
        await refreshList()
    }

    /// Irreversible: removes the rows and the archived image file.
    func permanentlyDeleteReceipt(id: Int) async {
        do {
            let sourceImage = try await db.queryOne("SELECT source_image FROM receipts WHERE id = ?", [.from(id)])?.string(0)
            try await db.transaction { conn in
                try conn.run("DELETE FROM line_items WHERE receipt_id = ?", [.from(id)])
                try conn.run("DELETE FROM receipts WHERE id = ?", [.from(id)])
            }
            if let path = env.resolveImagePath(sourceImage) {
                try? FileManager.default.removeItem(atPath: path)
            }
        } catch { report("Permanently deleting receipt", error) }
        if selectedReceipt?.id == id { selectedReceipt = nil }
        await refreshList()
    }

    func updateReceiptDateTime(id: Int, date: String?, time: String?) async {
        var fields: [String] = []
        var params: [SQLiteValue] = []
        if let date { fields.append("date = ?"); params.append(.text(date)) }
        if let time { fields.append("time = ?"); params.append(.text(time)) }
        guard !fields.isEmpty else { return }
        params.append(.from(id))
        do {
            try await db.run("UPDATE receipts SET \(fields.joined(separator: ", ")) WHERE id = ?", params)
        } catch { report("Saving date/time", error) }
        await refreshList()
        await loadReceiptDetail(id: id)
    }

    // MARK: - Stats (GET /stats/summary, GET /stats/item-group)

    func statsSummary(start: String?, end: String?) async -> StatsSummary {
        var query = """
            SELECT d.category, d.subcategory, d.item_group, li.total_price
            FROM line_items li
            JOIN item_dictionary d ON li.item_dictionary_id = d.id
            JOIN receipts r ON li.receipt_id = r.id
            WHERE r.deleted_at IS NULL
            """
        var params: [SQLiteValue] = []
        if let start { query += " AND r.date >= ?"; params.append(.text(start)) }
        if let end { query += " AND r.date <= ?"; params.append(.text(end)) }

        let rows: [SQLRow]
        do { rows = try await db.query(query, params) } catch {
            report("Loading stats", error)
            return StatsSummary(total: 0, categories: [])
        }

        struct SubAccum { var total = 0.0; var groups: [String: Double] = [:] }
        struct CatAccum { var total = 0.0; var subcats: [String: SubAccum] = [:] }

        var tree: [String: CatAccum] = [:]
        var grandTotal = 0.0
        for row in rows {
            let category = row.string(0) ?? ""
            let subcategory = row.string(1) ?? ""
            let itemGroup = row.string(2) ?? ""
            let price = row.double(3) ?? 0
            grandTotal += price

            var cat = tree[category] ?? CatAccum()
            cat.total += price
            var sub = cat.subcats[subcategory] ?? SubAccum()
            sub.total += price
            sub.groups[itemGroup, default: 0] += price
            cat.subcats[subcategory] = sub
            tree[category] = cat
        }

        var categories: [CategoryStat] = tree.map { catName, catAccum in
            var subcats: [SubcategoryStat] = catAccum.subcats.map { subName, subAccum in
                let groups = subAccum.groups
                    .map { ItemGroupStat(itemGroup: $0.key, total: round2($0.value)) }
                    .sorted { $0.total > $1.total }
                return SubcategoryStat(subcategory: subName, total: round2(subAccum.total), itemGroups: groups)
            }
            subcats.sort { $0.total > $1.total }
            return CategoryStat(category: catName, total: round2(catAccum.total), subcategories: subcats)
        }
        categories.sort { $0.total > $1.total }

        return StatsSummary(total: round2(grandTotal), categories: categories)
    }

    func statsItemGroup(category: String, subcategory: String, itemGroup: String, start: String?, end: String?) async -> ItemGroupDetail {
        var query = """
            SELECT r.date, r.store, d.translation_en, li.name_de, li.quantity, li.unit_price,
                   li.total_price, li.receipt_id, d.id
            FROM line_items li
            JOIN item_dictionary d ON li.item_dictionary_id = d.id
            JOIN receipts r ON li.receipt_id = r.id
            WHERE r.deleted_at IS NULL AND d.category = ? AND d.subcategory = ? AND d.item_group = ?
            """
        var params: [SQLiteValue] = [.text(category), .text(subcategory), .text(itemGroup)]
        if let start { query += " AND r.date >= ?"; params.append(.text(start)) }
        if let end { query += " AND r.date <= ?"; params.append(.text(end)) }
        query += " ORDER BY r.date DESC"

        let rows: [SQLRow]
        do { rows = try await db.query(query, params) } catch {
            report("Loading item group", error)
            return ItemGroupDetail(category: category, subcategory: subcategory, itemGroup: itemGroup, total: 0, purchases: [])
        }
        let purchases = rows.map { row in
            PurchaseRow(
                date: row.string(0), store: row.string(1), translationEn: row.string(2), nameDe: row.string(3),
                quantity: row.double(4) ?? 0, unitPrice: row.double(5) ?? 0, totalPrice: row.double(6) ?? 0,
                receiptId: row.int(7) ?? 0, itemDictionaryId: row.int(8) ?? 0
            )
        }
        let total = round2(purchases.reduce(0) { $0 + $1.totalPrice })
        return ItemGroupDetail(category: category, subcategory: subcategory, itemGroup: itemGroup, total: total, purchases: purchases)
    }
}
