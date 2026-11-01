import Charts
import LabCore
import SwiftUI

struct BrutalOverviewScreen: View {
    @Bindable var model: BrutalModel

    @State private var fromDate = LabFormat.date("2026-09-30") ?? .now
    @State private var toDate = LabFormat.date("2026-10-31") ?? .now
    @State private var loadingNode: String?

    private static let months: [String] = Array(Set(LabData.monthly.map(\.month))).sorted()
    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    private var currentMonth: String { Self.months[model.monthIndex] }

    private var monthLabel: String {
        let parts = currentMonth.split(separator: "-")
        return "\(Self.monthNames[(Int(parts[1]) ?? 1) - 1]) \(parts[0])"
    }

    private var octoberTotal: Double { LabData.summary(.month).total }

    /// LabData's month summary is October only, so other months scale it to that month's real chart total.
    private var factor: Double {
        guard model.range == .month, model.monthIndex != Self.months.count - 1, octoberTotal > 0 else { return 1 }
        let total = LabData.monthly.filter { $0.month == currentMonth }.reduce(0) { $0 + $1.total }
        return total / octoberTotal
    }

    private var summary: LabStatsSummary { LabData.summary(model.range) }
    private var previous: LabStatsSummary? { LabData.previousSummary(model.range) }
    private var total: Double? { model.overviewEmpty ? nil : summary.total * factor }

