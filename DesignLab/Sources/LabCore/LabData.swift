import Foundation

/// Fake data. "Today" in the data is 2026-10-31. German stores and item names, as on real receipts; the app's own text
/// is English, as in production.
public enum LabData {
    // MARK: Product catalog (one entry = one dictionary id)

    private struct Product {
        let id: Int, raw: String, de: String, en: String, cat: String, sub: String, group: String
    }

    private static let f = "Food", h = "Household", p = "Personal Care", o = "Other"
    private static let catalog: [String: Product] = {
        let list: [(String, Product)] = [
            ("milk", .init(id: 1, raw: "H-MILCH 3,5%", de: "H-Milch 3,5 %", en: "UHT milk 3.5%", cat: f, sub: "Dairy & Eggs", group: "Milk")),
            ("oatmilk", .init(id: 2, raw: "HAFER DRINK BARISTA", de: "Haferdrink Barista", en: "Oat drink barista", cat: f, sub: "Dairy & Eggs", group: "Milk")),
            ("skyr", .init(id: 3, raw: "SKYR NATUR 450G", de: "Skyr Natur", en: "Plain skyr", cat: f, sub: "Dairy & Eggs", group: "Yogurt, Skyr & Quark")),
            ("gouda", .init(id: 4, raw: "GOUDA JUNG SCHEIBEN", de: "Gouda jung, Scheiben", en: "Young gouda, sliced", cat: f, sub: "Dairy & Eggs", group: "Cheese")),
            ("eggs", .init(id: 5, raw: "EIER BODENH. 10ER", de: "Eier Bodenhaltung, 10 Stück", en: "Barn eggs, 10 pack", cat: f, sub: "Dairy & Eggs", group: "Eggs")),
            ("tomato", .init(id: 6, raw: "RISPENTOMATEN", de: "Rispentomaten", en: "Vine tomatoes", cat: f, sub: "Vegetables", group: "Tomatoes")),
            ("cucumber", .init(id: 7, raw: "SALATGURKE ST", de: "Salatgurke", en: "Cucumber", cat: f, sub: "Vegetables", group: "Cucumbers, Squash & Eggplant")),
            ("carrot", .init(id: 8, raw: "MOEHREN 1KG", de: "Möhren", en: "Carrots", cat: f, sub: "Vegetables", group: "Root Vegetables")),
            ("banana", .init(id: 9, raw: "BANANEN", de: "Bananen", en: "Bananas", cat: f, sub: "Fruits", group: "Bananas")),
            ("apple", .init(id: 10, raw: "AEPFEL ELSTAR", de: "Äpfel Elstar", en: "Elstar apples", cat: f, sub: "Fruits", group: "Apples & Pears")),
            ("bread", .init(id: 11, raw: "ROGGENMISCHBROT", de: "Roggenmischbrot", en: "Rye bread", cat: f, sub: "Bakery", group: "Bread")),
            ("pretzel", .init(id: 12, raw: "LAUGENBREZEL", de: "Laugenbrezel", en: "Pretzel", cat: f, sub: "Bakery", group: "Pastries")),
            ("chicken", .init(id: 13, raw: "HAEHN.BRUSTFILET", de: "Hähnchenbrustfilet", en: "Chicken breast fillet", cat: f, sub: "Meat & Fish", group: "Poultry")),
            ("salmon", .init(id: 14, raw: "LACHSFILET TK", de: "Lachsfilet", en: "Salmon fillet", cat: f, sub: "Meat & Fish", group: "Fish & Seafood")),
            ("pasta", .init(id: 15, raw: "SPAGHETTI 500G", de: "Spaghetti", en: "Spaghetti", cat: f, sub: "Pantry", group: "Pasta & Rice")),
            ("coffee", .init(id: 16, raw: "KAFFEE CREMA BOHNE", de: "Caffè Crema, ganze Bohne", en: "Crema coffee beans", cat: f, sub: "Beverages", group: "Coffee & Tea")),
            ("water", .init(id: 17, raw: "MINERALW. MEDIUM", de: "Mineralwasser Medium", en: "Medium sparkling water", cat: f, sub: "Beverages", group: "Water")),
            ("wine", .init(id: 18, raw: "RIESLING TROCKEN", de: "Riesling trocken", en: "Dry Riesling", cat: f, sub: "Beverages", group: "Wine")),
            ("choc", .init(id: 19, raw: "ZARTBITTER 70%", de: "Zartbitterschokolade 70 %", en: "Dark chocolate 70%", cat: f, sub: "Snacks & Sweets", group: "Chocolate & Candy")),
            ("pizza", .init(id: 20, raw: "PIZZA MARGHERITA TK", de: "Pizza Margherita", en: "Frozen pizza margherita", cat: f, sub: "Frozen & Ready Meals", group: "Frozen Pizza")),
            ("detergent", .init(id: 21, raw: "COLORWASCHMITTEL", de: "Colorwaschmittel", en: "Colour detergent", cat: h, sub: "Cleaning", group: "Laundry")),
            ("toiletpaper", .init(id: 22, raw: "TOILETTENP. 3LG 8ER", de: "Toilettenpapier 3-lagig", en: "Toilet paper, 3 ply", cat: h, sub: "Paper Goods", group: "Toilet Paper")),
            ("shampoo", .init(id: 23, raw: "SHAMPOO REPAIR", de: "Shampoo Repair", en: "Repair shampoo", cat: p, sub: "Cosmetics", group: "Haircare")),
            ("toothpaste", .init(id: 24, raw: "ZAHNCREME SENSITIV", de: "Zahncreme Sensitiv", en: "Sensitive toothpaste", cat: p, sub: "Hygiene", group: "Oral Care")),
            ("shower", .init(id: 25, raw: "DUSCHGEL SPORT", de: "Duschgel Sport", en: "Sport shower gel", cat: p, sub: "Hygiene", group: "Shower & Bath")),
            ("plasters", .init(id: 26, raw: "PFLASTER SORTIERT", de: "Pflaster, sortiert", en: "Assorted plasters", cat: o, sub: "Pharmacy", group: "First Aid & Plasters")),
            ("deposit", .init(id: 27, raw: "PFAND 0,25", de: "Pfand", en: "Bottle deposit", cat: o, sub: "Deposits & Refunds", group: "Pfand")),
            ("refund", .init(id: 28, raw: "LEERGUT", de: "Leergut", en: "Empties refund", cat: o, sub: "Deposits & Refunds", group: "Returns & Refunds")),
            ("unknown", .init(id: 29, raw: "ART 44817 AKT", de: "Art. 44817 Aktion", en: "", cat: o, sub: "Miscellaneous", group: "General")),
        ]
        return Dictionary(uniqueKeysWithValues: list)
    }()

