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

    // Copied verbatim from scan_and_parse_receipt.py's PROMPT_TEMPLATE so extraction quality/
    // behavior is unchanged.
    static let promptTemplate = #"""
    You are an expert OCR and data extraction AI. You are looking at a photo of a German supermarket or drugstore receipt (e.g., Aldi, Edeka, dm, Rewe, Lidl).

    Extract ONLY the shopping information into this exact JSON structure and nothing else:

    {
      "store": "<store name, e.g. 'Aldi Sud', 'Edeka', 'dm-drogerie markt'>",
      "date": "<YYYY-MM-DD>",
      "time": "<HH:MM or null if unclear>",
      "items": [
        {
          "raw_text": "<the original OCR line(s) for this item, uncorrected>",
          "name": "<your best-guess cleaned-up German item name, fixing obvious OCR typos>",
          "quantity": <number of units purchased - see rules below>,
          "unit_price": <price per single unit as a number, e.g. 1.25>,
          "total_price": <quantity x unit_price, as a number>
        }
      ],
      "total": <the printed total for the whole receipt - always positive - as a number>,
      "printed_item_count": <the article/item count printed on the receipt, e.g., from "22 Artikel" or "Posten: 9" - as an integer, or null if not visible>
    }

    CRITICAL RULES - Read carefully. These are the strict boundaries for your extraction:

    1. STRICT 1:1 LINE MAPPING (NO CONSOLIDATING). If the exact same product appears on multiple separate lines on the receipt, you MUST output a separate JSON object for EACH physical line. Do not group, merge, or sum them together just because they are the same item. We need a perfect 1:1 representation of the physical paper.

    2. QUANTITY IS 1 BY DEFAULT. Only output a quantity other than 1 if there is an EXPLICIT multiplier printed on the receipt for that specific item (e.g., a line saying "2 x 0.99", or a weight calculation like "0.804 kg x 1.99"). If a product is just listed multiple times on consecutive lines, keep its quantity as 1 and make multiple item entries.

    3. PACKAGING SIZES ARE NOT QUANTITIES. A number inside a product name (e.g., "2x70" in "Duo Sensitiv2x70") describes the package size as printed on the label (2 packs of 70ml), not how many the customer bought. Ignore these numbers for the quantity field.

    4. WEIGHT-BASED ITEMS usually print a second line below the item showing the calculation, e.g., "0,804 kg x 1,99 €/kg". This belongs to that single item's price calculation. Use it to get that item's quantity (0.804) and unit_price (1.99), and do not let it shift which price belongs to the next item.

    5. QUANTITY IS ALWAYS POSITIVE. Never make quantity negative. For refunds, discounts, or deposit returns (Leergut, Rabatt), keep the quantity positive (usually 1) and make the unit_price and total_price NEGATIVE instead.

    6. PFAND (DEPOSIT) IS POSITIVE when buying a bottle - it's money paid, same sign as any other item. It is only NEGATIVE when explicitly showing a minus sign (e.g., "-0,15" for a return). Pfand is its own separate item row - never merge it into the drink it belongs to. Standard German deposit amounts are 0.08, 0.15, 0.25, or 1.50.

    7. NEVER MERGE TWO DIFFERENT PRODUCTS. If you see two different product names, they are two separate entries, even if you can only find one price nearby. Make your best guess for each rather than combining them.

    8. THE TOTAL comes ONLY from the number next to "SUMME", "SUMME EUR", or "SUMME €". Do NOT use a payment method line (e.g., "VISA EUR", "Geg. Mastercard") even if it shows a similar or negative number. The total you report must always be positive.

    9. PRODUCT CODES ARE NEVER PRICES. Item lines are often prefixed with a 5-8 digit product code (e.g., "205137 Bio Eier"). Never read this code as a price. A price always has exactly 2 decimal places.

    10. PREFER UNAMBIGUOUS DATES. If the receipt shows a timestamp in "YYYY-MM-DD HH:MM:SS" format (often near "Start", "Ende", or "TSE"), use it. It is much more reliable than trying to read a blurry "DD.MM.YYYY" header.

    11. STOP EXTRACTING AT THE TOTAL. The item list ends exactly when you see the subtotal or total (e.g., "SUMME", "ZU ZAHLEN", "BAR", "KARTENZAHLUNG"). NEVER include payment details, change given, or footer metadata like "K-U-N-D-E-N-B-E-L-E-G", "TSE", "MwSt", or "Auf Wiedersehen" as items.

    12. BEWARE OF STUTTERING ON REPEATED ITEMS. If the receipt shows a repetitive pattern (e.g., multiple consecutive lines of the same Beer and Pfand), you must count the EXACT number of physical pairs on the paper. Do not accidentally output 5 pairs if there are only 4 on the receipt. Verify your count against the image before writing the JSON.

    13. EVERY ITEM MUST HAVE A PRICE. If a line of text on the receipt does not have a clear monetary value attached to it, it is not a purchasable product (it is likely a header, description, or footer). Do not extract it as an item.

    WORKED EXAMPLE:
    Imagine a receipt showing a Cola with an explicit multiplier line ("2 x 0,99" above "400123 Cola 6x1,5L"), followed by two SEPARATE rows of "Pfand" at 0,25 each, a "Leergut" return of -0,50, "Bananen" priced by weight as "0,804 kg x 1,99 €/kg", "Posten: 5", a "Start: 2026-03-01 09:12:00" timestamp, and a total of "SUMME EUR 3,58".

    The correct extraction is:

    {
      "store": "Example Markt",
      "date": "2026-03-01",
      "time": "09:12",
      "items": [
        {"raw_text": "2 x 0,99 \n 400123 Cola 6x1,5L", "name": "Cola 6x1,5L", "quantity": 2, "unit_price": 0.99, "total_price": 1.98},
        {"raw_text": "Pfand 0,25", "name": "Pfand", "quantity": 1, "unit_price": 0.25, "total_price": 0.25},
        {"raw_text": "Pfand 0,25", "name": "Pfand", "quantity": 1, "unit_price": 0.25, "total_price": 0.25},
        {"raw_text": "Leergut -0,50", "name": "Leergut", "quantity": 1, "unit_price": -0.50, "total_price": -0.50},
        {"raw_text": "Bananen / 0,804 kg x 1,99 €/kg", "name": "Bananen", "quantity": 0.804, "unit_price": 1.99, "total_price": 1.60}
      ],
      "total": 3.58,
      "printed_item_count": 5
    }

    Notice in the example: The Cola received a quantity of 2 because of the explicit "2 x 0,99" multiplier text (Rule 2). The two Pfand items were kept as separate entries with a quantity of 1 because they were separate lines on the receipt (Rule 1).

    Respond with ONLY the JSON object, no explanation, no markdown code fences.
    """#

    static let maxOutputTokens = 2048

    /// The JSON structure promptTemplate asks for, as a schema for providers with structured
    /// output. Nullable where the prompt allows null/unclear values; parsing stays lenient anyway.
    static let outputSchema: JSONSchema = {
        func nullable(_ type: String, _ description: String) -> [String: Any] {
            ["type": [type, "null"], "description": description]
        }
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "raw_text": ["type": "string", "description": "The original OCR line(s) for this item, uncorrected"],
                "name": ["type": "string", "description": "Best-guess cleaned-up German item name"],
                "quantity": ["type": "number", "description": "Units purchased; 1 unless an explicit multiplier or weight is printed"],
                "unit_price": ["type": "number", "description": "Price per single unit; negative for returns/discounts"],
                "total_price": ["type": "number", "description": "quantity x unit_price"],
            ] as [String: Any],
            "required": ["raw_text", "name", "quantity", "unit_price", "total_price"],
            "additionalProperties": false,
        ]
        let root: [String: Any] = [
            "type": "object",
            "properties": [
                "store": nullable("string", "Store name"),
                "date": nullable("string", "Purchase date, YYYY-MM-DD"),
                "time": nullable("string", "Purchase time, HH:MM, or null if unclear"),
                "items": ["type": "array", "items": item] as [String: Any],
                "total": nullable("number", "Printed SUMME total, always positive"),
                "printed_item_count": nullable("integer", "Article count printed on the receipt, or null if not visible"),
            ] as [String: Any],
            "required": ["store", "date", "time", "items", "total", "printed_item_count"],
            "additionalProperties": false,
        ]
        return JSONSchema(name: "receipt_extraction", root: root)
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