    var body: some View {
        VStack(spacing: 0) {
            HeroSlab {
                TitleBlock(text: "Overview", tab: .overview)
                    .frame(minHeight: 44)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        BrutalSegmented(
                            options: LabRange.allCases.map { ($0, $0.rawValue) },
                            selection: Binding(get: { model.range }, set: { value in
                                model.range = value
                                model.overviewEmpty = false
                            }),
                            accent: BP.accent(.overview)
                        )
                        periodRow
                        totalSlab
                        if model.overviewEmpty {
                            emptyBox
                        } else {
                            BrutalMonthChart(range: model.range, highlight: currentMonth)
                            BrutalStoreChart(range: model.range, factor: factor)
                            tree.id("tree")
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .task {
                    if model.drilldownFixture {
                        try? await Task.sleep(for: .milliseconds(150))
                        proxy.scrollTo("tree", anchor: .top)
                    }
                }
            }
        }
        .background(BP.page)
    }

    // MARK: Period

    @ViewBuilder
    private var periodRow: some View {
        switch model.range {
        case .month, .year:
            HStack(spacing: 8) {
                IconBlock(system: "chevron.left", label: "Previous") {
                    if model.range == .month, model.monthIndex > 0 { model.monthIndex -= 1 }
                }
                .disabled(model.range == .month && model.monthIndex == 0)
                Text(model.range == .month ? monthLabel : LabData.rangeLabel(.year))
                    .font(BF.label(16))
                    .foregroundStyle(BP.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                IconBlock(system: "chevron.right", label: "Next") {
                    if model.range == .month, model.monthIndex < Self.months.count - 1 { model.monthIndex += 1 }
                }
                .disabled(model.range != .month || model.monthIndex == Self.months.count - 1)
                refresh
            }
        case .custom:
            HStack(spacing: 8) {
                dateChip("From", $fromDate)
                dateChip("To", $toDate)
                Spacer(minLength: 0)
                refresh
            }
        case .all:
            HStack {
                Text(LabData.rangeLabel(.all))
                    .font(BF.label(16))
                    .foregroundStyle(BP.text)
                Spacer()
                refresh
            }
        }
    }

    private var refresh: some View {
        IconBlock(system: "arrow.clockwise", label: "Refresh") {}
    }

    private func dateChip(_ label: String, _ selection: Binding<Date>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(BF.label(13))
                .foregroundStyle(BP.text)
            BrutalDateChip(text: Self.format(selection.wrappedValue), selection: selection, components: .date, fontSize: 12)
        }
    }

    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private var totalSlab: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Total:")
                .font(BF.body(16, .semibold))
            Text(LabFormat.money(total))
                .font(BF.mono(25))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(BP.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .slab(BP.card, shadow: BT.shadowCard)
        .rotationEffect(.degrees(BT.tiltSlab))
        .padding(.vertical, 2)
    }

    private var emptyBox: some View {
        Text("No spending in this period.")
            .font(BF.body(17, .semibold))
            .foregroundStyle(BP.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .slab()
    }

    // MARK: Tree

    private var tree: some View {
        VStack(spacing: 0) {
            ForEach(summary.categories) { category in
                let key = category.category
                row(label: category.category, amount: category.total, level: 0, key: key,
                    delta: delta(current: category.total, previous: previous?.categories.first { $0.category == key }?.total))
                if model.openNodes.contains(key) {
                    ForEach(category.subcategories) { sub in
                        let subKey = key + "|" + sub.subcategory
                        let previousSub = previous?.categories.first { $0.category == key }?.subcategories.first { $0.subcategory == sub.subcategory }
                        row(label: sub.subcategory, amount: sub.total, level: 1, key: subKey,
                            delta: delta(current: sub.total, previous: previousSub?.total))
                        if model.openNodes.contains(subKey) {
                            ForEach(sub.itemGroups) { group in
                                let groupKey = subKey + "|" + group.itemGroup
                                row(label: group.itemGroup, amount: group.total, level: 2, key: groupKey, delta: nil)
                                if model.openNodes.contains(groupKey) {
                                    BrutalDrilldown(model: model, category: key, subcategory: sub.subcategory, itemGroup: group.itemGroup,
                                                    month: model.range == .month ? currentMonth : nil,
                                                    loading: loadingNode == groupKey)
                                }
                            }
                        }
                    }
                }
            }
        }
        .slab()
    }

    private func delta(current: Double, previous: Double?) -> (String, Color)? {
        let period: String
        switch model.range {
        case .month: period = "last month"
        case .year: period = "last year"
        case .custom, .all: return nil
        }
        guard let previous, previous > 0 else { return ("new vs \(period)", BP.redText) }
        let scaled = current * factor
        let percent = Int(((scaled - previous) / previous * 100).rounded())
        if percent == 0 { return ("±0% vs \(period)", BP.text2) }
        return percent > 0 ? ("+\(percent)% vs \(period)", BP.redText) : ("\(percent)% vs \(period)", BP.greenText)
    }

    private func row(label: String, amount: Double, level: Int, key: String, delta: (String, Color)?) -> some View {
        let open = model.openNodes.contains(key)
        return Button {
            toggle(key, level: level)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(open ? "▾" : "▸")
                    .font(BF.mono(14))
                    .foregroundStyle(BP.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(level == 0 ? BF.label(16) : BF.body(15, level == 1 ? .semibold : .regular))
                        .foregroundStyle(BP.text)
                        .multilineTextAlignment(.leading)
                    if let delta {
                        Text(delta.0)
                            .font(BF.mono(11, .medium))
                            .foregroundStyle(delta.1)
                    }
                }
                Spacer(minLength: 6)
                Text(LabFormat.money(amount * factor))
                    .font(BF.mono(level == 0 ? 16 : 14))
                    .foregroundStyle(BP.text)
            }
            .padding(.leading, 12 + CGFloat(level) * 14)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(alignment: .leading) {
                if level == 0 { BP.category(label).frame(width: 5) }
            }
            .overlay(alignment: .top) { if level == 0 { BP.line.frame(height: BT.ruleThin) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ key: String, level: Int) {
        if model.openNodes.contains(key) {
            model.openNodes = model.openNodes.filter { $0 != key && !$0.hasPrefix(key + "|") }
            return
        }
        model.openNodes.insert(key)
        if level == 2 {
            loadingNode = key
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if loadingNode == key { loadingNode = nil }
            }
        }
    }
}

// MARK: Month chart

struct BrutalMonthChart: View {
    let range: LabRange
    let highlight: String

    private static let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private var months: [String] {
        let all = Array(Set(LabData.monthly.map(\.month))).sorted()
        return range == .year ? all.filter { $0.hasPrefix("2026") } : all
    }

    private func isSelected(_ month: String) -> Bool {
        switch range {
        case .month: return month == highlight
        case .custom: return month >= "2026-09"
        case .year, .all: return true
        }
    }

    private var categories: [String] {
        var totals: [String: Double] = [:]
        for row in LabData.monthly { totals[row.category, default: 0] += row.total }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    /// `Other` goes last and on top.
    private var stackOrder: [String] { categories.filter { $0 != "Other" } + (categories.contains("Other") ? ["Other"] : []) }

    private func total(_ month: String, _ category: String) -> Double {
        LabData.monthly.first { $0.month == month && $0.category == category }?.total ?? 0
    }

    private var axisMax: Double {
        let peak = months.map { m in stackOrder.reduce(0) { $0 + total(m, $1) } }.max() ?? 0
        return max(100, ((peak / 100).rounded(.up)) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Spending by month")
            bars
            legend
        }
        .padding(12)
        .slab()
    }

    private var bars: some View {
        let top = axisMax
        let ticks: [Double] = stride(from: 0, through: top, by: top > 400 ? 200 : 100).map { $0 }
        let plotHeight: CGFloat = 170
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ForEach(ticks, id: \.self) { tick in
                        Text("€\(Int(tick))")
                            .font(BF.mono(10))
                            .foregroundStyle(BP.text2)
                            .offset(y: plotHeight - plotHeight * CGFloat(tick / top) - 7)
                    }
                }
                .frame(width: 34, height: plotHeight, alignment: .topTrailing)
                ZStack(alignment: .bottom) {
                    ForEach(ticks, id: \.self) { tick in
                        BP.line.opacity(tick == 0 ? 1 : 0.22)
                            .frame(height: tick == 0 ? BT.rule : BT.ruleThin)
                            .offset(y: -plotHeight * CGFloat(tick / top))
                    }
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(months, id: \.self) { month in
                            bar(month, plotHeight: plotHeight, top: top)
                        }
                    }
                }
                .frame(height: plotHeight)
            }
            HStack(spacing: 3) {
                Color.clear.frame(width: 37)
                ForEach(months, id: \.self) { month in
                    Text(Self.names[(Int(month.suffix(2)) ?? 1) - 1])
                        .font(BF.mono(8))
                        .foregroundStyle(isSelected(month) ? BP.text : BP.text2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending by month chart")
    }

    private func bar(_ month: String, plotHeight: CGFloat, top: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(stackOrder.reversed(), id: \.self) { category in
                let value = total(month, category)
                if value > 0 {
                    BP.category(category)
                        .opacity(isSelected(month) ? 1 : 0.45)
                        .frame(height: max(2, plotHeight * CGFloat(value / top)))
                        .overlay(alignment: .top) { BP.line.frame(height: BT.ruleThin) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.ruleThin))
    }

    private var legend: some View {
        BrutalFlow(spacing: 10) {
            ForEach(stackOrder, id: \.self) { category in
                BrutalLegendItem(color: BP.category(category), text: category)
            }
        }
    }
}

struct BrutalLegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            color
                .frame(width: 12, height: 12)
                .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.ruleThin))
            Text(text)
                .font(BF.body(12, .medium))
                .foregroundStyle(BP.text)
                .lineLimit(1)
        }
    }
}

