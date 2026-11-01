import Charts
import LabCore
import SwiftUI

/// LabCore's stat types have no public initializers, so the months the arrows reach use these.
struct OCategory: Identifiable {
    var id: String { category }
    let category: String
    let total: Double
    let subcategories: [LabSubcategoryStat]
}

struct OStats {
    let total: Double
    let categories: [OCategory]

    init(total: Double, categories: [OCategory]) {
        self.total = total
        self.categories = categories
    }

    init(_ summary: LabStatsSummary) {
        total = summary.total
        categories = summary.categories.map { OCategory(category: $0.category, total: $0.total, subcategories: $0.subcategories) }
    }
}

struct StoreRow: Identifiable {
    var id: String { store }
    let store: String
    let total: Double

    init(store: String, total: Double) {
        self.store = store
        self.total = total
    }

    init(_ row: LabStoreTotal) {
        store = row.store
        total = row.total
    }
}

/// Figures for what the Overview is showing, including months the arrows move to.
@MainActor
enum OverviewData {
    /// "yyyy-MM" of the month shown; offset 0 is October 2026.
    static func monthKey(offset: Int) -> String {
        let total = 2026 * 12 + 9 + offset
        return String(format: "%04d-%02d", total / 12, total % 12 + 1)
    }

    static func monthLabel(offset: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "LLLL yyyy"
        return LabFormat.date(monthKey(offset: offset) + "-01").map { f.string(from: $0) } ?? ""
    }

    static func summary(store: PolishStore) -> OStats {
        if store.overviewForcedEmpty { return OStats(total: 0, categories: []) }
        switch store.range {
        case .month: return monthSummary(offset: store.monthOffset)
        case .year: return yearSummary(offset: store.yearOffset)
        case .custom, .all: return OStats(LabData.summary(store.range))
        }
    }

    static func previous(store: PolishStore) -> OStats? {
        switch store.range {
        case .month:
            let summary = monthSummary(offset: store.monthOffset - 1)
            return summary
        case .year:
            return store.yearOffset == 0 ? LabData.previousSummary(.year).map(OStats.init) : OStats(total: 0, categories: [])
        case .custom, .all:
            return nil
        }
    }

    static func stores(store: PolishStore) -> [StoreRow] {
        if store.overviewForcedEmpty { return [] }
        switch store.range {
        case .month:
            let key = monthKey(offset: store.monthOffset)
            var totals: [String: Double] = [:]
            for receipt in LabData.receipts where receipt.date?.hasPrefix(key) == true {
                totals[receipt.store ?? "Unknown", default: 0] += receipt.computedSum ?? 0
            }
            return totals.map { StoreRow(store: $0.key, total: ($0.value * 100).rounded() / 100) }.sorted { $0.total > $1.total }
        case .year:
            return store.yearOffset == 0 ? LabData.storeTotals(.year).map(StoreRow.init) : []
        case .custom, .all:
            return LabData.storeTotals(store.range).map(StoreRow.init)
        }
    }

    private static func monthSummary(offset: Int) -> OStats {
        let key = monthKey(offset: offset)
        if offset == 0 { return OStats(LabData.summary(.month)) }
        if offset == -1 { return LabData.previousSummary(.month).map(OStats.init) ?? flat(prefix: key) }
        return flat(prefix: key)
    }

    private static func yearSummary(offset: Int) -> OStats {
        if offset == 0 { return OStats(LabData.summary(.year)) }
        return flat(prefix: String(2026 + offset))
    }

    /// Months with no receipts in the fake data only have category totals from `LabData.monthly`.
    private static func flat(prefix: String) -> OStats {
        var totals: [String: Double] = [:]
        for row in LabData.monthly where row.month.hasPrefix(prefix) { totals[row.category, default: 0] += row.total }
        let categories = totals
            .map { OCategory(category: $0.key, total: ($0.value * 100).rounded() / 100, subcategories: []) }
            .sorted { $0.total > $1.total }
        return OStats(total: (categories.reduce(0) { $0 + $1.total } * 100).rounded() / 100, categories: categories)
    }
}