    /// `(product key, quantity, unit price)` into line items.
    private static func lines(_ receipt: Int, _ spec: [(String, Double, Double)], flagged: Set<String> = []) -> [LabLineItem] {
        spec.enumerated().map { index, row in
            let product = catalog[row.0]!
            return LabLineItem(
                id: receipt * 100 + index, itemDictionaryId: product.id, rawText: product.raw, nameDe: product.de,
                quantity: row.1, unitPrice: row.2, translationEn: product.en.isEmpty ? nil : product.en,
                category: product.cat, subcategory: product.sub, itemGroup: product.group,
                needsReview: flagged.contains(row.0)
            )
        }
    }

    private static func finished(_ id: Int, _ store: String, _ date: String, _ time: String, _ spec: [(String, Double, Double)],
                                 printedDelta: Double = 0, reasons: [String] = [], flagged: Set<String> = [],
                                 reviewed: Bool = true, location: String = "server") -> LabReceipt {
        let items = lines(id, spec, flagged: flagged)
        let sum = (items.reduce(0) { $0 + $1.totalPrice } * 100).rounded() / 100
        return LabReceipt(
            id: id, store: store, date: date, time: time, total: ((sum + printedDelta) * 100).rounded() / 100,
            needsReview: !reasons.isEmpty || !flagged.isEmpty, reviewReasons: reasons,
            reviewedAt: reviewed ? date + "T20:15:00Z" : nil, items: items, photoLocation: location,
            photoNote: location == "archived" ? "This photo is on your laptop." : nil
        )
    }

