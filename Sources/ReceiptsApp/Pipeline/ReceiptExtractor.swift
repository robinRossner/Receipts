import CoreImage
import Foundation

enum ExtractionError: Error, LocalizedError {
    case invalidJSON(String)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): return "LLM did not return valid JSON: \(detail)"
        case .imageEncodingFailed: return "Could not encode image to JPEG"
        }
    }
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

/// Ports scan_and_parse_receipt.py: send the straightened receipt image to the vision LLM,
/// parse its JSON, and run the same validation checks (Pfand normalization, sum mismatch,
/// per-line math, quantities). The model call itself goes through a ReceiptExtractionProvider.
enum ReceiptExtractor {
    static let sumMismatchTolerance = 0.02
    static let knownPfandValues: [Double] = [0.08, 0.15, 0.25, 1.50]
    static let pfandAutocorrectThreshold = 0.10

    // The evaluated extraction prompt (prompt variant a2_minimal). Keep it identical to EXTRACTION_PROMPT in
    // backend/receipts/extraction/prompts.py (a backend test compares the two). It relies on `outputSchema` for the JSON shape.
    static let promptTemplate = #"""
    The photo shows a German supermarket or drugstore receipt. Extract the purchase into the JSON schema.

    Items: one entry per amount in the right-hand column, in printed order, from the first item down to the line above SUMME. A repeated product stays as separate entries. Text rows with no amount of their own (a supplier note such as "Z9 Beispiel GmbH", a weight row) belong to the item they describe and take no amount. Photos are often tilted, so match amounts to items by their order in the column, not by which name looks level with them. Read every amount from the photo, even when lines repeat in a pattern.
    - raw_text: the printed text, uncorrected. name: the German name with OCR typos fixed.
    - total_price: the printed amount. unit_price: the price of one unit.
    - quantity: 1 unless a multiplier or weight is printed ("3 x 1,50", "0,500 kg x 3,00 €/kg", giving quantity 3 or 0.5). Pack sizes in a name ("6x250") are not quantities.
    - Leergut, Rabatt and other refunds: quantity 1 with negative prices. Pfand is its own item and positive unless printed with a minus.
    - Numbers of 5-8 digits before a name are product codes, not prices.

    Other fields: store as printed. date as YYYY-MM-DD, time as HH:MM or null if unclear; a TSE timestamp is more legible than the header for the date, but one ending in Z is UTC, so take the time from the printed local clock (its minutes can settle an unclear minute there). total: the amount next to SUMME, positive, never a payment line. printed_item_count: the number at "Posten" or "Artikel", else null.

