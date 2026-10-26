import Foundation

/// Aggregations for the Overview page. All grouping happens in SQL (GROUP BY); results are
/// cached per query until `invalidateStatsCache()` (called on any data change).
extension ReceiptStore {
    private func dateFilter(_ start: String?, _ end: String?) -> (sql: String, params: [SQLiteValue]) {
        var sql = "", params: [SQLiteValue] = []
        if let start { sql += " AND r.date >= ?"; params.append(.text(start)) }
        if let end { sql += " AND r.date <= ?"; params.append(.text(end)) }
        return (sql, params)
    }

    private func cached<T>(_ key: String, _ compute: () async -> T) async -> T {
        if let hit = statsCache[key] as? T { return hit }
        let value = await compute()
        statsCache[key] = value
        return value
    }

    func statsSummary(start: String?, end: String?) async -> StatsSummary {
        await cached("summary|\(start ?? "")|\(end ?? "")") {
            let f = dateFilter(start, end)
            let rows: [SQLRow]
            do {
                rows = try await db.query("""
                    SELECT COALESCE(d.category, ''), COALESCE(d.subcategory, ''), COALESCE(d.item_group, ''), SUM(li.total_price)
                    FROM line_items li
                    JOIN item_dictionary d ON li.item_dictionary_id = d.id
                    JOIN receipts r ON li.receipt_id = r.id
                    WHERE r.deleted_at IS NULL\(f.sql)
                    GROUP BY d.category, d.subcategory, d.item_group
                    """, f.params)
            } catch {
                report("Loading stats", error)
                return StatsSummary(total: 0, categories: [])
            }

            var tree: [String: [String: [ItemGroupStat]]] = [:]
            for row in rows {
                tree[row.string(0) ?? "", default: [:]][row.string(1) ?? "", default: []]
                    .append(ItemGroupStat(itemGroup: row.string(2) ?? "", total: round2(row.double(3) ?? 0)))
            }
            var categories: [CategoryStat] = tree.map { cat, subs in
                var subcats = subs.map { name, groups in
                    SubcategoryStat(subcategory: name, total: round2(groups.reduce(0) { $0 + $1.total }),
                                    itemGroups: groups.sorted { $0.total > $1.total })
                }
                subcats.sort { $0.total > $1.total }
                return CategoryStat(category: cat, total: round2(subcats.reduce(0) { $0 + $1.total }), subcategories: subcats)
            }
            categories.sort { $0.total > $1.total }
            return StatsSummary(total: round2(categories.reduce(0) { $0 + $1.total }), categories: categories)
        }
    }

    /// Spend per month and top-level category within the range.
    func statsMonthly(start: String?, end: String?) async -> [MonthCategoryTotal] {
        await cached("monthly|\(start ?? "")|\(end ?? "")") {
            let f = dateFilter(start, end)
            do {
                let rows = try await db.query("""
                    SELECT substr(r.date, 1, 7), COALESCE(d.category, ''), SUM(li.total_price)
                    FROM line_items li
                    JOIN item_dictionary d ON li.item_dictionary_id = d.id
                    JOIN receipts r ON li.receipt_id = r.id
                    WHERE r.deleted_at IS NULL AND r.date IS NOT NULL\(f.sql)
                    GROUP BY 1, 2 ORDER BY 1
                    """, f.params)
                return rows.map { MonthCategoryTotal(month: $0.string(0) ?? "", category: $0.string(1) ?? "", total: round2($0.double(2) ?? 0)) }
            } catch {
                report("Loading monthly stats", error)
                return []
            }
        }
    }

    func statsByStore(start: String?, end: String?) async -> [StoreTotal] {
        await cached("stores|\(start ?? "")|\(end ?? "")") {
            let f = dateFilter(start, end)
            do {
                let rows = try await db.query("""
                    SELECT COALESCE(NULLIF(r.store, ''), 'Unknown'), SUM(li.total_price)
                    FROM line_items li JOIN receipts r ON li.receipt_id = r.id
                    WHERE r.deleted_at IS NULL\(f.sql)
                    GROUP BY 1 ORDER BY 2 DESC
                    """, f.params)
                return rows.map { StoreTotal(store: $0.string(0) ?? "", total: round2($0.double(1) ?? 0)) }
            } catch {
                report("Loading store totals", error)
                return []
            }
        }
    }

    /// Unit price over time for the most-bought items of an item group (all time, ignores the Overview range).
    func statsPriceHistory(category: String, subcategory: String, itemGroup: String) async -> [PricePoint] {
        await cached("prices|\(category)|\(subcategory)|\(itemGroup)") {
            do {
                let rows = try await db.query("""
                    SELECT r.date, COALESCE(d.translation_en, li.name_de, d.canonical_name), li.unit_price, d.id
                    FROM line_items li
                    JOIN item_dictionary d ON li.item_dictionary_id = d.id
                    JOIN receipts r ON li.receipt_id = r.id
                    WHERE r.deleted_at IS NULL AND r.date IS NOT NULL
                      AND d.category = ? AND d.subcategory = ? AND d.item_group = ? AND li.unit_price > 0
                    ORDER BY r.date
                    """, [.text(category), .text(subcategory), .text(itemGroup)])
                var counts: [Int: Int] = [:]
                for r in rows { counts[r.int(3) ?? 0, default: 0] += 1 }
                let top = Set(counts.sorted { $0.value > $1.value }.prefix(5).map(\.key))
                return rows.compactMap { r in
                    guard top.contains(r.int(3) ?? 0), let d = ReceiptDateFormat.date(from: r.string(0)) else { return nil }
                    return PricePoint(date: d, item: r.string(1) ?? "", unitPrice: r.double(2) ?? 0)
                }
            } catch {
                report("Loading price history", error)
                return []
            }
        }
    }
}
