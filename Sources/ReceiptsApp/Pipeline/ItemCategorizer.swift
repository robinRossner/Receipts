import Foundation

/// Ports categorize_item.py: normalize a raw item name, try an exact/fuzzy match against
/// what's already in item_dictionary, and fall back to one batched LLM classification call
/// (through an ItemClassificationProvider) for everything still unknown on the receipt.
enum ItemCategorizer {
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
            return "The store these items were purchased from is unknown."
        }
        let lower = storeName.lowercased()
        if let hint = storeTypeHints.first(where: { lower.contains($0.match) })?.hint {
            return "These items were purchased at \(storeName), \(hint)."
        }
        return "These items were purchased at \(storeName)."
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
    You are classifying German supermarket/drugstore items into a fixed category tree, and translating each item's name to natural English.

    %%STORE_CONTEXT%%

    %%GLOSSARY%%

    Items (German), each with its index in square brackets:
    %%ITEM_LIST%%

    For each item, first mentally expand any abbreviations or brand names in its name using the glossary above. Then translate what the product actually IS in natural English - not a literal word-for-word translation of the abbreviation.

    Below is a numbered list of the ONLY valid categories. For each item pick the single number that best matches - never invent a new category and never describe the item in that field, just give its number.

    %%TAXONOMY_LIST%%

    Rules:
    - Classify by how it is sold and shopped, not strict biology (e.g. tomatoes, cucumbers, zucchini go under Vegetables even though botanically fruits).
    - Brand names and product-line marketing terms (e.g. "PRO+") don't affect the category - look at what the product actually is, not what it's called.
    - Classify each item on its own; being on the same receipt says nothing about its category.
    - If genuinely unsure, use the number for "Other > Miscellaneous > General".

    Respond with ONLY this JSON, no explanation, no markdown fences - exactly one entry per item, using the item's index from the square brackets:
    {
      "items": [
        {
          "index": <the item's index>,
          "translation_en": "<natural English translation of what the product actually is>",
          "path_number": <the single number from the category list above, as an integer>
        }
      ]
    }
    """

    /// Items per LLM call. A typical receipt fits in one call; this only splits very long ones
    /// so the prompt + answer stay well inside the model's context window.
    static let maxItemsPerCall = 30

    /// Schema for the batched answer: `index` and `path_number` are limited to valid values, so
    /// providers with constrained output can't return an out-of-range number at all.
    static func classificationSchema(itemCount: Int, pathNumbers: [Int]) -> JSONSchema {
        let entry: [String: Any] = [
            "type": "object",
            "properties": [
                "index": ["type": "integer", "enum": Array(1...max(itemCount, 1)), "description": "The item's index from the item list"],
                "translation_en": ["type": "string", "description": "Natural English translation of what the product actually is"],
                "path_number": ["type": "integer", "enum": pathNumbers, "description": "Number of the chosen category from the category list"],
            ] as [String: Any],
            "required": ["index", "translation_en", "path_number"],
            "additionalProperties": false,
        ]
        let root: [String: Any] = [
            "type": "object",
            "properties": ["items": ["type": "array", "items": entry] as [String: Any]],
            "required": ["items"],
            "additionalProperties": false,
        ]
        return JSONSchema(name: "item_classification", root: root)
    }

    // ---- LLM classification, ported from call_llm() / classify_with_llm(), batched per receipt ----

    private typealias Answer = (translationEn: String?, pathNumber: Int?)

    /// One call for `itemNames` (indexed 1...n in the prompt). Returns answers keyed by that index;
    /// items the model skipped are simply absent.
    private static func callLLM(
        itemNames: [String], taxonomyList: String, pathNumbers: [Int], ctx: String, correction: String,
        provider: any ItemClassificationProvider
    ) async throws -> (answers: [Int: Answer], providerId: String) {
        let itemList = itemNames.enumerated()
            .map { "[\($0.offset + 1)] \"\($0.element)\"" }
            .joined(separator: "\n")
        var prompt = classifyPromptTemplate
            .replacingOccurrences(of: "%%ITEM_LIST%%", with: itemList)
            .replacingOccurrences(of: "%%TAXONOMY_LIST%%", with: taxonomyList)
            .replacingOccurrences(of: "%%STORE_CONTEXT%%", with: ctx)
            .replacingOccurrences(of: "%%GLOSSARY%%", with: abbreviationGlossary)
        if !correction.isEmpty {
            prompt += "\n\n\(correction)"
        }
        let response = try await provider.classify(
            prompt: prompt,
            schema: classificationSchema(itemCount: itemNames.count, pathNumbers: pathNumbers),
            maxOutputTokens: 100 + 80 * itemNames.count
        )
        guard let obj = JSONUtil.extractObject(response.text) else { return ([:], response.providerId) }

        var answers: [Int: Answer] = [:]
        if let entries = obj["items"] as? [[String: Any]] {
            for entry in entries {
                guard let index = JSONCoerce.int(entry["index"]), (1...itemNames.count).contains(index), answers[index] == nil else { continue }
                answers[index] = (JSONCoerce.string(entry["translation_en"]), JSONCoerce.int(entry["path_number"]))
            }
        } else if itemNames.count == 1, obj["path_number"] != nil {
            // Single item answered in the old flat shape - accept it.
            answers[1] = (JSONCoerce.string(obj["translation_en"]), JSONCoerce.int(obj["path_number"]))
        }
        return (answers, response.providerId)
    }

    struct Classification {
        var translationEn: String
        var category: String
        var subcategory: String
        var itemGroup: String
        var needsReview: Bool
    }

    /// Classifies all `itemNames` with one LLM call per chunk; items whose answer is missing or
    /// not a valid taxonomy number get one batched retry, then fall back to
    /// Other > Miscellaneous > General with needs_review. Results are in input order;
    /// `providerIds` lists who answered (several only when a FallbackProvider switched).
    static func classifyWithLLM(
        itemNames: [String], taxonomy: Taxonomy, storeName: String?, logURL: URL, provider: any ItemClassificationProvider
    ) async throws -> (results: [Classification], providerIds: [String]) {
        let (taxonomyList, indexMap) = taxonomy.numberedPrompt()
        let pathNumbers = indexMap.keys.sorted()
        let ctx = storeContext(storeName)
        var results: [Classification] = []
        var providerIds: [String] = []

        for chunkStart in stride(from: 0, to: itemNames.count, by: maxItemsPerCall) {
            let chunk = Array(itemNames[chunkStart..<min(chunkStart + maxItemsPerCall, itemNames.count)])
            var resolved: [Int: Classification] = [:]   // keyed by position in `chunk`
            var lastAnswers: [Int: Answer] = [:]
            var pending = Array(chunk.indices)

            for attempt in 1...2 where !pending.isEmpty {
                var correction = ""
                if attempt == 2 {
                    let lines = pending.enumerated().map { batchIndex, pos in
                        "[\(batchIndex + 1)] \"\(chunk[pos])\": you answered \(lastAnswers[pos]?.pathNumber.map(String.init) ?? "null")"
                    }
                    correction = "Your previous answers for these items were not valid numbers from the category list above:\n"
                        + lines.joined(separator: "\n")
                        + "\nLook again and give each item just one of the listed numbers."
                }
                let batch = pending.map { chunk[$0] }
                let (answers, providerId) = try await callLLM(
                    itemNames: batch, taxonomyList: taxonomyList, pathNumbers: pathNumbers,
                    ctx: ctx, correction: correction, provider: provider
                )
                if !providerIds.contains(providerId) { providerIds.append(providerId) }

                var stillPending: [Int] = []
                for (batchIndex, pos) in pending.enumerated() {
                    let answer = answers[batchIndex + 1]
                    lastAnswers[pos] = answer
                    let path = answer?.pathNumber.flatMap { indexMap[$0] }
                    logClassification(
                        itemName: chunk[pos], store: storeName, attempt: attempt, translation: answer?.translationEn,
                        pathNumber: answer?.pathNumber, valid: path != nil, provider: providerId, logURL: logURL
                    )
                    if let path {
                        resolved[pos] = Classification(
                            translationEn: answer?.translationEn ?? chunk[pos], category: path.category,
                            subcategory: path.subcategory, itemGroup: path.itemGroup, needsReview: false
                        )
                    } else {
                        stillPending.append(pos)
                    }
                }
                pending = stillPending
            }

            for pos in chunk.indices {
                results.append(resolved[pos] ?? Classification(
                    translationEn: lastAnswers[pos]?.translationEn ?? chunk[pos],
                    category: "Other", subcategory: "Miscellaneous", itemGroup: "General", needsReview: true
                ))
            }
        }
        return (results, providerIds)
    }

    private static func logClassification(itemName: String, store: String?, attempt: Int, translation: String?, pathNumber: Int?, valid: Bool, provider: String, logURL: URL) {
        var result: [String: Any] = [:]
        if let translation { result["translation_en"] = translation }
        if let pathNumber { result["path_number"] = pathNumber }
        var entry: [String: Any] = [
            "timestamp": isoNow(),
            "item_name": itemName,
            "attempt": attempt,
            "result": result,
            "valid": valid,
            "provider": provider,
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

    /// Single-item convenience (manual "add item"): same path as a receipt's batch.
    static func getOrCreateItem(
        db: Database, rawName: String, taxonomy: Taxonomy, storeName: String?, logURL: URL, provider: any ItemClassificationProvider
    ) async throws -> ItemDictionaryEntry {
        let resolved = try await resolveItems(db: db, rawNames: [rawName], taxonomy: taxonomy, storeName: storeName, logURL: logURL, provider: provider)
        guard let entry = resolved.entries.first else {
            throw DatabaseError.stepFailed("item resolution returned nothing", "")
        }
        return entry
    }

    /// For every raw name, in order: normalize -> exact cache match -> fuzzy cache match, against
    /// item_dictionary loaded ONCE; whatever is left is classified in one batched LLM call and
    /// cached. Names repeated within the batch (or fuzzy-close to an earlier new one) share one
    /// new entry, exactly as the old one-at-a-time loop would have matched them.
    /// `classificationProviders` is empty when everything came from the cache.
    static func resolveItems(
        db: Database, rawNames: [String], taxonomy: Taxonomy, storeName: String?, logURL: URL, provider: any ItemClassificationProvider
    ) async throws -> (entries: [ItemDictionaryEntry], classificationProviders: [String]) {
        var entries = try await db.query("SELECT * FROM item_dictionary").map(rowToEntry)

        /// A name with no dictionary entry yet; later occurrences (exact or fuzzy) attach to it.
        struct NewItem {
            let normalized: String
            let rawName: String
            var aliases: [String]
            var positions: [Int]
        }
        var resolved: [Int: ItemDictionaryEntry] = [:]
        var newItems: [NewItem] = []

        for (position, rawName) in rawNames.enumerated() {
            let normalized = normalizeName(rawName)

            if let exact = entries.first(where: { $0.canonicalName == normalized || $0.aliases.contains(normalized) }) {
                try await touchEntry(db: db, rowId: exact.id, alias: nil)
                resolved[position] = exact
                continue
            }
            if let n = newItems.firstIndex(where: { $0.normalized == normalized || $0.aliases.contains(normalized) }) {
                newItems[n].positions.append(position)
                continue
            }

            let candidates = entries.map(\.canonicalName) + newItems.map(\.normalized)
            if !candidates.isEmpty,
               let best = FuzzyMatch.bestMatch(normalized, among: candidates),
               best.score >= fuzzyMatchThreshold {
                if let i = entries.firstIndex(where: { $0.canonicalName == best.match }) {
                    try await touchEntry(db: db, rowId: entries[i].id, alias: normalized)
                    if !entries[i].aliases.contains(normalized) { entries[i].aliases.append(normalized) }
                    resolved[position] = entries[i]
                    continue
                }
                if let n = newItems.firstIndex(where: { $0.normalized == best.match }) {
                    if !newItems[n].aliases.contains(normalized) { newItems[n].aliases.append(normalized) }
                    newItems[n].positions.append(position)
                    continue
                }
            }

            newItems.append(NewItem(normalized: normalized, rawName: rawName, aliases: [normalized], positions: [position]))
        }

        var providerIds: [String] = []
        if !newItems.isEmpty {
            let (classifications, answeredBy) = try await classifyWithLLM(
                itemNames: newItems.map(\.rawName), taxonomy: taxonomy, storeName: storeName, logURL: logURL, provider: provider
            )
            providerIds = answeredBy
            for (item, classification) in zip(newItems, classifications) {
                let now = isoNow()
                let newId = try await db.run(
                    """
                    INSERT INTO item_dictionary
                    (canonical_name, display_name_de, translation_en, category, subcategory, item_group, aliases, needs_review, created_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(item.normalized), .text(item.rawName), .text(classification.translationEn), .text(classification.category),
                     .text(classification.subcategory), .text(classification.itemGroup), .text(encodeStringArray(item.aliases)),
                     .from(classification.needsReview), .text(now), .text(now)]
                )
                // Each further occurrence on this receipt counts as a sighting, as before.
                for _ in item.positions.dropFirst() {
                    try await touchEntry(db: db, rowId: Int(newId), alias: nil)
                }
                guard let row = try await db.queryOne("SELECT * FROM item_dictionary WHERE id = ?", [.integer(newId)]) else {
                    throw DatabaseError.stepFailed("could not read back inserted item_dictionary row", "")
                }
                let entry = rowToEntry(row)
                for position in item.positions { resolved[position] = entry }
            }
        }

        let ordered = try rawNames.indices.map { position in
            guard let entry = resolved[position] else {
                throw DatabaseError.stepFailed("no dictionary entry resolved for item #\(position)", "")
            }
            return entry
        }
        return (ordered, providerIds)
    }
}
