import Foundation

/// Mirrors category_taxonomy.json. Order matters here (it's shown to the LLM as a numbered
/// list, and used for the UI pickers), so this decodes manually via `allKeys` instead of into
/// a plain `[String: ...]`, which would lose the original JSON key order.
struct Taxonomy: Decodable, Sendable {
    struct Subcategory: Sendable {
        let name: String
        let itemGroups: [String]
    }
    struct Category: Sendable {
        let name: String
        let subcategories: [Subcategory]
    }

    /// A taxonomy path (level 1 > 2 > 3).
    struct Path: Hashable, Sendable {
        let category: String
        let subcategory: String
        let itemGroup: String
        var label: String { "\(category) > \(subcategory) > \(itemGroup)" }

        init(_ category: String, _ subcategory: String, _ itemGroup: String) {
            self.category = category; self.subcategory = subcategory; self.itemGroup = itemGroup
        }
        /// Parses "Food > Pantry > Legumes"; nil unless it has exactly three parts.
        init?(label: String) {
            let parts = label.components(separatedBy: " > ")
            guard parts.count == 3 else { return nil }
            self.init(parts[0], parts[1], parts[2])
        }
    }

    /// One `keyword_rules` entry: a case-insensitive regex over the normalized item name
    /// (skipped when `exclude` also matches) that assigns `path` without an LLM call.
    struct KeywordRule: @unchecked Sendable {
        let pattern: String
        let exclude: String?
        let path: Path
        let regex: NSRegularExpression?
        let excludeRegex: NSRegularExpression?

        init(pattern: String, exclude: String?, path: Path) {
            self.pattern = pattern; self.exclude = exclude; self.path = path
            regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            excludeRegex = exclude.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        }

        func matches(_ normalizedName: String) -> Bool {
            let range = NSRange(normalizedName.startIndex..., in: normalizedName)
            guard let regex, regex.firstMatch(in: normalizedName, options: [], range: range) != nil else { return false }
            if let excludeRegex, excludeRegex.firstMatch(in: normalizedName, options: [], range: range) != nil { return false }
            return true
        }
    }

    private struct RawKeywordRule: Decodable {
        let pattern: String
        let exclude: String?
        let path: String
    }

    let categories: [Category]
    let notes: [String: String]
    /// Evaluated in order; the first match wins.
    let keywordRules: [KeywordRule]
    /// Rules whose `path` string wasn't "A > B > C" (reported by `validate()`).
    private let malformedRulePaths: [String]

    private enum RootKeys: String, CodingKey { case categories, notes, keywordRules = "keyword_rules" }
    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let categoriesContainer = try root.nestedContainer(keyedBy: DynamicKey.self, forKey: .categories)

