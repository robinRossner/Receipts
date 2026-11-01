import Foundation

// "No good category": items the categoriser could not file (it found no fitting category in the taxonomy) are filed under
// Other > Miscellaneous > General, flagged on their dictionary entry together with a suggestion for the missing category, and
// can be resolved later: with an existing category, or by adding the (suggested) category to the taxonomy and using it.
//
// The flag lives on the dictionary entry (`item_dictionary.category_flagged`), because the category does: resolving one entry
// fixes every receipt that uses the item. Overview totals are unaffected (the fallback path is a normal category).

/// One flagged dictionary entry with how often it is used.
struct FlaggedItem: Identifiable, Hashable, Sendable {
    /// The dictionary entry id (pass it to `resolveFlaggedItems`).
    let id: Int
    let name: String
    let translationEn: String?
    /// Short name of the category the model found missing, e.g. "Pet Food".
    let suggestedCategory: String?
    /// "Category" or "Category > Subcategory" it would go under (existing or new names).
    let suggestedParent: String?
    /// Line items on live receipts that use this entry, and what they cost together.
    let itemCount: Int
    let totalSpend: Double
    /// Live receipts that contain it, newest id first (to jump to one).
    let receiptIds: [Int]

    /// The taxonomy path the suggestion stands for: a two-part parent gives (category, subcategory, name), a one-part parent
    /// (category, name, "General"). nil without a usable suggestion.
    var suggestedPath: Taxonomy.Path? { FlaggedItems.path(suggestedCategory: suggestedCategory, suggestedParent: suggestedParent) }
}

/// Flagged items that share one suggestion (so one new category can resolve them all).
struct FlaggedGroup: Identifiable, Hashable, Sendable {
    /// Lowercased "parent|name"; empty for the group of items without a suggestion.
    let id: String
    let suggestedCategory: String?
    let suggestedParent: String?
    let items: [FlaggedItem]
    var suggestedPath: Taxonomy.Path? { FlaggedItems.path(suggestedCategory: suggestedCategory, suggestedParent: suggestedParent) }
    var itemCount: Int { items.reduce(0) { $0 + $1.itemCount } }
    var totalSpend: Double { items.reduce(0) { $0 + $1.totalSpend } }
    var dictionaryIds: [Int] { items.map(\.id) }
}

enum FlagResolution: Equatable, Sendable {
    /// `count` dictionary entries were resolved (flag cleared, category set, manual override).
    case resolved(count: Int)
    /// Nothing changed: the reason is user-presentable (invalid or unknown category).
    case invalid(String)
}

/// Database level of the flagged-items feature (the store methods below are thin wrappers), usable without the UI store.
enum FlaggedItems {
    static func path(suggestedCategory: String?, suggestedParent: String?) -> Taxonomy.Path? {
        guard let name = suggestedCategory, !name.isEmpty, let parent = suggestedParent else { return nil }
        let parts = parent.components(separatedBy: " > ")
        switch parts.count {
        case 1: return Taxonomy.Path(parts[0], name, "General")
        case 2: return Taxonomy.Path(parts[0], parts[1], name)
        default: return nil
        }
    }

    static func list(db: Database) async throws -> [FlaggedItem] {
        let rows = try await db.query("""
            SELECT d.id, COALESCE(NULLIF(d.display_name_de, ''), d.canonical_name), d.translation_en, d.suggested_category,
                   d.suggested_parent, COUNT(li.id), COALESCE(SUM(li.total_price), 0), group_concat(DISTINCT r.id)
            FROM item_dictionary d
            JOIN line_items li ON li.item_dictionary_id = d.id
            JOIN receipts r ON r.id = li.receipt_id AND r.deleted_at IS NULL
            WHERE d.category_flagged = 1
            GROUP BY d.id
            ORDER BY lower(COALESCE(d.suggested_parent, '')), lower(COALESCE(d.suggested_category, '')), d.id
            """)
        return rows.map { r in
            let ids = (r.string(7) ?? "").split(separator: ",").compactMap { Int($0) }.sorted(by: >)
            return FlaggedItem(
                id: r.int(0) ?? 0, name: r.string(1) ?? "", translationEn: r.string(2), suggestedCategory: r.string(3),
                suggestedParent: r.string(4), itemCount: r.int(5) ?? 0, totalSpend: r.double(6) ?? 0, receiptIds: ids)
        }
    }

