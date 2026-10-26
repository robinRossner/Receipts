import Foundation

/// Ports categorize_item.py: normalize a raw item name, try an exact/fuzzy match against
/// what's already in item_dictionary, and fall back to an LLM classification call.
enum ItemCategorizer {
    static let model = "qwen2.5:7b-instruct"
    static let fuzzyMatchThreshold = 90

    // ---- Normalization, ported from normalize_name() ----

    private static let packSizePattern = #"\b\d+[.,]?\d*\s?(g|kg|ml|l|cl|stk|stück|x\d*)\b"#
    private static let nonWordPattern = #"[^a-zäöüß0-9\s]"#

    static func normalizeName(_ raw: String) -> String {
        var s = raw.lowercased()
        s = replace(s, pattern: packSizePattern, with: " ")
        s = replace(s, pattern: nonWordPattern, with: " ")
        s = replace(s, pattern: #"\s+"#, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ s: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: replacement)
    }

    // ---- Store context + abbreviation glossary, copied verbatim from categorize_item.py ----

    private static let storeTypeHints: [(match: String, hint: String)] = [
        ("dm", "a German drugstore (mostly personal care, household, and health items)"),
        ("rossmann", "a German drugstore (mostly personal care, household, and health items)"),
        ("edeka", "a German supermarket (mostly food and beverages)"),
        ("rewe", "a German supermarket (mostly food and beverages)"),
        ("aldi", "a German discount supermarket (mostly food and beverages)"),
        ("lidl", "a German discount supermarket (mostly food and beverages)"),
        ("kaufland", "a German supermarket (mostly food and beverages)"),
    ]

    static func storeContext(_ storeName: String?) -> String {
        guard let storeName, !storeName.isEmpty else {
            return "The store this was purchased from is unknown."
        }
        let lower = storeName.lowercased()
        if let hint = storeTypeHints.first(where: { lower.contains($0.match) })?.hint {
            return "This item was purchased at \(storeName), \(hint)."
        }
        return "This item was purchased at \(storeName)."
    }

    private static let abbreviationGlossary = """
    Common German receipt abbreviations - expand these mentally before translating:
    - Deo = Deodorant
    - ToiPa = Toilettenpapier (toilet paper)
    - Feu. = Feuchtigkeit(s)- (moisture/moisturizing) - NOT "Feuer" (fire)
    - SH = Shampoo
    - Duo = pack of 2
    - LSF = Lichtschutzfaktor (SPF / sun protection factor)
    - St. = Stück (piece) or Stift (stick)
    - Rd = Rinder- (beef)
    - Alkf. = alkoholfrei (non-alcoholic)
    - Einw. = Einweg (single-use/disposable)
    - Bio = organic
    - Zungenreiniger = tongue cleaner
    - G&G / Gut&Günstig, Ja!, K-Classic, Rewe Beste Wahl = supermarket house brands, not the product type
    """

    private static let classifyPromptTemplate = """
    You are classifying a German supermarket/drugstore item into a fixed category tree, and translating its name to natural English.

    %%STORE_CONTEXT%%

    %%GLOSSARY%%

    Item (German): "%%ITEM_NAME%%"

    First, mentally expand any abbreviations or brand names in the item name using the glossary above. Then translate what the product actually IS in natural English - not a literal word-for-word translation of the abbreviation.

    Below is a numbered list of the ONLY valid categories. Pick the single number that best matches - never invent a new category and never describe the item in that field, just give its number.

    %%TAXONOMY_LIST%%

    Rules:
    - Classify by how it is sold and shopped, not strict biology (e.g. tomatoes, cucumbers, zucchini go under Vegetables even though botanically fruits).
    - Brand names and product-line marketing terms (e.g. "PRO+") don't affect the category - look at what the product actually is, not what it's called.
    - If genuinely unsure, use the number for "Other > Miscellaneous > General".

    Respond with ONLY this JSON, no explanation, no markdown fences:
    {
      "translation_en": "<natural English translation of what the product actually is>",
      "path_number": <the single number from the list above, as an integer>
    }
    """

    // ---- LLM classification, ported from call_llm() / classify_with_llm() ----

    private static func callLLM(itemName: String, taxonomyList: String, ctx: String, correction: String = "", temperature: Double = 0.1) async throws -> (translationEn: String?, pathNumber: Int?) {
        var prompt = classifyPromptTemplate
            .replacingOccurrences(of: "%%ITEM_NAME%%", with: itemName)
            .replacingOccurrences(of: "%%TAXONOMY_LIST%%", with: taxonomyList)
            .replacingOccurrences(of: "%%STORE_CONTEXT%%", with: ctx)
            .replacingOccurrences(of: "%%GLOSSARY%%", with: abbreviationGlossary)
        if !correction.isEmpty {
            prompt += "\n\n\(correction)"
        }
        let raw = try await OllamaClient.chat(model: model, prompt: prompt, temperature: temperature, numPredict: 200)
        guard let obj = JSONUtil.extractObject(raw) else { return (nil, nil) }
        return (JSONCoerce.string(obj["translation_en"]), JSONCoerce.int(obj["path_number"]))
    }

    struct Classification {
        var translationEn: String
        var category: String
        var subcategory: String
        var itemGroup: String
        var needsReview: Bool
    }

    static func classifyWithLLM(itemName: String, taxonomy: Taxonomy, storeName: String?, logURL: URL) async throws -> Classification {
        let (taxonomyList, indexMap) = taxonomy.numberedPrompt()
        let ctx = storeContext(storeName)

        var (translation, pathNumber) = try await callLLM(itemName: itemName, taxonomyList: taxonomyList, ctx: ctx)
        var path = pathNumber.flatMap { indexMap[$0] }
        logClassification(itemName: itemName, store: storeName, attempt: 1, translation: translation, pathNumber: pathNumber, valid: path != nil, logURL: logURL)

        if path == nil {
            let correction = "Your previous answer, \"\(pathNumber.map(String.init) ?? "null")\", is not a valid number from the list above. Look again and respond with just one of the listed numbers."
            (translation, pathNumber) = try await callLLM(itemName: itemName, taxonomyList: taxonomyList, ctx: ctx, correction: correction)
            path = pathNumber.flatMap { indexMap[$0] }
            logClassification(itemName: itemName, store: storeName, attempt: 2, translation: translation, pathNumber: pathNumber, valid: path != nil, logURL: logURL)
        }

        if let path {
            return Classification(translationEn: translation ?? itemName, category: path.category, subcategory: path.subcategory, itemGroup: path.itemGroup, needsReview: false)
        }
        return Classification(translationEn: translation ?? itemName, category: "Other", subcategory: "Miscellaneous", itemGroup: "General", needsReview: true)
    }

    private static func logClassification(itemName: String, store: String?, attempt: Int, translation: String?, pathNumber: Int?, valid: Bool, logURL: URL) {
        var result: [String: Any] = [:]
        if let translation { result["translation_en"] = translation }
        if let pathNumber { result["path_number"] = pathNumber }
        var entry: [String: Any] = [
            "timestamp": isoNow(),
            "item_name": itemName,
            "attempt": attempt,
            "result": result,
            "valid": valid,
        ]
        entry["store"] = store ?? NSNull()

        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        }
    }

