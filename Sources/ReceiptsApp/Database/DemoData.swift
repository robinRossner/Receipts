#if DEBUG
import Foundation

/// Made-up receipts for screenshots and manual demos (debug builds only). Never touches real data: the seeding is refused
/// unless `RECEIPTS_APP_DATA_DIR` points somewhere else and the database is empty.
///
/// Launch with `RECEIPTS_APP_DATA_DIR=/some/temp/dir RECEIPTS_DEMO_DATA=1` (the iPhone simulator needs the `SIMCTL_CHILD_` prefix).
enum DemoData {
    static let envVar = "RECEIPTS_DEMO_DATA"

    private typealias Line = (name: String, en: String, qty: Double, price: Double, path: String)
    private typealias Demo = (store: String, date: String, time: String, lines: [Line], reviewed: Bool)

    static func seedIfRequested(db: Database, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard environment[envVar] == "1", environment[AppEnvironment.dataDirEnvVar]?.isEmpty == false else { return }
        try? await seed(db: db)
    }

    static func seed(db: Database) async throws {
        guard try await db.queryOne("SELECT id FROM receipts LIMIT 1") == nil else { return }
        for r in receipts {
            let total = r.lines.reduce(0) { $0 + ($1.qty * $1.price * 100).rounded() / 100 }
            let created = r.date + "T" + r.time + ":00Z"
            let receiptId = try await db.run(
                """
                INSERT INTO receipts (store, date, time, total, computed_sum, needs_review, review_reasons, created_at, reviewed_at)
                VALUES (?, ?, ?, ?, ?, 0, '[]', ?, ?)
                """,
                [.text(r.store), .text(r.date), .text(r.time), .real(total), .real(total), .text(created), r.reviewed ? .text(created) : .null]
            )
            for l in r.lines {
                let parts = l.path.components(separatedBy: " > ")
                let canonical = l.name.lowercased()
                try await db.run(
                    """
                    INSERT OR IGNORE INTO item_dictionary
                    (canonical_name, display_name_de, translation_en, category, subcategory, item_group, aliases, created_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, '[]', ?, ?)
                    """,
                    [.text(canonical), .text(l.name), .text(l.en), .text(parts[0]), .text(parts[1]), .text(parts.count > 2 ? parts[2] : ""), .text(created), .text(created)]
                )
                let dictId = try await db.queryOne("SELECT id FROM item_dictionary WHERE canonical_name = ?", [.text(canonical)])?.int(0) ?? 0
                try await db.run(
                    """
                    INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity, unit_price, total_price, price_normalized)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                    """,
                    [.integer(receiptId), .from(dictId), .text(l.name.uppercased()), .text(l.name), .real(l.qty), .real(l.price), .real((l.qty * l.price * 100).rounded() / 100)]
                )
            }
        }
    }