    /// Flagged entries that a live receipt uses (what `list` returns, counted).
    static func count(db: Database) async throws -> Int {
        try await db.queryOne("""
            SELECT COUNT(*) FROM item_dictionary d WHERE d.category_flagged = 1 AND EXISTS (
                SELECT 1 FROM line_items li JOIN receipts r ON r.id = li.receipt_id AND r.deleted_at IS NULL
                WHERE li.item_dictionary_id = d.id)
            """)?.int(0) ?? 0
    }

    /// Groups by suggestion (case-insensitive); biggest groups first, the group without a suggestion last.
    static func group(_ items: [FlaggedItem]) -> [FlaggedGroup] {
        var order: [String] = []
        var buckets: [String: [FlaggedItem]] = [:]
        for item in items {
            let key = path(suggestedCategory: item.suggestedCategory, suggestedParent: item.suggestedParent)
                .map { "\($0.category)|\($0.subcategory)|\($0.itemGroup)".lowercased() } ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        let groups = order.map { key -> FlaggedGroup in
            let items = buckets[key] ?? []
            return FlaggedGroup(id: key, suggestedCategory: items.first?.suggestedCategory, suggestedParent: items.first?.suggestedParent, items: items)
        }
        return groups.sorted {
            if ($0.id.isEmpty) != ($1.id.isEmpty) { return !$0.id.isEmpty }
            return $0.itemCount != $1.itemCount ? $0.itemCount > $1.itemCount : $0.id < $1.id
        }
    }

    /// Files these flagged entries under `path`: category set, manual override (extraction never changes it again), flag and
    /// suggestion cleared. Entries that are not flagged are left alone. Returns how many were resolved. The change tracking
    /// triggers mark the rows for the next push. The caller makes sure `path` is in the taxonomy.
    @discardableResult
    static func resolve(db: Database, dictionaryIds: [Int], to path: Taxonomy.Path) async throws -> Int {
        guard !dictionaryIds.isEmpty else { return 0 }
        return try await db.transaction { c in
            var n = 0
            for id in dictionaryIds {
                try c.run("""
                    UPDATE item_dictionary
                    SET category = ?, subcategory = ?, item_group = ?, is_manual_override = 1, needs_review = 0,
                        category_flagged = 0, suggested_category = NULL, suggested_parent = NULL
                    WHERE id = ? AND category_flagged = 1
                    """, [.text(path.category), .text(path.subcategory), .text(path.itemGroup), .from(id)])
                n += try c.queryOne("SELECT changes()")?.int(0) ?? 0
            }
            return n
        }
    }

    static func additions(db: Database) async throws -> [Taxonomy.Path] {
        try await db.query("SELECT category, subcategory, item_group FROM taxonomy_additions ORDER BY created_at, id")
            .map { Taxonomy.Path($0.string(0) ?? "", $0.string(1) ?? "", $0.string(2) ?? "") }
    }

    /// Stores a new taxonomy path (dirty until the server has it). False when the same path (ignoring case) is already stored.
    static func addPath(db: Database, _ path: Taxonomy.Path) async throws -> Bool {
        try await db.transaction { c in
            try c.run("""
                INSERT OR IGNORE INTO taxonomy_additions (category, subcategory, item_group, created_at, sync_state)
                VALUES (?, ?, ?, ?, 'dirty')
                """, [.text(path.category), .text(path.subcategory), .text(path.itemGroup), .text(SyncDate.now())])
            return (try c.queryOne("SELECT changes()")?.int(0) ?? 0) > 0
        }
    }
}

extension ReceiptStore {
    /// Re-reads the user-added categories and merges them onto the bundled taxonomy (what pickers and the categoriser use).
    func reloadTaxonomy() async {
        guard let added = try? await FlaggedItems.additions(db: db) else { return }
        let merged = baseTaxonomy.adding(added)
        if merged.categories.map(\.name) != taxonomy.categories.map(\.name)
            || merged.categories.flatMap({ $0.subcategories.map(\.itemGroups) }) != taxonomy.categories.flatMap({ $0.subcategories.map(\.itemGroups) }) {
            taxonomy = merged
        }
    }

