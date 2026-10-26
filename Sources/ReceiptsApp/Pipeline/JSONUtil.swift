import Foundation

/// Shared helpers used by both ReceiptExtractor and ItemCategorizer to parse LLM output (provider-agnostic).
enum JSONUtil {
    /// Scrapes everything between the first '{' and last '}' - mirrors parse_json_response()
    /// in both scan_and_parse_receipt.py and categorize_item.py (LLMs sometimes wrap JSON in
    /// prose or markdown fences despite being asked not to).
    static func extractObject(_ raw: String) -> [String: Any]? {
        let text = extractBraces(raw) ?? raw
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func extractBraces(_ s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\{.*\\}", options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, options: [], range: range), let r = Range(match.range, in: s) else { return nil }
        return String(s[r])
    }
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

func encodeStringArray(_ items: [String]) -> String {
    (try? JSONSerialization.data(withJSONObject: items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
}

func decodeStringArray(_ json: String?) -> [String] {
    guard let json, let data = json.data(using: .utf8) else { return [] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String] ?? []
}