    // MARK: Named receipts used by screens

    /// Needs review: sum mismatch warning, one flagged item, a product bought twice (shows the "2×" bracket).
    public static let flagged = finished(
        412, "REWE", "2026-10-30", "18:42",
        [("milk", 2, 1.09), ("tomato", 0.482, 3.99), ("bread", 1, 2.79), ("chicken", 1, 6.49), ("skyr", 1, 1.79),
         ("skyr", 1, 1.79), ("choc", 1, 1.89), ("unknown", 1, 2.49), ("deposit", 6, 0.25)],
        printedDelta: 2.40,
        reasons: ["Item prices sum to 22.84, but printed total is 25.24 (difference: 2.4). Check raw_text per item."],
        flagged: ["unknown"], reviewed: false
    )

    /// Reviewed, nothing to fix ("Reviewed ✓").
    public static let reviewed = finished(
        405, "dm-drogerie markt", "2026-10-21", "12:07",
        [("shampoo", 1, 3.45), ("toothpaste", 1, 1.95), ("shower", 2, 0.95), ("plasters", 1, 2.25), ("toiletpaper", 1, 3.95)]
    )

    /// Photo archived on the laptop: the Photo tab shows the note, and no "Re-run extraction…".
    public static let photoOnLaptop = finished(
        391, "Kaufland", "2026-08-29", "11:20",
        [("pasta", 3, 0.89), ("water", 6, 0.49), ("deposit", 6, 0.25), ("carrot", 1, 1.29), ("wine", 1, 6.99)],
        location: "archived"
    )

    public static let waitingForUpload = LabReceipt(
        id: 420, store: nil, date: nil, time: nil, total: nil,
        processing: .waitingForUpload("The network connection was lost."), photoLocation: nil
    )

    public static let processing = LabReceipt(id: 419, store: nil, date: nil, time: nil, total: nil, processing: .processing)

    public static let uploadFailed = LabReceipt(
        id: 418, store: nil, date: nil, time: nil, total: nil,
        processing: .uploadFailed("The server did not accept this photo."), photoLocation: nil
    )

    public static let extractionFailed = LabReceipt(
        id: 417, store: nil, date: "2026-10-29", time: nil, total: nil,
        processing: .failed("The photo is too blurry to read.")
    )

    // MARK: Lists