    Report what is printed. If a digit is hard to read, give your best reading of that digit alone; never choose a digit because it makes the amounts add up. A sum that does not match SUMME is fine: the app sends that receipt to a person for review.
    """#

    static let maxOutputTokens = 2048

    /// The structure promptTemplate asks for, as a schema for providers with structured output. Nullable where the prompt
    /// allows null/unclear values; parsing stays lenient anyway. No descriptions: the evaluated version had none.
    static let outputSchema: JSONSchema = {
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "raw_text": ["type": "string"],
                "name": ["type": "string"],
                "quantity": ["type": "number"],
                "unit_price": ["type": "number"],
                "total_price": ["type": "number"],
            ] as [String: Any],
            "required": ["raw_text", "name", "quantity", "unit_price", "total_price"],
            "additionalProperties": false,
        ]
        let root: [String: Any] = [
            "type": "object",
            "properties": [
                "store": ["type": ["string", "null"]],
                "date": ["type": ["string", "null"]],
                "time": ["type": ["string", "null"]],
                "items": ["type": "array", "items": item] as [String: Any],
                "total": ["type": ["number", "null"]],
                "printed_item_count": ["type": ["integer", "null"]],
            ] as [String: Any],
            "required": ["store", "date", "time", "items", "total", "printed_item_count"],
            "additionalProperties": false,
        ]
        return JSONSchema(name: "receipt_extraction", root: root, keyOrder: JSONSchema.evaluatedKeyOrder)
    }()

    static func callVisionModel(jpeg: Data, provider: any ReceiptExtractionProvider) async throws -> LLMResponse {
        try await provider.extractReceipt(jpeg: jpeg, prompt: promptTemplate, schema: outputSchema, maxOutputTokens: maxOutputTokens)
    }

    static func parseJSONResponse(_ raw: String) throws -> ExtractedReceipt {
        guard let obj = JSONUtil.extractObject(raw) else {
            throw ExtractionError.invalidJSON("no JSON object found")
        }
        return ExtractedReceipt(dict: obj)
    }

    /// Calls the vision model, retrying once on invalid JSON - same policy as
    /// process_receipt() in receipt_pipeline.py.
    static func extractAndValidate(image: CIImage, provider: any ReceiptExtractionProvider) async throws -> ExtractedReceipt {
        guard let jpeg = DocumentScanner.modelJPEG(from: image) else {
            throw ExtractionError.imageEncodingFailed
        }
        let first = try await callVisionModel(jpeg: jpeg, provider: provider)
        if var parsed = try? parseJSONResponse(first.text) {
            parsed.providerId = first.providerId
            return validateReceipt(parsed)
        }
        let second = try await callVisionModel(jpeg: jpeg, provider: provider)
        guard var parsed = try? parseJSONResponse(second.text) else {
            throw ExtractionError.invalidJSON("LLM did not return valid JSON after retry")
        }
        parsed.providerId = second.providerId
        return validateReceipt(parsed)
    }

    // ---- Validation, ported from scan_and_parse_receipt.py ----

    static func validateReceipt(_ raw: ExtractedReceipt) -> ExtractedReceipt {
        var receipt = raw
        // Rule 13 enforcement: drop anything the model emitted without a clear price.
        receipt.items = receipt.items.filter { $0.unitPrice != nil && $0.totalPrice != nil }

        var issues: [String] = []
        normalizePfandPrices(&receipt, issues: &issues)
        validateTotals(&receipt, issues: &issues)
        validateLineMath(receipt, issues: &issues)
        validateQuantities(receipt, issues: &issues)
        validateSigns(receipt, issues: &issues)

        receipt.needsReview = !issues.isEmpty
        receipt.reviewReasons = issues
        return receipt
    }

    private static func normalizePfandPrices(_ receipt: inout ExtractedReceipt, issues: inout [String]) {
        for i in receipt.items.indices {
            let name = (receipt.items[i].name ?? "").lowercased()
            guard name.contains("pfand"), let unitPrice = receipt.items[i].unitPrice else { continue }

            let sign: Double = unitPrice < 0 ? -1 : 1
            let magnitude = abs(unitPrice)
            let closest = knownPfandValues.min(by: { abs($0 - magnitude) < abs($1 - magnitude) }) ?? magnitude
            let deviation = abs(magnitude - closest)

            if deviation == 0 {
                receipt.items[i].priceNormalized = false
            } else if deviation <= pfandAutocorrectThreshold {
                let oldPrice = unitPrice
                let qty = receipt.items[i].quantity ?? 1.0
                let newUnit = round2(sign * closest)
                receipt.items[i].unitPrice = newUnit
                receipt.items[i].totalPrice = round2(sign * closest * qty)
                receipt.items[i].priceNormalized = true
                issues.append("Pfand item '\(receipt.items[i].name ?? "")' had unit_price \(oldPrice) - corrected to \(newUnit).")
            } else {
                receipt.items[i].priceNormalized = false
                issues.append("Pfand item '\(receipt.items[i].name ?? "")' has unit_price \(unitPrice), which isn't close to any standard German deposit amount - check manually.")
            }
        }
    }

    private static func validateTotals(_ receipt: inout ExtractedReceipt, issues: inout [String]) {
        for (i, item) in receipt.items.enumerated() where item.totalPrice == nil {
            issues.append("Item #\(i) (\(item.name ?? "nil")) has no total_price - treated as 0")
        }
        let itemSum = round2(receipt.items.reduce(0.0) { $0 + ($1.totalPrice ?? 0.0) })
        receipt.computedSum = itemSum

        guard let printedTotal = receipt.total else {
            issues.append("No total found on receipt")
            return
        }
        if printedTotal < 0 {
            issues.append("Printed total is negative (\(printedTotal)) - likely picked up payment line")
        }
        let diff = round2(abs(itemSum - printedTotal))
        if diff > sumMismatchTolerance {
            issues.append("Item prices sum to \(itemSum), but printed total is \(printedTotal) (difference: \(diff)). Check raw_text per item.")
        }
    }

    private static func validateLineMath(_ receipt: ExtractedReceipt, issues: inout [String]) {
        for (i, item) in receipt.items.enumerated() {
            let qty = item.quantity ?? 1.0
            let unit = item.unitPrice ?? 0.0
            let total = item.totalPrice ?? 0.0
            let expected = round2(qty * unit)
            if round2(abs(expected - total)) > sumMismatchTolerance {
                issues.append("Item #\(i) (\(item.name ?? "nil")): \(qty) x \(unit) = \(expected), but total_price is \(total)")
            }
        }
    }

    private static func validateQuantities(_ receipt: ExtractedReceipt, issues: inout [String]) {
        for (i, item) in receipt.items.enumerated() {
            let qty = item.quantity ?? 1.0
            if qty <= 0 {
                issues.append("Item #\(i) (\(item.name ?? "nil")) has quantity \(qty) - should be positive")
            }
        }
    }

    // ---- Sign plausibility (shifted price column) ----
    // Names are folded to ASCII words (lower case, umlauts and accents dropped, ss for the sharp s) and
    // matched word by word, never as substrings of the whole name. Mirrors validate.py in the backend;
    // both run the table in backend/tests/test_receipts_sign_checks.py.

    private static let depositReturnPrefixes = [
        "leergut", "pfandbon", "pfandruck", "pfandrueck", "pfanderstatt", "pfandgutschrift",
        "pfandzuruck", "pfandzurueck", "pfandeinlos", "ruckpfand", "rueckpfand",
    ]
    private static let depositReturnWords: Set<String> = [
        "zuruck", "zurueck", "ruckgabe", "rueckgabe", "ruckerstattung", "rueckerstattung",
        "erstattung", "ruckzahlung", "rueckzahlung", "gutschrift", "bon", "einlosung", "einloesung",
    ]
    /// Legitimately negative lines: a word starting or ending with one of these.
    private static let negativeOKStems = [
        "rabatt", "coupon", "gutschein", "gutschrift", "nachlass", "storno", "bonus",
        "payback", "ersparnis", "korrektur", "retoure", "umtausch", "erstattung", "abzug",
        "skonto", "ruckgabe", "rueckgabe", "abschlag", "preissenkung", "cashback",
    ]
    /// Only at the start of a word ("Aktionsware" yes, "Reaktion" no).
    private static let negativeOKPrefixes = ["aktion", "storn", "reduzier", "punkte", "treue"]
    /// Only at the end of a word ("Preisvorteil" yes, "Vorteilspack" no).
    private static let negativeOKSuffixes = ["vorteil"]
    /// Whole words only (abbreviations printed on receipts).
    private static let negativeOKWords: Set<String> = ["rab", "rabt", "gutsch", "gutschr", "korr"]

    static func nameWords(_ name: String?) -> [String] {
        let decomposed = (name ?? "").lowercased().decomposedStringWithCanonicalMapping
        var folded = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
            folded.append(scalar)
        }
        let ascii = String(folded).replacingOccurrences(of: "ß", with: "ss")
        var words: [String] = []
        var current = ""
        for scalar in ascii.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func isPfandWord(_ w: String) -> Bool { w.hasPrefix("pfand") || w.hasSuffix("pfand") }

    static func isDepositReturnName(_ name: String?) -> Bool {
        let words = nameWords(name)
        if words.contains(where: { w in depositReturnPrefixes.contains { w.hasPrefix($0) } }) { return true }
        return words.contains(where: isPfandWord) && words.contains(where: { depositReturnWords.contains($0) })
    }

    private static func isDepositName(_ name: String?) -> Bool {
        isDepositReturnName(name) || nameWords(name).contains { isPfandWord($0) || $0.hasPrefix("leergut") }
    }

    static func isLegitNegativeName(_ name: String?) -> Bool {
        if isDepositName(name) { return true }
        for w in nameWords(name) {
            if negativeOKWords.contains(w) || negativeOKPrefixes.contains(where: { w.hasPrefix($0) }) { return true }
            if negativeOKSuffixes.contains(where: { w.hasSuffix($0) }) { return true }
            if negativeOKStems.contains(where: { w.hasPrefix($0) || w.hasSuffix($0) }) { return true }
        }
        return false
    }

    /// A shifted price column keeps the sum right, so check each line's sign against its name.
    private static func validateSigns(_ receipt: ExtractedReceipt, issues: inout [String]) {
        for (i, item) in receipt.items.enumerated() {
            let total = item.totalPrice ?? 0.0
            let label = item.name ?? item.rawText
            if total > 0 && isDepositReturnName(label) {
                issues.append("Item #\(i) (\(item.name ?? "nil")): deposit return has a positive amount \(total) - check whether the price column shifted by a line.")
            } else if total < 0 && !isLegitNegativeName(label) {
                issues.append("Item #\(i) (\(item.name ?? "nil")): product has a negative amount \(total) - check whether the price column shifted by a line.")
            }
        }
    }
}
