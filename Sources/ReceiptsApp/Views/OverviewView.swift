import SwiftUI

/// Ports #overviewPage from dashboard.html: a month navigator, a running total, and an
/// expandable category > subcategory > item_group spending tree with a lazy-loaded purchase
/// drill-down per item group.
struct OverviewView: View {
    @EnvironmentObject var store: ReceiptStore
    let isActive: Bool

    enum RangeMode: String, CaseIterable, Identifiable {
        case month = "Month", year = "Year", custom = "Custom", all = "All time"
        var id: String { rawValue }
    }

    @State private var mode: RangeMode = .month
    /// Month or year being shown (cursor arrows move it).
    @State private var monthCursor = Date()
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var summary: StatsSummary?
    @State private var previousSummary: StatsSummary?
    @State private var monthly: [MonthCategoryTotal] = []
    @State private var storeTotals: [StoreTotal] = []
    @State private var priceHistories: [String: [PricePoint]] = [:]

    // Persists for the life of the view (i.e. the whole app session, since OverviewView is
    // never torn down - just hidden) - mirrors the `openNodes` Set in dashboard.html, which is
    // explicitly "in-memory state" that survives a refresh but not a full reload.
    @State private var openCategories: Set<String> = []
    @State private var openSubcategories: Set<String> = []
    @State private var openItemGroups: Set<String> = []
    @State private var groupDetails: [String: ItemGroupDetail] = [:]
    @State private var loadingGroups: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                Text("Total: \(fmtMoney(summary?.total))")
                    .font(AppTheme.mono(22))
                    .foregroundColor(AppTheme.ink)
                SpendingChartsView(
                    monthly: monthly, stores: storeTotals,
                    highlightMonth: mode == .month ? Self.monthKey(monthCursor) : nil
                )
                categoryTree
            }
            .padding(40)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.desk)
        .onChange(of: isActive) {
            // Always refetch on becoming visible - an item may have just been corrected on
            // the Review page, same reasoning as switchToPage('overview') in dashboard.html.
            if isActive { Task { await load() } }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Picker("Range", selection: $mode) {
                ForEach(RangeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            HStack(spacing: 10) {
                switch mode {
                case .month, .year:
                    navButton("‹") { moveCursor(-1) }
                    Text(rangeLabel)
                        .font(AppTheme.display(17))
                        .frame(minWidth: 150)
                        .multilineTextAlignment(.center)
                    navButton("›") { moveCursor(1) }
                case .custom:
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                case .all:
                    Text("All time").font(AppTheme.display(17))
                }
                navButton("⟳") { store.invalidateStatsCache(); Task { await load() } }
                Button {
                    store.exportSheetPresented = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up").font(AppTheme.body(12))
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.inkSoft)
            }
        }
        .onChange(of: mode) { Task { await load() } }
        .onChange(of: customStart) { if mode == .custom { Task { await load() } } }
        .onChange(of: customEnd) { if mode == .custom { Task { await load() } } }
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(AppTheme.body(15))
                .frame(width: 30, height: 30)
                .background(AppTheme.paper)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
                .cornerRadius(4)
                .foregroundColor(AppTheme.ink)
        }
        .buttonStyle(.plain)
    }

    private var rangeLabel: String {
        switch mode {
        case .all: return "All time"
        case .custom: return "\(ReceiptDateFormat.dateString(from: customStart)) – \(ReceiptDateFormat.dateString(from: customEnd))"
        case .year:
            let f = DateFormatter(); f.dateFormat = "yyyy"
            return f.string(from: monthCursor)
        case .month:
            let f = DateFormatter(); f.dateFormat = "LLLL yyyy"
            return f.string(from: monthCursor)
        }
    }

    static func monthKey(_ d: Date) -> String { String(ReceiptDateFormat.dateString(from: d).prefix(7)) }

    private func bounds(of component: Calendar.Component, containing date: Date) -> (start: String, end: String) {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: component, for: date) else {
            let d = ReceiptDateFormat.dateString(from: date); return (d, d)
        }
        let last = interval.end.addingTimeInterval(-1)
        return (ReceiptDateFormat.dateString(from: interval.start), ReceiptDateFormat.dateString(from: last))
    }

    /// First/last day of the selected range, "yyyy-MM-dd"; nil/nil = all time.
    private var rangeStartEnd: (start: String?, end: String?) {
        switch mode {
        case .all: return (nil, nil)
        case .custom:
            let a = ReceiptDateFormat.dateString(from: min(customStart, customEnd))
            let b = ReceiptDateFormat.dateString(from: max(customStart, customEnd))
            return (a, b)
        case .month: let b = bounds(of: .month, containing: monthCursor); return (b.start, b.end)
        case .year: let b = bounds(of: .year, containing: monthCursor); return (b.start, b.end)
        }
    }

    /// The period right before the selected one (month/year only), for "vs last month" deltas.
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
        for key in openItemGroups {
            let parts = key.components(separatedBy: " >> ")
            if parts.count == 3 {
                Task { await loadGroupDetail(category: parts[0], subcategory: parts[1], itemGroup: parts[2], key: key) }
            }
        }
    }

    /// "+12% vs last month"; nil when there is no comparison period.
    private func deltaText(current: Double, previous: Double?) -> String? {
        guard previousSummary != nil, let previous else { return previousSummary == nil ? nil : "new vs \(previousLabel)" }
        guard previous > 0 else { return current > 0 ? "new vs \(previousLabel)" : nil }
        let pct = (current - previous) / previous * 100
        guard abs(pct) >= 0.5 else { return "±0% vs \(previousLabel)" }
        return String(format: "%+.0f%% vs %@", pct, previousLabel)
    }

    private func deltaColor(current: Double, previous: Double?) -> Color {
        guard let previous, previous > 0 else { return AppTheme.inkSoft }
        return current > previous ? AppTheme.penRed : (current < previous ? AppTheme.stampGreen : AppTheme.inkSoft)
    }

    @ViewBuilder
    private var categoryTree: some View {
        if let summary, !summary.categories.isEmpty {
            VStack(spacing: 2) {
                ForEach(summary.categories) { cat in categoryNode(cat) }
            }
        } else {
            Text("No spending in this period.")
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.inkSoft)
        }
    }

    private func categoryNode(_ cat: CategoryStat) -> some View {
        let isOpen = openCategories.contains(cat.category)
        return VStack(spacing: 2) {
            treeRow(label: cat.category, total: cat.total, depth: 0, isOpen: isOpen,
                    previous: previousSummary?.categories.first { $0.category == cat.category }?.total) {
                toggle(&openCategories, cat.category)
            }
            if isOpen {
                VStack(spacing: 2) {
                    ForEach(cat.subcategories) { sub in subcategoryNode(category: cat.category, sub: sub) }
                }
            }
        }
    }

    private func subcategoryNode(category: String, sub: SubcategoryStat) -> some View {
        let key = nodeKey(category, sub.subcategory)
        let isOpen = openSubcategories.contains(key)
        return VStack(spacing: 2) {
            treeRow(label: sub.subcategory, total: sub.total, depth: 1, isOpen: isOpen,
                    previous: previousSummary?.categories.first { $0.category == category }?.subcategories.first { $0.subcategory == sub.subcategory }?.total) {
                toggle(&openSubcategories, key)
            }
            if isOpen {
                VStack(spacing: 2) {
                    ForEach(sub.itemGroups) { ig in itemGroupNode(category: category, subcategory: sub.subcategory, ig: ig) }
                }
            }
        }
    }

    private func itemGroupNode(category: String, subcategory: String, ig: ItemGroupStat) -> some View {
        let key = nodeKey(category, subcategory, ig.itemGroup)
        let isOpen = openItemGroups.contains(key)
        return VStack(spacing: 2) {
            treeRow(label: ig.itemGroup, total: ig.total, depth: 2, isOpen: isOpen) {
                let willOpen = !openItemGroups.contains(key)
                toggle(&openItemGroups, key)
                if willOpen && groupDetails[key] == nil {
                    Task { await loadGroupDetail(category: category, subcategory: subcategory, itemGroup: ig.itemGroup, key: key) }
                }
            }
            if isOpen {
                purchaseDetail(key: key)
            }
        }
    }

    @ViewBuilder
    private func purchaseDetail(key: String) -> some View {
        Group {
            if loadingGroups.contains(key) {
                Text("Loading…")
                    .font(AppTheme.body(13)).foregroundColor(AppTheme.inkSoft)
            } else if let detail = groupDetails[key] {
                if detail.purchases.isEmpty {
                    Text("No purchases found.")
                        .font(AppTheme.body(13)).foregroundColor(AppTheme.inkSoft)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let history = priceHistories[key], Set(history.map(\.item)).count > 0, history.count > 1 {
                            PriceHistoryChart(points: history)
                        }
                        ForEach(detail.purchases) { purchaseRow($0) }
                    }
                    .padding(10)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AppTheme.rule, style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
            }
        }
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func purchaseRow(_ p: PurchaseRow) -> some View {
        HStack(spacing: 8) {
            Text(p.date ?? "").font(AppTheme.mono(12)).frame(width: 84, alignment: .leading)
            Text(p.store ?? "").font(AppTheme.body(12)).foregroundColor(AppTheme.inkSoft).frame(minWidth: 60, alignment: .leading)
            Text(p.translationEn ?? p.nameDe ?? "").font(AppTheme.body(12)).frame(maxWidth: .infinity, alignment: .leading)
            Text(fmtMoney(p.totalPrice)).font(AppTheme.mono(12)).frame(width: 70, alignment: .trailing)
            Button("Edit") {
                Task { await store.jumpToItem(receiptId: p.receiptId, itemDictionaryId: p.itemDictionaryId) }
            }
            .font(AppTheme.body(11))
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.inkSoft)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(AppTheme.rule, lineWidth: 1))
        }
        .padding(.vertical, 4)
    }

    private func treeRow(label: String, total: Double, depth: Int, isOpen: Bool, previous: Double? = nil, action: @escaping () -> Void) -> some View {
        let rowBackground: Color = depth == 0 ? AppTheme.paper : (depth == 1 ? Color(hex: 0xFBF8F1) : .white)
        return Button(action: action) {
            HStack {
                Text(isOpen ? "▾" : "▸")
                    .frame(width: 12)
                    .foregroundColor(AppTheme.inkSoft)
                Text(label)
                    .font(AppTheme.body(depth == 0 ? 14 : 13))
                Spacer()
                if depth < 2, let delta = deltaText(current: total, previous: previous) {
                    Text(delta)
                        .font(AppTheme.body(11))
                        .foregroundColor(deltaColor(current: total, previous: previous))
                }
                Text(fmtMoney(total))
                    .font(AppTheme.mono(depth == 0 ? 14 : 13))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .padding(.leading, CGFloat(depth) * 20)
            .background(rowBackground)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
            .cornerRadius(4)
            .foregroundColor(AppTheme.ink)
        }
        .buttonStyle(.plain)
    }

    private func nodeKey(_ parts: String...) -> String { parts.joined(separator: " >> ") }

    private func toggle(_ set: inout Set<String>, _ key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }

    private func loadGroupDetail(category: String, subcategory: String, itemGroup: String, key: String) async {
        loadingGroups.insert(key)
        let (start, end) = rangeStartEnd
        let detail = await store.statsItemGroup(category: category, subcategory: subcategory, itemGroup: itemGroup, start: start, end: end)
        groupDetails[key] = detail
        priceHistories[key] = await store.statsPriceHistory(category: category, subcategory: subcategory, itemGroup: itemGroup)
        loadingGroups.remove(key)
    }
}