/// Wrapping row layout, for legends.
struct BrutalFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: rows(subviews, width: width).last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(subviews, width: bounds.width) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)]; var y: CGFloat; var height: CGFloat }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var current = Row(items: [], y: 0, height: 0)
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, !current.items.isEmpty {
                rows.append(current)
                y += current.height + spacing / 2
                x = 0
                current = Row(items: [], y: y, height: 0)
            }
            current.items.append((index, x))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: Store chart

struct BrutalStoreChart: View {
    let range: LabRange
    let factor: Double

    private var rows: [(String, Double)] {
        let totals = LabData.storeTotals(range)
        var out = totals.prefix(8).map { ($0.store, $0.total * factor) }
        let rest = totals.dropFirst(8).reduce(0) { $0 + $1.total } * factor
        if rest > 0 { out.append(("Other", rest)) }
        return out
    }

    var body: some View {
        let rows = rows
        let top = rows.map(\.1).max() ?? 1
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "By store")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(BF.body(13, .medium))
                            .foregroundStyle(BP.text)
                            .lineLimit(1)
                        GeometryReader { geo in
                            HStack(spacing: 6) {
                                BP.accent(.overview)
                                    .frame(width: max(4, (geo.size.width - 76) * CGFloat(row.1 / top)))
                                    .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
                                Text(LabFormat.money(row.1))
                                    .font(BF.mono(12))
                                    .foregroundStyle(BP.text)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .frame(height: 14)
                    }
                }
            }
        }
        .padding(12)
        .slab()
    }
}