    /// Finished receipts, newest first. Filter on `reviewedAt` for "Needs review" and "Reviewed", as production does.
    public static let receipts: [LabReceipt] = [
        flagged,
        finished(411, "ALDI SÜD", "2026-10-29", "17:55",
                 [("milk", 1, 0.99), ("banana", 1.124, 1.19), ("eggs", 1, 2.29), ("gouda", 1, 1.89), ("pizza", 2, 1.99), ("coffee", 1, 6.49)],
                 reasons: ["Possible duplicate of receipt #409"], reviewed: false),
        finished(410, "Lidl", "2026-10-28", "19:03",
                 [("oatmilk", 2, 1.65), ("apple", 1, 2.49), ("cucumber", 1, 0.79), ("pasta", 2, 0.89), ("salmon", 1, 4.99)],
                 reviewed: false),
        finished(409, "Bäckerei Schäfer", "2026-10-28", "08:12",
                 [("pretzel", 2, 0.95), ("bread", 1, 3.60)], reviewed: false),
        finished(408, "EDEKA", "2026-10-26", "18:30",
                 [("milk", 2, 1.15), ("chicken", 1, 7.29), ("tomato", 0.612, 3.49), ("carrot", 1, 1.39), ("wine", 1, 7.99), ("water", 6, 0.59), ("deposit", 6, 0.25)]),
        finished(407, "Rossmann", "2026-10-24", "13:40",
                 [("detergent", 1, 5.95), ("toiletpaper", 1, 3.75), ("toothpaste", 1, 1.65)]),
        finished(406, "REWE", "2026-10-23", "20:01",
                 [("oatmilk", 1, 1.89), ("gouda", 1, 2.19), ("banana", 0.915, 1.29), ("choc", 2, 1.79), ("refund", 8, -0.25)]),
        reviewed,
        finished(404, "Penny", "2026-10-17", "16:44",
                 [("pasta", 4, 0.79), ("tomato", 0.5, 3.29), ("eggs", 1, 2.19), ("pizza", 1, 2.29)]),
        finished(403, "ALDI SÜD", "2026-10-12", "18:09",
                 [("milk", 2, 0.99), ("bread", 1, 1.99), ("apple", 1, 2.29), ("skyr", 2, 1.29), ("coffee", 1, 5.99)]),
        finished(402, "Lidl", "2026-09-30", "19:21",
                 [("milk", 2, 0.95), ("chicken", 1, 5.99), ("cucumber", 2, 0.69), ("banana", 1.2, 1.15), ("choc", 1, 1.49)]),
        finished(401, "EDEKA", "2026-09-22", "17:38",
                 [("salmon", 1, 6.99), ("wine", 2, 6.99), ("gouda", 1, 2.39), ("bread", 1, 2.99), ("water", 6, 0.59), ("deposit", 6, 0.25)]),
        finished(400, "dm-drogerie markt", "2026-09-14", "12:51",
                 [("shower", 1, 0.95), ("shampoo", 1, 3.25), ("detergent", 1, 5.45)]),
        finished(399, "Kaufland", "2026-09-05", "10:30",
                 [("milk", 4, 0.89), ("carrot", 1, 1.19), ("pasta", 2, 0.85), ("coffee", 1, 5.79), ("toiletpaper", 1, 3.49)]),
        photoOnLaptop,
    ]

    /// Receipts still with the server or upload queue. They go in "Needs review" (row shows the state, no date).
    public static let processingReceipts: [LabReceipt] = [waitingForUpload, processing, uploadFailed, extractionFailed]

    /// "RECENTLY DELETED (n)".
    public static let deletedReceipts: [LabReceipt] = [
        finished(398, "Netto", "2026-10-11", "15:12", [("water", 6, 0.49), ("deposit", 6, 0.25)]),
        finished(385, "REWE", "2026-09-19", "18:05", [("pizza", 2, 2.49), ("choc", 1, 1.89)]),
    ]

    /// "UPLOADS - 3 of 5"; every state the panel shows on the phone.
    public static let uploadQueue: [LabUploadJob] = [
        .init(id: 1, fileName: "IMG_4821.HEIC", state: .uploaded(419)),
        .init(id: 2, fileName: "IMG_4822.HEIC", state: .duplicate(403)),
        .init(id: 3, fileName: "scan-2026-10-31.jpg", state: .uploading),
        .init(id: 4, fileName: "IMG_4823.HEIC", state: .queued),
        .init(id: 5, fileName: "IMG_4824.PNG", state: .failed("The server did not accept this photo.")),
    ]

    public static var unreviewed: [LabReceipt] { receipts.filter { $0.reviewedAt == nil } }
    public static var reviewedReceipts: [LabReceipt] { receipts.filter { $0.reviewedAt != nil } }
    /// Unreviewed receipts without review reasons: what "Confirm all without flags (n)" covers.
    public static var unflaggedUnreviewedCount: Int { unreviewed.filter { !$0.needsReview }.count }

    public static let dateRanges = ["All time", "This month", "Last 3 months", "This year"]
    public static var storesInUse: [String] { Array(Set(receipts.compactMap(\.store))).sorted() }
    public static let storeSuggestions = ["ALDI NORD", "ALDI SÜD", "Bäckerei Schäfer", "dm-drogerie markt", "EDEKA", "Kaufland", "Lidl", "Netto", "Penny", "REWE", "Rossmann"]

    // MARK: Status texts

