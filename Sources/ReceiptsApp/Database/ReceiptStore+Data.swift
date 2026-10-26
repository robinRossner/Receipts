import AppKit
import UniformTypeIdentifiers

/// Export, backup and dictionary maintenance.
extension ReceiptStore {
    enum ExportKind: String, CaseIterable, Identifiable {
        case lineItemsCSV = "Line items (CSV)"
        case receiptsCSV = "Receipts (CSV)"
        case everythingJSON = "Everything (JSON)"
        var id: String { rawValue }
    }

    // MARK: - Export

    /// Asks where to save, then writes the export. `useOverviewRange` is ignored for JSON (always everything).
    func export(kind: ExportKind, useOverviewRange: Bool, format: DataExporter.Format) async {
        let panel = NSSavePanel()
        let stamp = ReceiptDateFormat.dateString(from: Date())
        switch kind {
        case .lineItemsCSV: panel.nameFieldStringValue = "receipt-items-\(stamp).csv"; panel.allowedContentTypes = [.commaSeparatedText]
        case .receiptsCSV: panel.nameFieldStringValue = "receipts-\(stamp).csv"; panel.allowedContentTypes = [.commaSeparatedText]
        case .everythingJSON: panel.nameFieldStringValue = "receipts-export-\(stamp).json"; panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let start = useOverviewRange ? overviewRange.start : nil
        let end = useOverviewRange ? overviewRange.end : nil
        do {
            let data: Data
            switch kind {
            case .lineItemsCSV: data = try await DataExporter.lineItemsCSV(db: db, start: start, end: end, format: format)
            case .receiptsCSV: data = try await DataExporter.receiptsCSV(db: db, start: start, end: end, format: format)
            case .everythingJSON: data = try await DataExporter.everythingJSON(db: db)
            }
            try data.write(to: url, options: .atomic)
        } catch { report("Exporting", error) }
    }

    // MARK: - Backup

    func backUpNow() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose a folder for the backup zip (database + receipt images)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        await runBackup(to: folder, prune: false)
    }

    /// Weekly backup into the Settings folder, if enabled and due.
    func runAutoBackupIfDue() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: BackupService.Keys.autoEnabled),
              let path = d.string(forKey: BackupService.Keys.autoFolder), !path.isEmpty else { return }
        if let last = BackupService.lastBackupDate, Date().timeIntervalSince(last) < BackupService.interval { return }
        await runBackup(to: URL(fileURLWithPath: path, isDirectory: true), prune: true)
    }

    private func runBackup(to folder: URL, prune: Bool) async {
        do {
            try await BackupService.createBackup(db: db, env: env, intoFolder: folder)
            if prune { BackupService.prune(folder: folder) }
        } catch { report("Backing up", error) }
        lastBackupDate = BackupService.lastBackupDate
    }

    // MARK: - Dictionary editor

    struct DictionaryRow: Identifiable, Hashable {
        let id: Int
        var canonicalName: String
        var displayNameDe: String
        var translationEn: String
        var category: String
        var subcategory: String
        var itemGroup: String
        var isManual: Bool
        var timesSeen: Int
        var pathLabel: String { [category, subcategory, itemGroup].filter { !$0.isEmpty }.joined(separator: " › ") }
    }

    func dictionaryRows() async -> [DictionaryRow] {
        do {
            let rows = try await db.query("""
                SELECT id, canonical_name, COALESCE(display_name_de, ''), COALESCE(translation_en, ''), COALESCE(category, ''),
                       COALESCE(subcategory, ''), COALESCE(item_group, ''), is_manual_override, times_seen
                FROM item_dictionary ORDER BY lower(COALESCE(display_name_de, canonical_name))
                """)
            return rows.map {
                DictionaryRow(id: $0.int(0) ?? 0, canonicalName: $0.string(1) ?? "", displayNameDe: $0.string(2) ?? "",
                              translationEn: $0.string(3) ?? "", category: $0.string(4) ?? "", subcategory: $0.string(5) ?? "",
                              itemGroup: $0.string(6) ?? "", isManual: $0.bool(7), timesSeen: $0.int(8) ?? 0)
            }
        } catch { report("Loading dictionary", error); return [] }
    }

    /// Edit names and category of an entry. Counts as a manual correction (is_manual_override = 1).
    func updateDictionaryEntry(_ row: DictionaryRow) async {
        do {
            try await db.run("""
                UPDATE item_dictionary SET display_name_de = ?, translation_en = ?, category = ?, subcategory = ?, item_group = ?,
                    is_manual_override = 1, needs_review = 0 WHERE id = ?
                """, [.text(row.displayNameDe), .from(row.translationEn.isEmpty ? nil : row.translationEn),
                      .text(row.category), .text(row.subcategory), .text(row.itemGroup), .from(row.id)])
        } catch { report("Saving dictionary entry", error) }
        await afterDictionaryChange()
    }

    /// Repoints source's line items to target, unions aliases (plus source's canonical name),
    /// adds times_seen and deletes the source - one transaction.
    func mergeDictionaryEntries(sourceId: Int, targetId: Int) async {
        guard sourceId != targetId else { return }
        do {
            try await db.transaction { conn in
                func row(_ id: Int) throws -> SQLRow? {
                    try conn.queryOne("SELECT canonical_name, aliases, times_seen FROM item_dictionary WHERE id = ?", [.from(id)])
                }
                guard let src = try row(sourceId), let dst = try row(targetId) else {
                    throw DatabaseError.stepFailed("dictionary entry not found", "")
                }
                var aliases = decodeStringArray(dst.string(1))
                for a in decodeStringArray(src.string(1)) + [src.string(0) ?? ""] where !a.isEmpty && !aliases.contains(a) && a != dst.string(0) {
                    aliases.append(a)
                }
                try conn.run("UPDATE line_items SET item_dictionary_id = ? WHERE item_dictionary_id = ?", [.from(targetId), .from(sourceId)])
                try conn.run("UPDATE item_dictionary SET aliases = ?, times_seen = ? WHERE id = ?",
                             [.text(encodeStringArray(aliases)), .from((dst.int(2) ?? 0) + (src.int(2) ?? 0)), .from(targetId)])
                try conn.run("DELETE FROM item_dictionary WHERE id = ?", [.from(sourceId)])
            }
        } catch { report("Merging entries", error) }
        await afterDictionaryChange()
    }

    private func afterDictionaryChange() async {
        invalidateStatsCache()
        if let id = selectedReceiptID { await loadReceiptDetail(id: id) }
    }
}