    func refreshFlaggedCount() async {
        let n = (try? await FlaggedItems.count(db: db)) ?? 0
        if n != flaggedItemCount { flaggedItemCount = n }
    }

    /// Every unresolved flagged item (used by a live receipt), ordered by suggestion.
    func flaggedItems() async -> [FlaggedItem] {
        do { return try await FlaggedItems.list(db: db) } catch { report("Loading flagged items", error); return [] }
    }

    /// The same, grouped by suggested category (biggest group first, items without suggestion last).
    func flaggedGroups() async -> [FlaggedGroup] { FlaggedItems.group(await flaggedItems()) }

    /// Files flagged items under an EXISTING category (the path must be in `taxonomy`; "Other > Miscellaneous > General" keeps
    /// them there and just clears the flag).
    @discardableResult
    func resolveFlaggedItems(_ dictionaryIds: [Int], to path: Taxonomy.Path) async -> FlagResolution {
        guard let existing = taxonomy.canonicalPath(matching: path) else {
            return .invalid("\(path.label) is not in the category list. Add it first.")
        }
        return await finishResolve(dictionaryIds, existing)
    }

    /// Adds `path` to the taxonomy (when it is new; syncs to the server and the other devices) and files the flagged items
    /// under it. Use `FlaggedItem.suggestedPath` / `FlaggedGroup.suggestedPath` for "add the proposed category".
    @discardableResult
    func resolveFlaggedItems(_ dictionaryIds: [Int], addingCategory path: Taxonomy.Path) async -> FlagResolution {
        switch await addTaxonomyPath(path) {
        case .invalid(let why): return .invalid(why)
        case .resolved: break
        }
        guard let target = taxonomy.canonicalPath(matching: path) else { return .invalid("Could not add \(path.label).") }
        return await finishResolve(dictionaryIds, target)
    }

    /// Adds a path to the category list without resolving anything (names of an existing category or subcategory are
    /// matched ignoring case and take its spelling). `.resolved(count: 0)` = it already existed, `1` = added.
    @discardableResult
    func addTaxonomyPath(_ path: Taxonomy.Path) async -> FlagResolution {
        let trimmed = Taxonomy.Path(path.category.trimmingCharacters(in: .whitespaces), path.subcategory.trimmingCharacters(in: .whitespaces),
                                    path.itemGroup.trimmingCharacters(in: .whitespaces))
        if let problem = Taxonomy.additionProblem(trimmed) { return .invalid(problem) }
        await reloadTaxonomy()
        if taxonomy.canonicalPath(matching: trimmed) != nil { return .resolved(count: 0) }
        let category = taxonomy.canonicalCategory(trimmed.category) ?? trimmed.category
        let sub = taxonomy.canonicalSubcategory(trimmed.subcategory, in: category) ?? trimmed.subcategory
        do {
            let added = try await FlaggedItems.addPath(db: db, Taxonomy.Path(category, sub, trimmed.itemGroup))
            await reloadTaxonomy()
            await sync.syncIfLocalChangesPending()
            return .resolved(count: added ? 1 : 0)
        } catch {
            report("Adding category", error)
            return .invalid("Could not save the category: \(error)")
        }
    }

    private func finishResolve(_ ids: [Int], _ path: Taxonomy.Path) async -> FlagResolution {
        do {
            let n = try await FlaggedItems.resolve(db: db, dictionaryIds: ids, to: path)
            await refreshList()
            if let id = selectedReceiptID { await loadReceiptDetail(id: id) }
            return .resolved(count: n)
        } catch {
            report("Resolving flagged items", error)
            return .invalid("Could not save: \(error)")
        }
    }
}
