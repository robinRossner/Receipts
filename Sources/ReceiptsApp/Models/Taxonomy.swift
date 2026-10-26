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

    let categories: [Category]
    let notes: [String: String]

    private enum RootKeys: String, CodingKey { case categories, notes }
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
