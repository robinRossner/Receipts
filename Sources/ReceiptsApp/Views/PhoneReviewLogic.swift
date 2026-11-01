import Foundation

/// What `Looks good` does next and says beforehand (both apps). Receipts still being read or that failed have nothing to
/// confirm yet, so the queue skips them.
enum ReviewQueue {
    static func waiting(in receipts: [ReceiptSummary], excluding id: Int) -> [ReceiptSummary] {
        receipts.filter { $0.reviewedAt == nil && $0.processing == nil && $0.id != id }
    }

    /// The next unreviewed receipt after this one in the list, else the first; nil when nothing is left.
    static func next(after id: Int, in receipts: [ReceiptSummary]) -> ReceiptSummary? {
        let queue = waiting(in: receipts, excluding: id)
        if let index = receipts.firstIndex(where: { $0.id == id }) {
            let later = Set(receipts[(index + 1)...].map(\.id))
            if let found = queue.first(where: { later.contains($0.id) }) { return found }
        }
        return queue.first
    }

    /// `3 more to review · next: ALDI SÜD`.
    static func hint(for id: Int, in receipts: [ReceiptSummary]) -> String {
        let more = waiting(in: receipts, excluding: id).count
        guard more > 0 else { return "Last one to review" }
        if let store = next(after: id, in: receipts)?.store, !store.isEmpty { return "\(more) more to review · next: \(store)" }
        return "\(more) more to review"
    }
}

/// Typed numbers: a German keyboard or decimal pad gives "12,50".
enum DecimalInput {
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}

/// `+12% vs last month` under a total or a tree row.
struct SpendDelta: Equatable {
    enum Trend: Equatable { case up, down, flat }
    let text: String
    let trend: Trend

    /// - Parameters:
    ///   - hasComparison: the range has a previous period at all (month and year do, custom and all time do not).
    ///   - previous: what the previous period spent on this; nil when it did not appear there.
    static func make(current: Double, previous: Double?, hasComparison: Bool, label: String) -> SpendDelta? {
        guard hasComparison else { return nil }
        guard let previous else { return SpendDelta(text: "new vs \(label)", trend: .up) }
        guard previous > 0 else { return current > 0 ? SpendDelta(text: "new vs \(label)", trend: .up) : nil }
        let percent = (current - previous) / previous * 100
        guard abs(percent) >= 0.5 else { return SpendDelta(text: "±0% vs \(label)", trend: .flat) }
        return SpendDelta(text: String(format: "%+.0f%% vs %@", percent, label), trend: percent > 0 ? .up : .down)
    }
}

/// Moving through months and years on the Overview: never past the current one.
enum OverviewCursor {
    static func isLatest(_ cursor: Date, byYear: Bool, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let component: Calendar.Component = byYear ? .year : .month
        guard let shown = calendar.dateInterval(of: component, for: cursor),
              let current = calendar.dateInterval(of: component, for: now) else { return false }
        return shown.start >= current.start
    }
}

/// The bars of "Spending by month": the top categories by total get their own colour, everything else is folded into
/// "Other". Works for any category name, including ones the user added (a name may contain anything but ">").
enum SpendingSeries {
    static let otherName = "Other"
    static let maxSeries = 5

    struct Bar: Identifiable, Equatable {
        let month: String
        let category: String
        let date: Date
        let total: Double
        var id: String { month + "\u{0}" + category }
    }

    /// Series in legend order; "Other" last. Equal totals are ordered by name, so the colours do not change between loads.
    static func names(_ monthly: [MonthCategoryTotal]) -> [String] {
        var totals: [String: Double] = [:]
        for m in monthly { totals[m.category, default: 0] += m.total }
        let ranked = totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key).filter { $0 != otherName }
        let top = Array(ranked.prefix(maxSeries))
        return ranked.count > maxSeries || totals[otherName] != nil ? top + [otherName] : top
    }

    static func bars(_ monthly: [MonthCategoryTotal]) -> [Bar] {
        let top = Set(names(monthly))
        var totals: [BarKey: Double] = [:]
        for m in monthly { totals[BarKey(month: m.month, category: top.contains(m.category) ? m.category : otherName), default: 0] += m.total }
        return totals.compactMap { key, total in
            ReceiptDateFormat.date(from: key.month + "-01").map { Bar(month: key.month, category: key.category, date: $0, total: total) }
        }
        .sorted { $0.date != $1.date ? $0.date < $1.date : $0.category < $1.category }
    }

    private struct BarKey: Hashable {
        let month: String
        let category: String
    }
}