// MARK: Drill-down

struct BrutalDrilldown: View {
    let model: BrutalModel
    let category: String
    let subcategory: String
    let itemGroup: String
    let month: String?
    let loading: Bool

    private var purchases: [LabPurchaseRow] {
        let all = LabData.purchases(category: category, subcategory: subcategory, itemGroup: itemGroup, range: .all)
        guard let month else { return all }
        return all.filter { $0.date?.hasPrefix(month) == true }
    }

    private var history: [LabPricePoint] {
        LabData.priceHistory(category: category, subcategory: subcategory, itemGroup: itemGroup)
    }

    private var products: [String] { Array(Set(history.map(\.item))).sorted() }

    private static let lineColors: [Color] = BP.chartLines

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                Text("Loading…")
                    .font(BF.body(14, .medium))
                    .foregroundStyle(BP.text2)
            } else {
                if history.count >= 2 { priceBox }
                if purchases.isEmpty {
                    Text("No purchases found.")
                        .font(BF.body(14, .medium))
                        .foregroundStyle(BP.text2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(purchases) { purchase in
                            purchaseRow(purchase)
                            if purchase.id != purchases.last?.id { BP.line.frame(height: BT.ruleThin) }
                        }
                    }
                }
            }
        }
        .padding(10)
    }

    private var priceBox: some View {
        let colors = Dictionary(uniqueKeysWithValues: products.enumerated().map { ($1, Self.lineColors[$0 % Self.lineColors.count]) })
        return VStack(alignment: .leading, spacing: 8) {
            Text("Price history (unit price, all time)")
                .font(BF.label(13))
                .foregroundStyle(BP.text)
            Chart(history) { point in
                LineMark(x: .value("Date", point.date), y: .value("Unit price", point.unitPrice), series: .value("Product", point.item))
                    .foregroundStyle(colors[point.item] ?? BP.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .square, lineJoin: .miter))
                PointMark(x: .value("Date", point.date), y: .value("Unit price", point.unitPrice))
                    .symbol(.square)
                    .symbolSize(26)
                    .foregroundStyle(BP.line)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 21)) { value in
                    AxisGridLine().foregroundStyle(BP.line.opacity(0.2))
                    AxisValueLabel(anchor: .topLeading) {
                        if let date = value.as(Date.self) {
                            Text(Self.shortDate(date)).font(BF.mono(10)).foregroundStyle(BP.text2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(BP.line.opacity(0.2))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(LabFormat.money(v)).font(BF.mono(10)).foregroundStyle(BP.text2) }
                    }
                }
            }
            .frame(height: 140)
            BrutalFlow(spacing: 10) {
                ForEach(products, id: \.self) { product in
                    BrutalLegendItem(color: colors[product] ?? BP.blue, text: product)
                }
            }
        }
        .padding(10)
        .background(BP.page)
        .overlay(Rectangle().strokeBorder(BP.line, style: StrokeStyle(lineWidth: BT.borderThin, dash: [5, 4])))
    }

    private func purchaseRow(_ purchase: LabPurchaseRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(purchase.date ?? "—")  \(purchase.store ?? "Unknown")")
                    .font(BF.mono(11, .regular))
                    .foregroundStyle(BP.text2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(purchase.translationEn ?? purchase.nameDe ?? "")
                    .font(BF.body(14, .medium))
                    .foregroundStyle(BP.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(LabFormat.money(purchase.totalPrice))
                .font(BF.mono(13))
                .foregroundStyle(BP.text)
            Button("Edit") { model.open(purchase.receiptId, expanding: purchase.lineItemId) }
                .buttonStyle(.slabSmall())
        }
        .padding(.vertical, 6)
    }
}
