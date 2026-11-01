import Charts
import LabCore
import SwiftUI

struct OverviewTab: View {
    @Bindable var model: GlassModel

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        Picker("Range", selection: $model.range) {
                            ForEach(LabRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    totalSection
                    if model.summary.categories.isEmpty {
                        Section {
                            ContentUnavailableView {
                                Label("No spending in this period.", systemImage: "chart.bar.xaxis")
                            }
                        }
                    } else {
                        Section {
                            MonthlyChart(model: model)
                        } header: {
                            Text("Spending by month").textCase(nil)
                        }
                        Section {
                            StoreChart(bars: model.storeBars)
                        } header: {
                            Text("By store").textCase(nil)
                        }
                        Section {
                            TreeRows(model: model)
                        } header: {
                            Text("Categories").textCase(nil)
                        }
                    }
                }
                .task {
                    if model.scrollToDrilldown {
                        model.scrollToDrilldown = false
                        try? await Task.sleep(for: .seconds(0.3))
                        proxy.scrollTo(drilldownRowID, anchor: .top)
                    }
                }
            }
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") {}
                }
            }
        }
    }

    private var drilldownRowID: String {
        let p = LabData.drilldownPath
        return p.category + "|" + p.subcategory + "|" + p.itemGroup
    }

    @ViewBuilder
    private var totalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.summary.categories.isEmpty ? "—" : LabFormat.money(model.summary.total))
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.vertical, 2)

            switch model.range {
            case .month, .year:
                HStack {
                    stepButton("Previous", "chevron.left", by: -1)
                    Spacer()
                    Text(model.rangeLabel).font(.headline)
                    Spacer()
                    stepButton("Next", "chevron.right", by: 1)
                }
            case .custom:
                DatePicker("From", selection: $model.customFrom, displayedComponents: .date)
                DatePicker("To", selection: $model.customTo, displayedComponents: .date)
            case .all:
                Text(model.rangeLabel).font(.headline)
            }
        }
    }

    private func stepButton(_ title: String, _ image: String, by step: Int) -> some View {
        Button(title, systemImage: image) {
            withAnimation(.snappy) {
                if model.range == .month {
                    model.monthOffset += step
                } else {
                    model.yearOffset += step
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
}

// MARK: Charts

/// Fixed order, so a category keeps its colour on every range. Checked with the palette validator: `Other` is
/// deliberately grey, and the legend carries identity alongside colour.
private let categoryOrder = ["Food", "Household", "Personal Care", "Other"]
private let categoryColors: [Color] = [.blue, .teal, .purple, Color(.systemGray)]

private struct MonthlyChart: View {
    let model: GlassModel

    var body: some View {
        Chart(model.chartMonths) { row in
            BarMark(
                x: .value("Month", row.date, unit: .month),
                y: .value("Amount", row.total),
                width: .ratio(0.62)
            )
            .foregroundStyle(by: .value("Category", row.category))
            .cornerRadius(3)
            .opacity(model.range != .month || row.month == model.selectedMonth ? 1 : 0.45)
        }
        .chartForegroundStyleScale(domain: categoryOrder, range: categoryColors)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text("€\(Int(amount))") }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
        .frame(height: 240)
        .padding(.vertical, 8)
    }
}

private struct StoreChart: View {
    let bars: [StoreBar]

    var body: some View {
        let maxTotal = bars.map(\.total).max() ?? 1
        Chart(bars) { bar in
            BarMark(
                x: .value("Amount", bar.total),
                y: .value("Store", bar.store),
                height: .ratio(0.6)
            )
            .foregroundStyle(.tint)
            .cornerRadius(3)
            .annotation(position: .trailing, spacing: 6) {
                Text(LabFormat.money(bar.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .chartXScale(domain: 0...(maxTotal * 1.3))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let store = value.as(String.self) {
                        Text(store)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(height: CGFloat(bars.count) * 30 + 8)
        .padding(.vertical, 6)
    }
}

// MARK: Tree

private struct TreeRows: View {
    @Bindable var model: GlassModel

    private var periodWord: String { model.range == .year ? "last year" : "last month" }

    var body: some View {
        ForEach(model.summary.categories) { category in
            let categoryKey = category.category
            TreeRow(
                title: category.category, amount: category.total, depth: 0,
                delta: delta(category.total, previous: previousCategory(category.category)?.total),
                isOpen: model.openCategories.contains(categoryKey)
            ) { toggle(&model.openCategories, categoryKey) }

            if model.openCategories.contains(categoryKey) {
                ForEach(category.subcategories) { sub in
                    let subKey = categoryKey + "|" + sub.subcategory
                    TreeRow(
                        title: sub.subcategory, amount: sub.total, depth: 1,
                        delta: delta(
                            sub.total,
                            previous: previousCategory(category.category)?.subcategories.first { $0.subcategory == sub.subcategory }?.total
                        ),
                        isOpen: model.openSubcategories.contains(subKey)
                    ) { toggle(&model.openSubcategories, subKey) }

                    if model.openSubcategories.contains(subKey) {
                        ForEach(sub.itemGroups) { group in
                            let groupKey = subKey + "|" + group.itemGroup
                            TreeRow(
                                title: group.itemGroup, amount: group.total, depth: 2, delta: nil,
                                isOpen: model.openGroups.contains(groupKey)
                            ) { toggle(&model.openGroups, groupKey) }
                            .id(groupKey)

                            if model.openGroups.contains(groupKey) {
                                Drilldown(model: model, category: category.category, subcategory: sub.subcategory, itemGroup: group.itemGroup)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ set: inout Set<String>, _ key: String) {
        withAnimation(.snappy) {
            if set.contains(key) {
                set.remove(key)
            } else {
                set.insert(key)
            }
        }
    }

    private func previousCategory(_ name: String) -> LabCategoryStat? {
        model.previousSummary?.categories.first { $0.category == name }
    }

    private func delta(_ current: Double, previous: Double?) -> (text: String, color: Color)? {
        guard model.previousSummary != nil else { return nil }
        guard let previous, previous > 0 else { return ("new vs \(periodWord)", .secondary) }
        let percent = Int(((current - previous) / previous * 100).rounded())
        if percent == 0 { return ("±0% vs \(periodWord)", .secondary) }
        return percent > 0 ? ("+\(percent)% vs \(periodWord)", .red) : ("\(percent)% vs \(periodWord)", .green)
    }
}

private struct TreeRow: View {
    let title: String
    let amount: Double
    let depth: Int
    let delta: (text: String, color: Color)?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .fontWeight(depth == 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if let delta {
                        Text(delta.text)
                            .font(.caption)
                            .foregroundStyle(delta.color)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 6)
                Text(LabFormat.money(amount)).amount()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Drilldown: View {
    let model: GlassModel
    let category: String
    let subcategory: String
    let itemGroup: String

    private var purchases: [LabPurchaseRow] {
        LabData.purchases(category: category, subcategory: subcategory, itemGroup: itemGroup, range: model.range)
    }

    private var history: [LabPricePoint] {
        LabData.priceHistory(category: category, subcategory: subcategory, itemGroup: itemGroup)
    }

    var body: some View {
        if history.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Price history (unit price, all time)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Chart(history) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Unit price", point.unitPrice))
                        .foregroundStyle(by: .value("Product", point.item))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Date", point.date), y: .value("Unit price", point.unitPrice))
                        .foregroundStyle(by: .value("Product", point.item))
                        .symbolSize(28)
                }
                .chartForegroundStyleScale(range: categoryColors)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let price = value.as(Double.self) { Text(LabFormat.money(price)) }
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 190)
            }
            .padding(.vertical, 6)
        }
        if purchases.isEmpty {
            Text("No purchases found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        ForEach(purchases) { row in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.translationEn ?? row.nameDe ?? "")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("\(row.date ?? "") · \(row.store ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(LabFormat.money(row.totalPrice))
                    .font(.subheadline)
                    .monospacedDigit()
                Button("Edit") { model.open(row.receiptId, highlightItem: row.lineItemId) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