    // ---- Dictionary lookup, ported from get_or_create_item() ----

    private static func rowToEntry(_ row: SQLRow) -> ItemDictionaryEntry {
        let aliasesJSON = row.string(7) ?? "[]"
        let aliases = (try? JSONSerialization.jsonObject(with: Data(aliasesJSON.utf8))) as? [String] ?? []
        return ItemDictionaryEntry(
            id: row.int(0) ?? 0,
            canonicalName: row.string(1) ?? "",
            displayNameDe: row.string(2),
            translationEn: row.string(3),
            category: row.string(4) ?? "",
            subcategory: row.string(5) ?? "",
            itemGroup: row.string(6) ?? "",
            aliases: aliases,
            isManualOverride: row.bool(8),
            needsReview: row.bool(9),
            timesSeen: row.int(10) ?? 0,
            createdAt: row.string(11) ?? "",
            lastSeenAt: row.string(12) ?? ""
        )
    }

    private static func touchEntry(db: Database, rowId: Int, alias: String?) async throws {
        if let alias {
            if let row = try await db.queryOne("SELECT aliases FROM item_dictionary WHERE id = ?", [.from(rowId)]) {
                var aliases = (try? JSONSerialization.jsonObject(with: Data((row.string(0) ?? "[]").utf8))) as? [String] ?? []
                if !aliases.contains(alias) {
                    aliases.append(alias)
                    if let data = try? JSONSerialization.data(withJSONObject: aliases), let json = String(data: data, encoding: .utf8) {
                        try await db.run("UPDATE item_dictionary SET aliases = ? WHERE id = ?", [.text(json), .from(rowId)])
                    }
                }
            }
        }
        try await db.run(
            "UPDATE item_dictionary SET times_seen = times_seen + 1, last_seen_at = ? WHERE id = ?",
            [.text(isoNow()), .from(rowId)]
        )
    }

    /// normalize -> exact cache match -> fuzzy cache match -> LLM classify -> cache it.
    static func getOrCreateItem(db: Database, rawName: String, taxonomy: Taxonomy, storeName: String?, logURL: URL) async throws -> ItemDictionaryEntry {
        let normalized = normalizeName(rawName)
        let rows = try await db.query("SELECT * FROM item_dictionary")
        let entries = rows.map(rowToEntry)

        if let exact = entries.first(where: { $0.canonicalName == normalized || $0.aliases.contains(normalized) }) {
            try await touchEntry(db: db, rowId: exact.id, alias: nil)
            return exact
        }

        if !entries.isEmpty {
            if let best = FuzzyMatch.bestMatch(normalized, among: entries.map(\.canonicalName)),
               best.score >= fuzzyMatchThreshold,
               let matched = entries.first(where: { $0.canonicalName == best.match }) {
                try await touchEntry(db: db, rowId: matched.id, alias: normalized)
                return matched
            }
        }

        let classification = try await classifyWithLLM(itemName: rawName, taxonomy: taxonomy, storeName: storeName, logURL: logURL)
        let now = isoNow()
        let aliasesJSON = (try? JSONSerialization.data(withJSONObject: [normalized]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let newId = try await db.run(
            """
            INSERT INTO item_dictionary
            (canonical_name, display_name_de, translation_en, category, subcategory, item_group, aliases, needs_review, created_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(normalized), .text(rawName), .text(classification.translationEn), .text(classification.category),
             .text(classification.subcategory), .text(classification.itemGroup), .text(aliasesJSON),
             .from(classification.needsReview), .text(now), .text(now)]
        )
        guard let row = try await db.queryOne("SELECT * FROM item_dictionary WHERE id = ?", [.integer(newId)]) else {
            throw DatabaseError.stepFailed("could not read back inserted item_dictionary row", "")
        }
        return rowToEntry(row)
    }
}
