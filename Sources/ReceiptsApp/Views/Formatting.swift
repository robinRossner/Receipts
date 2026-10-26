import Foundation

/// Mirrors fmtMoney()/fmtQty() in dashboard.html.
func fmtMoney(_ v: Double?) -> String {
    guard let v else { return "—" }
    return String(format: "€%.2f", v)
}

func trimmedNumber(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    var s = String(format: "%.3f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

func fmtQty(_ q: Double) -> String {
    trimmedNumber((q * 1000).rounded() / 1000)
}

/// The string formats receipts store for date ("yyyy-MM-dd") and time ("HH:mm").
enum ReceiptDateFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }
    static func dateString(from d: Date) -> String { formatter("yyyy-MM-dd").string(from: d) }
    static func timeString(from d: Date) -> String { formatter("HH:mm").string(from: d) }
    static func date(from s: String?) -> Date? { s.flatMap { formatter("yyyy-MM-dd").date(from: String($0.prefix(10))) } }
    /// Today's date at the stored "HH:mm" (or "HH:mm:ss").
    static func time(from s: String?) -> Date? { s.flatMap { formatter("HH:mm").date(from: String($0.prefix(5))) } }
}