    private static let receipts: [Demo] = [
        ("Fresh Mart", "2026-11-18", "17:42", [
            ("Bananen", "bananas", 1, 1.89, "Food > Fruits > Bananas"),
            ("Milch 1L", "milk", 2, 1.19, "Food > Dairy & Eggs > Milk"),
            ("Joghurt Natur", "plain yogurt", 2, 0.89, "Food > Dairy & Eggs > Yogurt, Skyr & Quark"),
            ("Tomaten", "tomatoes", 1, 2.49, "Food > Vegetables > Tomatoes"),
            ("Spaghetti 500g", "spaghetti", 2, 1.29, "Food > Pantry > Pasta & Rice"),
            ("Bio Eier 10er", "organic eggs", 1, 3.29, "Food > Dairy & Eggs > Eggs"),
        ], false),
        ("Corner Bakery", "2026-11-16", "08:15", [
            ("Roggenbrot", "rye bread", 1, 3.80, "Food > Bakery > Bread"),
            ("Brötchen", "bread rolls", 4, 0.55, "Food > Bakery > Bread"),
            ("Butterbrezel", "butter pretzel", 2, 1.60, "Food > Bakery > Pastries"),
            ("Cappuccino", "cappuccino", 1, 3.20, "Food > Beverages > Coffee & Tea"),
        ], true),
        ("City Pharmacy", "2026-11-12", "13:05", [
            ("Ibuprofen 400", "ibuprofen 400", 1, 5.95, "Other > Pharmacy > General"),
            ("Pflaster Set", "plaster set", 1, 3.45, "Other > Pharmacy > First Aid & Plasters"),
            ("Vitamin D Tropfen", "vitamin D drops", 1, 12.90, "Other > Pharmacy > Supplements"),
            ("Zahnpasta", "toothpaste", 2, 1.95, "Personal Care > Hygiene > Oral Care"),
        ], true),
        ("Fresh Mart", "2026-11-08", "18:20", [
            ("Hähnchenbrust", "chicken breast", 1, 6.99, "Food > Meat & Fish > Poultry"),
            ("Reis 1kg", "rice", 1, 2.29, "Food > Pantry > Pasta & Rice"),
            ("Paprika rot", "red pepper", 3, 0.99, "Food > Vegetables > Peppers"),
            ("Gouda am Stück", "gouda", 1, 2.79, "Food > Dairy & Eggs > Cheese"),
            ("Mineralwasser", "mineral water", 6, 0.35, "Food > Beverages > Water"),
            ("Pfand", "deposit", 6, 0.25, "Other > Deposits & Refunds > Pfand"),
        ], true),
        ("Green Basket Market", "2026-10-29", "11:30", [
            ("Äpfel Elstar", "apples", 1, 3.49, "Food > Fruits > Apples & Pears"),
            ("Feldsalat", "lamb's lettuce", 1, 1.99, "Food > Vegetables > Leafy Greens"),
            ("Haferflocken", "rolled oats", 1, 1.49, "Food > Pantry > Cereals & Muesli"),
            ("Orangensaft", "orange juice", 1, 2.29, "Food > Beverages > Juice"),
            ("Zartbitterschokolade", "dark chocolate", 2, 1.19, "Food > Snacks & Sweets > Chocolate & Candy"),
        ], true),
        ("Home & Clean Drogerie", "2026-10-21", "16:48", [
            ("Spülmittel", "dish soap", 1, 1.65, "Household > Cleaning > Dishwashing"),
            ("Toilettenpapier 8er", "toilet paper", 1, 3.95, "Household > Paper Goods > Toilet Paper"),
            ("Küchenrolle", "kitchen roll", 1, 2.49, "Household > Paper Goods > Kitchen Roll"),
            ("Duschgel", "shower gel", 2, 1.45, "Personal Care > Hygiene > Shower & Bath"),
            ("Sonnencreme LSF 30", "sunscreen SPF 30", 1, 5.99, "Personal Care > Cosmetics > Sun Care"),
        ], true),
        ("Fresh Mart", "2026-10-10", "19:02", [
            ("Tiefkühlpizza", "frozen pizza", 2, 2.79, "Food > Frozen & Ready Meals > Frozen Pizza"),
            ("Eiscreme Vanille", "vanilla ice cream", 1, 3.49, "Food > Frozen & Ready Meals > Ice Cream"),
            ("Kartoffelchips", "potato chips", 1, 1.99, "Food > Snacks & Sweets > Chips & Snacks"),
            ("Pils 0,5L", "pilsner", 4, 0.89, "Food > Beverages > Beer"),
            ("Pfand", "deposit", 4, 0.08, "Other > Deposits & Refunds > Pfand"),
        ], true),
        ("Corner Bakery", "2026-09-27", "09:10", [
            ("Dinkelbrot", "spelt bread", 1, 4.20, "Food > Bakery > Bread"),
            ("Croissant", "croissant", 3, 1.30, "Food > Bakery > Pastries"),
            ("Filterkaffee", "filter coffee", 2, 2.60, "Food > Beverages > Coffee & Tea"),
        ], true),
    ]
}
#endif
