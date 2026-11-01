import Charts
import SwiftUI

/// Overview: a range (month, year, custom, all time), a hero total with its change, spending charts and an expandable
/// category > subcategory > item group tree with a lazy-loaded purchase drill-down. A purchase's `Edit` opens that
/// receipt with the item open.
struct OverviewScreen: View {
    @EnvironmentObject var store: ReceiptStore
    @EnvironmentObject private var snacks: SnackCenter
    let isActive: Bool

    private enum RangeMode: String, CaseIterable, Identifiable {
        case month = "Month", year = "Year", custom = "Custom", all = "All time"
        var id: String { rawValue }
    }

    private struct EditTarget: Hashable {
        let receiptId: Int
        let itemDictionaryId: Int
    }

    private enum Route: Hashable {
        case edit(EditTarget)
        case flagged
    }

    @State private var path: [Route] = []
    @State private var mode: RangeMode = .month
    /// Month or year being shown (the arrows move it).
    @State private var monthCursor = Date()
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var summary: StatsSummary?
    @State private var previousSummary: StatsSummary?
    @State private var monthly: [MonthCategoryTotal] = []
    @State private var storeTotals: [StoreTotal] = []
    @State private var priceHistories: [String: [PricePoint]] = [:]
    @State private var refreshing = false

    @State private var open: Set<String> = []
    @State private var groupDetails: [String: ItemGroupDetail] = [:]
    @State private var loadingGroups: Set<String> = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    rangeHeader
                    totalBlock
                    flaggedRow
                    if !monthly.isEmpty { monthlyCard }
                    if !storeTotals.isEmpty { storesCard }
                    if let summary, !summary.categories.isEmpty {
                        tree(summary)
                    } else {
                        emptyState
                    }
                }
                .padding(12)
            }
            .background(Theme.desk)
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Overview").font(Theme.display(20)).foregroundStyle(Theme.ink)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .edit(let target):
                    ReceiptDetailScreen(id: target.receiptId, highlightDictionaryId: target.itemDictionaryId)
                case .flagged:
                    FlaggedItemsScreen { receiptId, itemDictionaryId in
                        path.append(.edit(EditTarget(receiptId: receiptId, itemDictionaryId: itemDictionaryId)))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let snack = snacks.current, path.isEmpty {
                    SnackbarView(snack: snack, undo: snacks.performUndo)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
        }
        .onChange(of: isActive) {
            // Always refetch on becoming visible: an item may have just been corrected on another tab.
            if isActive { Task { await load() } }
        }
        .onChange(of: path) {
            if path.isEmpty { Task { await load() } }   // back from an edit
        }
        .onChange(of: store.receipts) {
            if isActive && path.isEmpty { Task { await load() } }   // a sync or an undo changed the data
        }
        .onChange(of: mode) { Task { await load() } }
        .onChange(of: customStart) { if mode == .custom { Task { await load() } } }
        .onChange(of: customEnd) { if mode == .custom { Task { await load() } } }
    }

    // MARK: Header

    private var rangeHeader: some View {
        VStack(spacing: 8) {
            Picker("Range", selection: $mode) {
                ForEach(RangeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 4) {
                switch mode {
                case .month, .year:
                    nav("chevron.left", label: "Previous") { moveCursor(-1) }
                    Text(rangeLabel)
                        .font(Theme.display(19))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                    nav("chevron.right", label: "Next") { moveCursor(1) }
                        .disabled(atLatest)
                        .opacity(atLatest ? 0.3 : 1)
                case .custom:
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("From")
                    Text("–").foregroundStyle(Theme.label)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("To")
                    Spacer(minLength: 0)
                case .all:
                    Text("All time")
                        .font(Theme.display(19))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                }
                nav("arrow.clockwise", label: "Refresh") {
                    withAnimation(.easeInOut(duration: 0.6)) { refreshing.toggle() }
                    store.invalidateStatsCache()
                    Task { await load() }
                }
                .rotationEffect(.degrees(refreshing ? 360 : 0))
            }
        }
    }

    private var atLatest: Bool { OverviewCursor.isLatest(monthCursor, byYear: mode == .year) }

    private func nav(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule, lineWidth: 1))
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var rangeLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        switch mode {
        case .all: return "All time"
        case .custom: return "\(ReceiptDateFormat.dateString(from: customStart)) – \(ReceiptDateFormat.dateString(from: customEnd))"
        case .year:
            f.dateFormat = "yyyy"
            return f.string(from: monthCursor)
        case .month:
            f.dateFormat = "LLLL yyyy"
            return f.string(from: monthCursor)
        }
    }

    private func bounds(of component: Calendar.Component, containing date: Date) -> (start: String, end: String) {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: component, for: date) else {
            let d = ReceiptDateFormat.dateString(from: date)
            return (d, d)
        }
        return (ReceiptDateFormat.dateString(from: interval.start), ReceiptDateFormat.dateString(from: interval.end.addingTimeInterval(-1)))
    }

    /// First and last day of the selected range, "yyyy-MM-dd"; nil/nil = all time.
    private var rangeStartEnd: (start: String?, end: String?) {
        switch mode {
        case .all: return (nil, nil)
        case .custom:
            return (ReceiptDateFormat.dateString(from: min(customStart, customEnd)), ReceiptDateFormat.dateString(from: max(customStart, customEnd)))
        case .month:
            let b = bounds(of: .month, containing: monthCursor)
            return (b.start, b.end)
        case .year:
            let b = bounds(of: .year, containing: monthCursor)
            return (b.start, b.end)
        }
    }

    /// The period right before the selected one (month and year only), for the deltas.
    private var previousRange: (start: String, end: String)? {
        let cal = Calendar.current
        switch mode {
        case .month: return cal.date(byAdding: .month, value: -1, to: monthCursor).map { bounds(of: .month, containing: $0) }
        case .year: return cal.date(byAdding: .year, value: -1, to: monthCursor).map { bounds(of: .year, containing: $0) }
        default: return nil
        }
    }

    private var previousLabel: String { mode == .year ? "last year" : "last month" }

    /// Range the bar chart covers: the 12 months up to the selected one in month view.
    private var chartRange: (start: String?, end: String?) {
        if mode == .month, let from = Calendar.current.date(byAdding: .month, value: -11, to: monthCursor) {
            return (bounds(of: .month, containing: from).start, bounds(of: .month, containing: monthCursor).end)
        }
        return rangeStartEnd
    }

    private func moveCursor(_ delta: Int) {
        guard let newDate = Calendar.current.date(byAdding: mode == .year ? .year : .month, value: delta, to: monthCursor) else { return }
        monthCursor = newDate
        Task { await load() }
    }

    private func load() async {
        let (start, end) = rangeStartEnd
        summary = await store.statsSummary(start: start, end: end)
        store.overviewRange = (start, end, rangeLabel)
        if let prev = previousRange {
            previousSummary = await store.statsSummary(start: prev.start, end: prev.end)
        } else {
            previousSummary = nil
        }
        let chart = chartRange
        monthly = await store.statsMonthly(start: chart.start, end: chart.end)
        storeTotals = await store.statsByStore(start: start, end: end)
        // Drill-downs opened earlier belong to the old range.
        groupDetails = [:]
        for key in open {
            let parts = key.components(separatedBy: Self.keySeparator)
            if parts.count == 3 {
                Task { await loadGroupDetail(category: parts[0], subcategory: parts[1], itemGroup: parts[2], key: key) }
            }
        }
    }

    // MARK: Total

    private var totalBlock: some View {
        let total = summary?.total ?? 0
        return VStack(spacing: 2) {
            Text("Total:")
                .font(Theme.body(13, .medium))
                .foregroundStyle(Theme.label)
            Text(total > 0 ? fmtMoney(total) : "—")
                .font(Theme.mono(36, .semibold))
                .foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityIdentifier("overviewTotal")
            if total > 0, let delta = delta(current: total, previous: previousSummary?.total) {
                Text(delta.text)
                    .font(Theme.body(13, .medium))
                    .foregroundStyle(color(delta))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func delta(current: Double, previous: Double?) -> SpendDelta? {
        SpendDelta.make(current: current, previous: previous, hasComparison: previousSummary != nil, label: previousLabel)
    }

    private func color(_ delta: SpendDelta) -> Color {
        switch delta.trend {
        case .up: return Theme.red
        case .down: return Theme.greenText
        case .flat: return Theme.label
        }
    }

    /// Quiet, right under the total: flagged items are what makes "Other" bigger than it should be. Hidden with nothing to do.
    @ViewBuilder private var flaggedRow: some View {
        if store.flaggedItemCount > 0 {
            Button {
                path.append(.flagged)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkSoft)
                        .accessibilityHidden(true)
                    Text("Items without a category (\(store.flaggedItemCount))")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.rule, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flaggedItemsRow")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundStyle(Theme.label)
            Text("No spending in this period.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.label)
        }
        .padding(.top, monthly.isEmpty ? 50 : 16)
    }

    // MARK: Charts

    private static let otherName = SpendingSeries.otherName

    private func seriesColor(_ name: String, at index: Int) -> Color {
        name == Self.otherName ? Theme.seriesOther : Theme.series[index % Theme.series.count]
    }

    private var highlightMonth: String? {
        mode == .month ? String(ReceiptDateFormat.dateString(from: monthCursor).prefix(7)) : nil
    }

    private var monthlyCard: some View {
        let names = SpendingSeries.names(monthly)
        let months = Set(monthly.map(\.month)).count
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Spending by month")
            Chart(SpendingSeries.bars(monthly)) { bar in
                // One month alone would otherwise fill the whole chart.
                BarMark(x: .value("Month", bar.date, unit: .month), y: .value("€", bar.total), width: months == 1 ? .fixed(36) : .automatic)
                    .foregroundStyle(by: .value("Category", bar.category))
                    .opacity(highlightMonth == nil || highlightMonth == bar.month ? 1 : 0.45)
            }
            .chartForegroundStyleScale(domain: names, range: names.enumerated().map { seriesColor($0.element, at: $0.offset) })
            .chartXAxis {
                // Many months (a long custom range, all time) would not fit one letter each.
                if months <= 12 {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine().foregroundStyle(Theme.rule.opacity(0.4))
                        AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                            .foregroundStyle(Theme.inkSoft)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(Theme.rule.opacity(0.4))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.rule.opacity(0.6))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text("€\(Int(v))").font(Theme.mono(10)).foregroundStyle(Theme.inkSoft) }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 200)
            FlowLayout(spacing: 12) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(seriesColor(name, at: index)).frame(width: 10, height: 10)
                        Text(name).font(Theme.body(12)).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
        .paperCard()
    }

    private var storesCard: some View {
        let top = Array(storeTotals.prefix(8))
        let rest = storeTotals.dropFirst(8).reduce(0) { $0 + $1.total }
        let rows = rest > 0 ? top + [StoreTotal(store: Self.otherName, total: round2(rest))] : top
        let peak = rows.map(\.total).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "By store")
            VStack(spacing: 9) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.store).font(Theme.body(13.5)).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            Text(fmtMoney(row.total)).font(Theme.mono(13, .medium)).foregroundStyle(Theme.ink)
                        }
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row.store == Self.otherName ? Theme.seriesOther : Theme.series[2])
                                .frame(width: max(3, geometry.size.width * row.total / max(peak, 0.01)))
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: Tree

    private static let keySeparator = " >> "
    private func key(_ parts: String...) -> String { parts.joined(separator: Self.keySeparator) }

    private func tree(_ summary: StatsSummary) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(summary.categories.enumerated()), id: \.element.id) { index, category in
                categoryRows(category)
                if index < summary.categories.count - 1 { Rectangle().fill(Theme.rule).frame(height: 1) }
            }
        }
        .paperCard(padding: 4)
    }

    @ViewBuilder
    private func categoryRows(_ category: CategoryStat) -> some View {
        let prevCategory = previousSummary?.categories.first { $0.category == category.category }
        let categoryKey = key(category.category)
        treeRow(title: category.category, total: category.total, level: 0, key: categoryKey,
                delta: delta(current: category.total, previous: prevCategory?.total))
        if open.contains(categoryKey) {
            ForEach(category.subcategories) { sub in
                let subKey = key(category.category, sub.subcategory)
                let prevSub = prevCategory?.subcategories.first { $0.subcategory == sub.subcategory }
                treeRow(title: sub.subcategory, total: sub.total, level: 1, key: subKey,
                        delta: delta(current: sub.total, previous: prevSub?.total))
                if open.contains(subKey) {
                    ForEach(sub.itemGroups) { group in
                        let groupKey = key(category.category, sub.subcategory, group.itemGroup)
                        treeRow(title: group.itemGroup, total: group.total, level: 2, key: groupKey, delta: nil) {
                            if groupDetails[groupKey] == nil {
                                Task { await loadGroupDetail(category: category.category, subcategory: sub.subcategory, itemGroup: group.itemGroup, key: groupKey) }
                            }
                        }
                        if open.contains(groupKey) { drilldown(key: groupKey) }
                    }
                }
            }
        }
    }

    private func treeRow(title: String, total: Double, level: Int, key: String, delta: SpendDelta?, onOpen: @escaping () -> Void = {}) -> some View {
        let isOpen = open.contains(key)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isOpen { open.remove(key) } else { open.insert(key) }
            }
            if !isOpen { onOpen() }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 14, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(Theme.body(level == 0 ? 15.5 : level == 1 ? 14.5 : 14, level == 0 ? .semibold : .regular))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text(fmtMoney(total))
                            .font(Theme.mono(level == 0 ? 15 : 14, level == 0 ? .semibold : .regular))
                            .foregroundStyle(Theme.ink)
                    }
                    if let delta {
                        Text(delta.text).font(Theme.body(12)).foregroundStyle(color(delta))
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
    private func drilldown(key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let detail = groupDetails[key] {
                if let history = priceHistories[key], history.count >= 2 { priceHistory(history) }
                if detail.purchases.isEmpty {
                    Text("No purchases found.")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.vertical, 6)
                }
                VStack(spacing: 0) {
                    ForEach(Array(detail.purchases.enumerated()), id: \.offset) { index, purchase in
                        purchaseRow(purchase)
                        if index < detail.purchases.count - 1 { Rectangle().fill(Theme.rule.opacity(0.6)).frame(height: 1) }
                    }
                }
            } else if loadingGroups.contains(key) {
                Text("Loading…")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func priceHistory(_ points: [PricePoint]) -> some View {
        let names = Array(Set(points.map(\.item))).sorted()
        let colors = names.indices.map { Theme.series[$0 % Theme.series.count] }
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
                    AxisGridLine().foregroundStyle(Theme.rule.opacity(0.4))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Theme.inkSoft)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Theme.rule.opacity(0.6))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(fmtMoney(v)).font(Theme.mono(10)).foregroundStyle(Theme.inkSoft) }
                    }
                }
            }
            .frame(height: 140)
            FlowLayout(spacing: 12) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    HStack(spacing: 5) {
                        Circle().fill(colors[index]).frame(width: 8, height: 8)
                        Text(name).font(Theme.body(12)).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func purchaseRow(_ purchase: PurchaseRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(purchase.translationEn ?? purchase.nameDe ?? "")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(purchase.date ?? "") · \(purchase.store ?? "")")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Text(fmtMoney(purchase.totalPrice))
                .font(Theme.mono(13.5, .medium))
                .foregroundStyle(Theme.ink)
            Button("Edit") {
                path.append(.edit(EditTarget(receiptId: purchase.receiptId, itemDictionaryId: purchase.itemDictionaryId)))
            }
            .buttonStyle(OutlineButtonStyle())
            .fixedSize()
        }
        .padding(.vertical, 5)
    }

    private func loadGroupDetail(category: String, subcategory: String, itemGroup: String, key: String) async {
        loadingGroups.insert(key)
        let (start, end) = rangeStartEnd
        groupDetails[key] = await store.statsItemGroup(category: category, subcategory: subcategory, itemGroup: itemGroup, start: start, end: end)
        priceHistories[key] = await store.statsPriceHistory(category: category, subcategory: subcategory, itemGroup: itemGroup)
        loadingGroups.remove(key)
    }
}
