import SwiftUI
import Charts

/// Spending by month (stacked by top-level category) and per-store totals for the Overview page.
struct SpendingChartsView: View {
    let monthly: [MonthCategoryTotal]
    let stores: [StoreTotal]
    /// "yyyy-MM" to emphasise (month view); nil = no emphasis.
    let highlightMonth: String?

    private static let otherName = SpendingSeries.otherName

    private var seriesNames: [String] { SpendingSeries.names(monthly) }

    private var colorRange: [Color] {
        seriesNames.enumerated().map { i, name in name == Self.otherName ? AppTheme.chartOther : AppTheme.chartPalette[i % AppTheme.chartPalette.count] }
    }

    private var months: Int { Set(monthly.map(\.month)).count }

    private var topStores: [StoreTotal] {
        let top = Array(stores.prefix(8))
        let rest = stores.dropFirst(8).reduce(0) { $0 + $1.total }
        return rest > 0 ? top + [StoreTotal(store: Self.otherName, total: round2(rest))] : top
    }

    var body: some View {
        if monthly.isEmpty && stores.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 20) {
                chartCard("SPENDING BY MONTH") {
                    Chart(SpendingSeries.bars(monthly)) { bar in
                        // One month alone would otherwise fill the whole chart.
                        BarMark(x: .value("Month", bar.date, unit: .month), y: .value("€", bar.total), width: months == 1 ? .fixed(48) : .automatic)
                            .foregroundStyle(by: .value("Category", bar.category))
                            .opacity(isDimmed(bar.date) ? 0.45 : 1)
                    }
                    .chartForegroundStyleScale(domain: seriesNames, range: colorRange)
                    .chartXAxis {
                        // Many months (a long custom range, all time) would not fit a label each.
                        if months <= 12 {
                            AxisMarks(values: .stride(by: .month)) { _ in
                                AxisGridLine().foregroundStyle(AppTheme.rule.opacity(0.4))
                                AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(AppTheme.inkSoft)
                            }
                        } else {
                            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                                AxisGridLine().foregroundStyle(AppTheme.rule.opacity(0.4))
                                AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)).foregroundStyle(AppTheme.inkSoft)
                            }
                        }
                    }
                    .chartYAxis { AxisMarks { v in
                        AxisGridLine().foregroundStyle(AppTheme.rule.opacity(0.6))
                        AxisValueLabel { if let d = v.as(Double.self) { Text("€\(Int(d))").foregroundStyle(AppTheme.inkSoft) } }
                    } }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 220)
                }
                chartCard("BY STORE") {
                    Chart(topStores) { s in
                        BarMark(x: .value("€", s.total), y: .value("Store", s.store))
                            .foregroundStyle(AppTheme.chartPalette[2])
                            .annotation(position: .trailing) {
                                Text(fmtMoney(s.total)).font(AppTheme.mono(10)).foregroundColor(AppTheme.inkSoft)
                            }
                    }
                    .chartYAxis { AxisMarks(preset: .extended) { _ in AxisValueLabel().foregroundStyle(AppTheme.ink) } }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(max(topStores.count, 1)) * 28 + 12)
                }
            }
            .foregroundColor(AppTheme.ink)
        }
    }

    private func isDimmed(_ date: Date) -> Bool {
        guard let highlightMonth else { return false }
        return OverviewView.monthKey(date) != highlightMonth
    }

    private func chartCard<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTheme.body(11, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(AppTheme.label)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.paper)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
        .cornerRadius(4)
    }
}

/// Unit price over time, one line per item, in an item-group drill-down.
struct PriceHistoryChart: View {
    let points: [PricePoint]

    private var names: [String] { Array(Set(points.map(\.item))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PRICE HISTORY (unit price, all time)")
                .font(AppTheme.body(10, weight: .medium))
                .foregroundColor(AppTheme.inkSoft)
            Chart(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("€", p.unitPrice))
                    .foregroundStyle(by: .value("Item", p.item))
                PointMark(x: .value("Date", p.date), y: .value("€", p.unitPrice))
                    .foregroundStyle(by: .value("Item", p.item))
                    .symbolSize(18)
            }
            .chartForegroundStyleScale(domain: names, range: names.indices.map { AppTheme.chartPalette[$0 % AppTheme.chartPalette.count] })
            .chartYAxis { AxisMarks { v in
                AxisGridLine().foregroundStyle(AppTheme.rule.opacity(0.6))
                AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "€%.2f", d)).foregroundStyle(AppTheme.inkSoft) } }
            } }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 140)
        }
        .padding(.bottom, 6)
    }
}