    public static let syncStatus = "Synced 12 minutes ago"
    public static let syncStatusSyncing = "Syncing…"
    public static let syncStatusFailed = "Sync failed, retrying"
    public static let banners = [
        "14 receipt photo(s) (38 MB) wait on the server and have not been archived for over 30 days. Open Receipts on your laptop to archive them.",
        "The server is low on disk space (1.2 GB free). Archive its photos on your laptop.",
    ]
    public static let errorBanner = "Could not save the change: the database is busy."

    // MARK: Settings values

    public static let serverURL = "https://receipts.example.com"
    public static let lastSync = "Oct 31, 2026 at 09:48"
    public static let unsentChanges = 2
    public static let rejectedRecords = 1
    public static let syncError = "The server could not be reached."
    public static let cachedPhotos = "84.3 MB"
    public static let photoCacheLimit = "300 MB"
    public static let connectionOK = "Connected. 14 photo(s) on the server, extraction provider: anthropic."
    public static let connectionFailed = "The server could not be reached."
    public static let invalidURLMessage = "Not a valid address. Use https://… (plain http:// works for localhost in debug builds only)."

    // MARK: Stats, all derived from the receipts so a drill-down adds up

    public static func summary(_ range: LabRange) -> LabStatsSummary {
        switch range {
        case .month: return aggregate(receipts.filter { $0.date?.hasPrefix("2026-10") == true })
        case .custom: return aggregate(receipts.filter { ($0.date ?? "") >= "2026-09-30" })
        case .year: return scaled(aggregate(receipts), to: monthlyTotal(prefix: "2026"))
        case .all: return scaled(aggregate(receipts), to: monthlyTotal(prefix: ""))
        }
    }

    /// The period before, for "+12% vs last month" deltas. nil for Custom and All time (no deltas there).
    public static func previousSummary(_ range: LabRange) -> LabStatsSummary? {
        switch range {
        case .month: return aggregate(receipts.filter { $0.date?.hasPrefix("2026-09") == true })
        case .year: return scaled(aggregate(receipts), to: monthlyTotal(prefix: "2025") * 5.4)
        case .custom, .all: return nil
        }
    }

    /// Range labels as production shows them.
    public static func rangeLabel(_ range: LabRange) -> String {
        switch range {
        case .month: return "October 2026"
        case .year: return "2026"
        case .custom: return "2026-09-30 – 2026-10-31"
        case .all: return "All time"
        }
    }

    /// Month being emphasised in the bar chart in month view; the others dim.
    public static let highlightMonth = "2026-10"

    /// Twelve months, Nov 2025 to Oct 2026, stacked by category. Sep and Oct come from the receipts.
    public static let monthly: [LabMonthCategoryTotal] = {
        let past: [(String, Double, Double, Double, Double)] = [
            ("2025-11", 312.40, 41.20, 28.75, 6.10), ("2025-12", 398.15, 36.80, 52.30, 9.75),
            ("2026-01", 287.60, 58.45, 24.10, 4.25), ("2026-02", 264.30, 22.90, 31.65, 12.40),
            ("2026-03", 301.85, 47.10, 19.80, 7.60), ("2026-04", 322.50, 33.25, 44.35, 5.90),
            ("2026-05", 345.20, 29.60, 27.15, 8.35), ("2026-06", 298.75, 52.70, 38.90, 3.80),
            ("2026-07", 276.40, 18.35, 22.60, 6.70), ("2026-08", 309.95, 41.85, 33.20, 10.15),
        ]
        var out: [LabMonthCategoryTotal] = []
        for row in past {
            out.append(.init(month: row.0, category: "Food", total: row.1))
            out.append(.init(month: row.0, category: "Household", total: row.2))
            out.append(.init(month: row.0, category: "Personal Care", total: row.3))
            out.append(.init(month: row.0, category: "Other", total: row.4))
        }
        for month in ["2026-09", "2026-10"] {
            for cat in aggregate(receipts.filter { $0.date?.hasPrefix(month) == true }).categories {
                out.append(.init(month: month, category: cat.category, total: cat.total))
            }
        }
        return out
    }()