struct OverviewScreen: View {
    @Bindable var store: PolishStore
    @State private var from = LabFormat.date("2026-09-30") ?? Date()
    @State private var to = LabFormat.date("2026-10-31") ?? Date()
    @State private var refreshing = false

    private var summary: OStats { OverviewData.summary(store: store) }
    private var previous: OStats? { OverviewData.previous(store: store) }
    private var deltaSuffix: String { store.range == .year ? "last year" : "last month" }

    var body: some View {
        NavigationStack(path: $store.overviewPath) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        rangeHeader
                        totalBlock
                        if !store.overviewIsEmpty {
                            monthlyCard
                            storesCard
                            tree
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .task {
                    guard store.scrollToDrilldown else { return }
                    store.scrollToDrilldown = false
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo("drilldown", anchor: .top)
                }
            }
            .background(P.desk)
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(P.paper, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Overview").font(P.display(20)).foregroundStyle(P.ink)
                }
            }
            .navigationDestination(for: Int.self) { id in
                ReceiptDetailScreen(store: store, receiptId: id, path: $store.overviewPath)
            }
        }
    }

    // MARK: Header

    private var rangeHeader: some View {
        VStack(spacing: 8) {
            Picker("Range", selection: Binding(get: { store.range }, set: { store.range = $0; store.overviewForcedEmpty = false })) {
                ForEach(LabRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 4) {
                switch store.range {
                case .month, .year:
                    nav("chevron.left", label: "Previous") { move(-1) }
                    Text(rangeLabel)
                        .font(P.display(19))
                        .foregroundStyle(P.ink)
                        .frame(maxWidth: .infinity)
                    nav("chevron.right", label: "Next") { move(1) }
                        .disabled(atLatest)
                        .opacity(atLatest ? 0.3 : 1)
                case .custom:
                    DatePicker("From", selection: $from, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("From")
                    Text("–").foregroundStyle(P.label)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("To")
                    Spacer(minLength: 0)
                case .all:
                    Text("All time")
                        .font(P.display(19))
                        .foregroundStyle(P.ink)
                        .frame(maxWidth: .infinity)
                }
                nav("arrow.clockwise", label: "Refresh") {
                    withAnimation(.easeInOut(duration: 0.6)) { refreshing.toggle() }
                }
                .rotationEffect(.degrees(refreshing ? 360 : 0))
            }
        }
    }

    private var atLatest: Bool { store.range == .month ? store.monthOffset >= 0 : store.yearOffset >= 0 }

    private func move(_ delta: Int) {
        store.overviewForcedEmpty = false
        if store.range == .month { store.monthOffset += delta } else { store.yearOffset += delta }
    }

    private var rangeLabel: String {
        store.range == .month ? OverviewData.monthLabel(offset: store.monthOffset) : String(2026 + store.yearOffset)
    }

    private func nav(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(P.ink)
                .frame(width: 40, height: 40)
                .background(P.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(P.rule, lineWidth: 1))
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Total

    private var totalBlock: some View {
        VStack(spacing: 2) {
            Text("Total:")
                .font(P.body(13, .medium))
                .foregroundStyle(P.label)
            Text(summary.total > 0 ? LabFormat.money(summary.total) : "—")
                .font(P.mono(36, .semibold))
                .foregroundStyle(P.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if summary.total > 0, let delta = delta(current: summary.total, previous: previous?.total, hasPrevious: previous != nil) {
                Text(delta.text)
                    .font(P.body(13, .medium))
                    .foregroundStyle(delta.color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func delta(current: Double, previous: Double?, hasPrevious: Bool) -> (text: String, color: Color)? {
        guard hasPrevious else { return nil }
        guard let previous, previous > 0 else { return ("new vs \(deltaSuffix)", P.red) }
        let percent = Int(((current - previous) / previous * 100).rounded())
        if percent == 0 { return ("±0% vs \(deltaSuffix)", P.label) }
        return (percent > 0 ? "+\(percent)% vs \(deltaSuffix)" : "\(percent)% vs \(deltaSuffix)", percent > 0 ? P.red : P.greenText)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundStyle(P.label)
            Text("No spending in this period.")
                .font(P.body(15))
                .foregroundStyle(P.label)
        }
        .padding(.top, 50)
    }

    // MARK: Charts

    private func color(_ category: String) -> Color {
        switch category {
        case "Food": return P.series[0]
        case "Household": return P.series[1]
        case "Personal Care": return P.series[2]
        case "Other": return P.seriesOther
        default: return P.series[3]
        }
    }

    private var highlight: String? {
        store.range == .month ? OverviewData.monthKey(offset: store.monthOffset) : nil
    }

    private var monthlyCard: some View {
        let names = ["Food", "Household", "Personal Care", "Other"]
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Spending by month")
            Chart(LabData.monthly) { bar in
                BarMark(x: .value("Month", bar.date, unit: .month), y: .value("€", bar.total))
                    .foregroundStyle(by: .value("Category", bar.category))
                    .opacity(highlight == nil || highlight == bar.month ? 1 : 0.45)
            }
            .chartForegroundStyleScale(domain: names, range: names.map(color))
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine().foregroundStyle(P.rule.opacity(0.4))
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                        .foregroundStyle(P.inkSoft)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(P.rule.opacity(0.6))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text("€\(Int(v))").font(P.mono(10)).foregroundStyle(P.inkSoft) }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 200)
            FlowLayout(spacing: 12) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(color(name)).frame(width: 10, height: 10)
                        Text(name).font(P.body(12)).foregroundStyle(P.inkSoft)
                    }
                }
            }
        }
        .paperCard()
    }

    private var storesCard: some View {
        let all = OverviewData.stores(store: store)
        let top = Array(all.prefix(8))
        let rest = all.dropFirst(8).reduce(0) { $0 + $1.total }
        let rows = rest > 0 ? top + [StoreRow(store: "Other", total: (rest * 100).rounded() / 100)] : top
        let peak = rows.map(\.total).max() ?? 1
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "By store")
                    VStack(spacing: 9) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(row.store).font(P.body(13.5)).foregroundStyle(P.ink).lineLimit(1)
                                    Spacer()
                                    Text(LabFormat.money(row.total)).font(P.mono(13, .medium)).foregroundStyle(P.ink)
                                }
                                GeometryReader { geometry in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(row.store == "Other" ? P.seriesOther : P.series[2])
                                        .frame(width: max(3, geometry.size.width * row.total / max(peak, 0.01)))
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                }
                .paperCard()
            }
        }
    }

    // MARK: Tree

    private var tree: some View {
        VStack(spacing: 0) {
            let categories = summary.categories
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                categoryRows(category)
                if index < categories.count - 1 { Rectangle().fill(P.rule).frame(height: 1) }
            }
        }
        .paperCard(padding: 4)
    }

    @ViewBuilder
    private func categoryRows(_ category: OCategory) -> some View {
        let prevCategory = previous?.categories.first { $0.category == category.category }
        let key = category.category
        treeRow(title: category.category, total: category.total, level: 0, key: key,
                expandable: !category.subcategories.isEmpty,
                delta: previous == nil ? nil : delta(current: category.total, previous: prevCategory?.total, hasPrevious: true))
        if store.expanded.contains(key) {
            ForEach(category.subcategories) { sub in
                let subKey = "\(key)>\(sub.subcategory)"
                let hasBreakdown = prevCategory?.subcategories.isEmpty == false
                let prevSub = prevCategory?.subcategories.first { $0.subcategory == sub.subcategory }
                treeRow(title: sub.subcategory, total: sub.total, level: 1, key: subKey, expandable: true,
                        delta: previous == nil || !hasBreakdown ? nil : delta(current: sub.total, previous: prevSub?.total, hasPrevious: true))
                if store.expanded.contains(subKey) {
                    ForEach(sub.itemGroups) { group in
                        let groupKey = "\(subKey)>\(group.itemGroup)"
                        treeRow(title: group.itemGroup, total: group.total, level: 2, key: groupKey, expandable: true, delta: nil)
                            .id(groupKey == drilldownKey ? "drilldown" : groupKey)
                        if store.expanded.contains(groupKey) {
                            drilldown(category: category.category, subcategory: sub.subcategory, group: group.itemGroup)
                        }
                    }
                }
            }
        }
    }

    private var drilldownKey: String {
        let path = LabData.drilldownPath
        return "\(path.category)>\(path.subcategory)>\(path.itemGroup)"
    }

    private func treeRow(title: String, total: Double, level: Int, key: String, expandable: Bool,
                         delta: (text: String, color: Color)?) -> some View {
        Button {
            guard expandable else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                if store.expanded.contains(key) { store.expanded.remove(key) } else { store.expanded.insert(key) }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(P.inkSoft)
                    .rotationEffect(.degrees(store.expanded.contains(key) ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .opacity(expandable ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(P.body(level == 0 ? 15.5 : level == 1 ? 14.5 : 14, level == 0 ? .semibold : .regular))
                            .foregroundStyle(P.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text(LabFormat.money(total))
                            .font(P.mono(level == 0 ? 15 : 14, level == 0 ? .semibold : .regular))
                            .foregroundStyle(P.ink)
                    }
                    if let delta {
                        Text(delta.text).font(P.body(12)).foregroundStyle(delta.color)
                    }
                }
            }
            .padding(.leading, 6 + CGFloat(level) * 16)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Drill-down

    @ViewBuilder
    private func drilldown(category: String, subcategory: String, group: String) -> some View {
        let points = LabData.priceHistory(category: category, subcategory: subcategory, itemGroup: group)
        let purchases = LabData.purchases(category: category, subcategory: subcategory, itemGroup: group,
                                          range: store.range == .month ? .month : .all)
        VStack(alignment: .leading, spacing: 10) {
            if points.count >= 2 { priceHistory(points) }
            if purchases.isEmpty {
                Text("No purchases found.")
                    .font(P.body(14))
                    .foregroundStyle(P.inkSoft)
                    .padding(.vertical, 6)
            }
            VStack(spacing: 0) {
                ForEach(Array(purchases.enumerated()), id: \.element.id) { index, purchase in
                    purchaseRow(purchase)
                    if index < purchases.count - 1 { Rectangle().fill(P.rule.opacity(0.6)).frame(height: 1) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func priceHistory(_ points: [LabPricePoint]) -> some View {
        let names = Array(Set(points.map(\.item))).sorted()
        let colors = names.indices.map { P.series[$0 % P.series.count] }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Price history (unit price, all time)")
            Chart(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Price", point.unitPrice))
                    .foregroundStyle(by: .value("Item", point.item))
                PointMark(x: .value("Date", point.date), y: .value("Price", point.unitPrice))
                    .foregroundStyle(by: .value("Item", point.item))
                    .symbolSize(24)
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(P.rule.opacity(0.4))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(P.inkSoft)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(P.rule.opacity(0.6))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(LabFormat.money(v)).font(P.mono(10)).foregroundStyle(P.inkSoft) }
                    }
                }
            }
            .frame(height: 140)
            FlowLayout(spacing: 12) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    HStack(spacing: 5) {
                        Circle().fill(colors[index]).frame(width: 8, height: 8)
                        Text(name).font(P.body(12)).foregroundStyle(P.inkSoft)
                    }
                }
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(P.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func purchaseRow(_ purchase: LabPurchaseRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(purchase.translationEn ?? purchase.nameDe ?? "")
                    .font(P.body(14))
                    .foregroundStyle(P.ink)
                    .lineLimit(1)
                Text("\(purchase.date ?? "") · \(purchase.store ?? "")")
                    .font(P.mono(11))
                    .foregroundStyle(P.inkSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Text(LabFormat.money(purchase.totalPrice))
                .font(P.mono(13.5, .medium))
                .foregroundStyle(P.ink)
            Button("Edit") {
                store.highlightItem = purchase.lineItemId
                store.overviewPath.append(purchase.receiptId)
            }
            .buttonStyle(OutlineButtonStyle())
            .fixedSize()
        }
        .padding(.vertical, 5)
    }
}