        var cats: [Category] = []
        for catKey in categoriesContainer.allKeys {
            let subContainer = try categoriesContainer.nestedContainer(keyedBy: DynamicKey.self, forKey: catKey)
            var subs: [Subcategory] = []
            for subKey in subContainer.allKeys {
                let groups = try subContainer.decode([String].self, forKey: subKey)
                subs.append(Subcategory(name: subKey.stringValue, itemGroups: groups.isEmpty ? ["General"] : groups))
            }
            cats.append(Category(name: catKey.stringValue, subcategories: subs))
        }
        categories = cats
        notes = try root.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]

        let raw = try root.decodeIfPresent([RawKeywordRule].self, forKey: .keywordRules) ?? []
        var rules: [KeywordRule] = []
        var bad: [String] = []
        for r in raw {
            if let path = Path(label: r.path) {
                rules.append(KeywordRule(pattern: r.pattern, exclude: r.exclude, path: path))
            } else {
                bad.append(r.path)
            }
        }
        keywordRules = rules
        malformedRulePaths = bad
    }

    // ---- Keyword routing + validation ----

    /// First keyword rule matching the already-normalized item name, if any.
    func keywordPath(forNormalizedName name: String) -> Path? {
        keywordRules.first(where: { $0.matches(name) })?.path
    }

    func contains(_ path: Path) -> Bool {
        categories.first(where: { $0.name == path.category })?
            .subcategories.first(where: { $0.name == path.subcategory })?
            .itemGroups.contains(path.itemGroup) ?? false
    }

    /// Paths renamed or merged by data migration v5 (old -> new). Wine & Spirits is split and
    /// handled separately in the migration.
    static let migrationV5Renames: [(from: Path, to: Path)] = [
        (Path("Food", "Vegetables", "Cucumbers & Squash"), Path("Food", "Vegetables", "Cucumbers, Squash & Eggplant")),
        (Path("Food", "Pantry", "Baking"), Path("Food", "Pantry", "Baking & Sugar")),
        (Path("Food", "Dairy & Eggs", "Yogurt"), Path("Food", "Dairy & Eggs", "Yogurt, Skyr & Quark")),
        (Path("Food", "Snacks & Sweets", "Nuts & Dried Fruit"), Path("Food", "Snacks & Sweets", "Nuts, Seeds & Dried Fruit")),
        (Path("Food", "Frozen & Ready Meals", "Frozen Vegetables"), Path("Food", "Frozen & Ready Meals", "Frozen Fruit & Vegetables")),
    ]
    static let oldWineAndSpirits = Path("Food", "Beverages", "Wine & Spirits")
    static let wine = Path("Food", "Beverages", "Wine")
    static let spirits = Path("Food", "Beverages", "Spirits")
    static let notAProduct = Path("Other", "Not a product", "Receipt text")
    static let fallback = Path("Other", "Miscellaneous", "General")

    /// Every problem found: keyword-rule paths/regexes that don't resolve, and migration targets
    /// missing from the taxonomy. Empty means consistent. Checked (precondition) at load time.
    func validate() -> [String] {
        var problems: [String] = malformedRulePaths.map { "keyword rule path is not 'A > B > C': \($0)" }
        for rule in keywordRules {
            if rule.regex == nil { problems.append("keyword rule regex does not compile: \(rule.pattern)") }
            if rule.exclude != nil, rule.excludeRegex == nil { problems.append("keyword rule exclude does not compile: \(rule.exclude ?? "")") }
            if !contains(rule.path) { problems.append("keyword rule points at a missing path: \(rule.path.label) (\(rule.pattern))") }
        }
        var referenced = Taxonomy.migrationV5Renames.map(\.to)
        referenced += [Taxonomy.wine, Taxonomy.spirits, Taxonomy.notAProduct, Taxonomy.fallback]
        for path in referenced where !contains(path) { problems.append("migration/fallback target missing: \(path.label)") }
        for old in Taxonomy.migrationV5Renames.map(\.from) + [Taxonomy.oldWineAndSpirits] where contains(old) {
            problems.append("renamed path still exists in taxonomy: \(old.label)")
        }
        return problems
    }

    static func load() -> Taxonomy {
        // `Bundle.module` only exists when built via Swift Package Manager (it's a generated
        // accessor for the package's resource bundle). The Xcode app target has no such thing -
        // there, the JSON is just copied straight into the app bundle's Resources, found via
        // `Bundle.main`. `SWIFT_PACKAGE` is a compiler-defined flag set only in the SPM build.
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle.main
        #endif
        guard let url = resourceBundle.url(forResource: "category_taxonomy", withExtension: "json", subdirectory: "Resources")
                ?? resourceBundle.url(forResource: "category_taxonomy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let taxonomy = try? JSONDecoder().decode(Taxonomy.self, from: data) else {
            fatalError("Could not load category_taxonomy.json from bundle resources")
        }
        let problems = taxonomy.validate()
        precondition(problems.isEmpty, "category_taxonomy.json is inconsistent:\n" + problems.joined(separator: "\n"))
        return taxonomy
    }

    // ---- Convenience lookups, mirroring categorize_item.py / dashboard.html ----

    func categoryNames() -> [String] { categories.map(\.name) }

    func subcategoryNames(in category: String) -> [String] {
        categories.first(where: { $0.name == category })?.subcategories.map(\.name) ?? []
    }

    func itemGroups(category: String, subcategory: String) -> [String] {
        let groups = categories.first(where: { $0.name == category })?
            .subcategories.first(where: { $0.name == subcategory })?.itemGroups
        return (groups?.isEmpty ?? true) ? ["General"] : groups!
    }

    /// Mirrors flatten_taxonomy: a flat list of (category, subcategory, item_group, note).
    func flattened() -> [(category: String, subcategory: String, itemGroup: String, note: String?)] {
        var entries: [(String, String, String, String?)] = []
        for category in categories {
            for sub in category.subcategories {
                for group in sub.itemGroups {
                    let path = "\(category.name) > \(sub.name) > \(group)"
                    entries.append((category.name, sub.name, group, notes[path]))
                }
            }
        }
        return entries
    }

    /// Mirrors build_numbered_taxonomy: numbered prompt text + a lookup from number to path.
    func numberedPrompt() -> (text: String, indexMap: [Int: (category: String, subcategory: String, itemGroup: String)]) {
        let entries = flattened()
        var lines: [String] = []
        var indexMap: [Int: (String, String, String)] = [:]
        for (i, entry) in entries.enumerated() {
            let number = i + 1
            var line = "\(number). \(entry.category) > \(entry.subcategory) > \(entry.itemGroup)"
            if let note = entry.note {
                line += "  (note: \(note))"
            }
            lines.append(line)
            indexMap[number] = (entry.category, entry.subcategory, entry.itemGroup)
        }
        return (lines.joined(separator: "\n"), indexMap)
    }
}