    public static func storeTotals(_ range: LabRange) -> [LabStoreTotal] {
        let scope = range == .month ? receipts.filter { $0.date?.hasPrefix("2026-10") == true } : receipts
        let factor = range == .month || range == .custom ? 1 : summary(range).total / aggregate(receipts).total
        var totals: [String: Double] = [:]
        for receipt in scope { totals[receipt.store ?? "Unknown", default: 0] += (receipt.computedSum ?? 0) * factor }
        return totals.map { LabStoreTotal(store: $0.key, total: round2($0.value)) }.sorted { $0.total > $1.total }
    }

    public static func purchases(category: String, subcategory: String, itemGroup: String, range: LabRange = .month) -> [LabPurchaseRow] {
        let scope = range == .month ? receipts.filter { $0.date?.hasPrefix("2026-10") == true } : receipts
        return scope.flatMap { receipt in
            receipt.items
                .filter { $0.category == category && $0.subcategory == subcategory && $0.itemGroup == itemGroup }
                .map { LabPurchaseRow(lineItemId: $0.id, date: receipt.date, store: receipt.store, translationEn: $0.translationEn,
                                      nameDe: $0.nameDe, quantity: $0.quantity, unitPrice: $0.unitPrice, totalPrice: $0.totalPrice, receiptId: receipt.id) }
        }
    }

    /// All time, one series per product. Production draws the chart when there are at least 2 points.
    public static func priceHistory(category: String, subcategory: String, itemGroup: String) -> [LabPricePoint] {
        purchases(category: category, subcategory: subcategory, itemGroup: itemGroup, range: .all)
            .map { LabPricePoint(dateString: $0.date ?? "", item: $0.translationEn ?? $0.nameDe ?? "", unitPrice: $0.unitPrice) }
            .sorted { $0.dateString < $1.dateString }
    }

    /// The node `overviewDrilldown` opens: Food > Dairy & Eggs > Milk.
    public static let drilldownPath = (category: "Food", subcategory: "Dairy & Eggs", itemGroup: "Milk")

    /// A receipt by id, for a purchase row's "Edit" (production jumps to the receipt).
    public static func receipt(id: Int) -> LabReceipt? {
        (receipts + processingReceipts + deletedReceipts).first { $0.id == id }
    }

    // MARK: Helpers

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    private static func monthlyTotal(prefix: String) -> Double {
        return monthly.filter { prefix.isEmpty || $0.month.hasPrefix(prefix) }.reduce(0) { $0 + $1.total }
    }

    private static func aggregate(_ list: [LabReceipt]) -> LabStatsSummary {
        var tree: [String: [String: [String: Double]]] = [:]
        for receipt in list {
            for item in receipt.items { tree[item.category, default: [:]][item.subcategory, default: [:]][item.itemGroup, default: 0] += item.totalPrice }
        }
        let categories = tree.map { cat, subs -> LabCategoryStat in
            let subStats = subs.map { sub, groups -> LabSubcategoryStat in
                let groupStats = groups.map { LabItemGroupStat(itemGroup: $0.key, total: round2($0.value)) }.sorted { $0.total > $1.total }
                return LabSubcategoryStat(subcategory: sub, total: round2(groups.values.reduce(0, +)), itemGroups: groupStats)
            }.sorted { $0.total > $1.total }
            return LabCategoryStat(category: cat, total: round2(subStats.reduce(0) { $0 + $1.total }), subcategories: subStats)
        }.sorted { $0.total > $1.total }
        return LabStatsSummary(total: round2(categories.reduce(0) { $0 + $1.total }), categories: categories)
    }

    private static func scaled(_ summary: LabStatsSummary, to total: Double) -> LabStatsSummary {
        guard summary.total > 0 else { return summary }
        let k = total / summary.total
        return LabStatsSummary(total: round2(total), categories: summary.categories.map { cat in
            LabCategoryStat(category: cat.category, total: round2(cat.total * k), subcategories: cat.subcategories.map { sub in
                LabSubcategoryStat(subcategory: sub.subcategory, total: round2(sub.total * k), itemGroups: sub.itemGroups.map {
                    LabItemGroupStat(itemGroup: $0.itemGroup, total: round2($0.total * k))
                })
            })
        })
    }
}
