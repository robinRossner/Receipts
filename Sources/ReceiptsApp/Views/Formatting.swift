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
