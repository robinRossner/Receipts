import Charts
import LabCore
import SwiftUI

// MARK: The aisles: the Overview tab

struct AisleScreen: View {
    @Bindable var model: StoreModel
    static let drilldownAnchor = "drilldown"

    @State private var from = LabFormat.date("2026-09-30") ?? Date()
    @State private var to = LabFormat.date("2026-10-31") ?? Date()

    /// Twelve months up to and including the selected one. `model.monthIndex` is 0...11.
    private var months: [String] {
        Array(Set(LabData.monthly.map(\.month))).sorted()
    }

    private var selectedMonth: String { months[min(model.monthIndex, months.count - 1)] }

    private var monthLabel: String {
        guard let date = LabFormat.date(selectedMonth + "-01") else { return LabData.rangeLabel(.month) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private func monthTotal(_ month: String) -> Double {
        LabData.monthly.filter { $0.month == month }.reduce(0) { $0 + $1.total }
    }

    /// Scales the data to the shown month, so stepping the arrows stays consistent.
    private var factor: Double {
        guard model.range == .month, selectedMonth != LabData.highlightMonth else { return 1 }
        let base = LabData.summary(.month).total
        return base > 0 ? monthTotal(selectedMonth) / base : 1
    }

    private var summary: LabStatsSummary? {
        guard !model.overviewEmpty else { return nil }
        return Self.scale(LabData.summary(model.range), by: factor)
    }

    private var previous: LabStatsSummary? {
        guard let prev = LabData.previousSummary(model.range) else { return nil }
        if model.range == .month, selectedMonth != LabData.highlightMonth {
            let index = model.monthIndex
            guard index > 0, prev.total > 0 else { return nil }
            return Self.scale(prev, by: monthTotal(months[index - 1]) / prev.total)
        }
        return prev
    }

    private static func scale(_ s: LabStatsSummary, by k: Double) -> LabStatsSummary {
        guard k != 1 else { return s }
        var out = s
        out.total *= k
        for c in out.categories.indices {
            out.categories[c].total *= k
            for b in out.categories[c].subcategories.indices {
                out.categories[c].subcategories[b].total *= k
                for g in out.categories[c].subcategories[b].itemGroups.indices {
                    out.categories[c].subcategories[b].itemGroups[g].total *= k
                }
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HangingSign(title: "Overview", detail: "AISLE 2")
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    rangeRack
                    periodBar
                    DiscountSign(total: summary?.total)
                    if let summary {
                        StackedShelf(highlight: model.range == .month ? selectedMonth : nil, range: model.range)
                        StoreRail(totals: LabData.storeTotals(model.range).map { row in
                            var row = row
                            row.total *= factor
                            return row
                        })
                        AisleTree(model: model, summary: summary, previous: previous)
                    } else {
                        emptyAisle
                    }
                }
                .padding(.horizontal, ST.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .onAppear {
                // Opening at the drill-down shows it, not the top of the aisle.
                guard model.drilldownFixture else { return }
                model.drilldownFixture = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(Self.drilldownAnchor, anchor: .top) }
            }
            }
        }
        .background(SP.floor.ignoresSafeArea())
    }

    // MARK: Range and period

    private var rangeRack: some View {
        VStack(spacing: 0) {
            ShelfRail()
            HStack(spacing: 6) {
                ForEach(LabRange.allCases) { range in
                    ShelfTagButton(title: range.rawValue, selected: model.range == range, minWidth: 40) {
                        model.range = range
                        model.overviewEmpty = false
                    }
                }
            }
        }
    }

    @ViewBuilder private var periodBar: some View {
        HStack(spacing: 6) {
            switch model.range {
            case .month:
                IconKey(systemName: "chevron.left", label: "Previous month") { model.monthIndex = max(0, model.monthIndex - 1) }
                Text(monthLabel).periodLabel()
                IconKey(systemName: "chevron.right", label: "Next month") { model.monthIndex = min(months.count - 1, model.monthIndex + 1) }
            case .custom:
                labelledDate("From", $from)
                labelledDate("To", $to)
                Spacer(minLength: 0)
            case .year, .all:
                Text(LabData.rangeLabel(model.range)).periodLabel()
            }
            IconKey(systemName: "arrow.clockwise", label: "Refresh") {}
        }
    }

    private func labelledDate(_ label: String, _ selection: Binding<Date>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(SF.shelf(14)).foregroundStyle(SP.aisleText)
            DatePicker("", selection: selection, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(SP.pickerTint)
                .scaleEffect(0.86, anchor: .leading)
                .frame(width: 104, alignment: .leading)
        }
    }

    private var emptyAisle: some View {
        VStack(spacing: 16) {
            EmptyShelf()
            Text("No spending in this period.")
                .font(SF.shelf(17))
                .foregroundStyle(SP.aisleText)
            EmptyShelf()
        }
        .padding(.top, 14)
    }
}

private extension Text {
    func periodLabel() -> some View {
        font(SF.sign(24))
            .foregroundStyle(SP.aisleText)
            .padding(.top, 4)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Hanging sign

/// A navy sign on two wires from the ceiling.
struct HangingSign: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SP.wire.frame(width: 1.5, height: 10)
                Spacer()
                SP.wire.frame(width: 1.5, height: 10)
            }
            .padding(.horizontal, 54)
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(SF.sign(32))
                    .foregroundStyle(SP.signText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(detail)
                    .font(SF.sign(18))
                    .tracking(1)
                    .foregroundStyle(SP.signText2)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .background(SP.sign, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.horizontal, ST.gutter)
            .shadow(color: SP.sign.opacity(0.45), radius: 4, y: 2)
        }
        .padding(.bottom, 6)
    }
}

// MARK: Discount sign

/// The classic red-on-yellow price card, carrying the total.
private struct DiscountSign: View {
    let total: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Total:")
                .font(SF.sign(26))
                .foregroundStyle(SP.tagInk)
                .padding(.top, 6)
            Spacer(minLength: 4)
            Text(LabFormat.money(total))
                .font(SF.sign(52))
                .foregroundStyle(SP.tagRed)
                .padding(.top, 10)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
        .background(SP.tag)
        .overlay(Rectangle().inset(by: 3).strokeBorder(SP.tagRed, lineWidth: 2))
        .rotationEffect(.degrees(-0.5))
        .shadow(color: SP.shadow.opacity(0.25), radius: 3, y: 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shelf card

private struct ShelfCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(SF.sign(19))
                .tracking(0.6)
                .foregroundStyle(SP.aisleText)
                .padding(.top, 3)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(12)
        .background(SP.shelf)
        .overlay(alignment: .bottom) { ShelfRail() }
    }
}

// MARK: Spending by month: crates on a shelf

private struct StackedShelf: View {
    let highlight: String?
    let range: LabRange

    private let order = ["Food", "Household", "Personal Care", "Other"]
    private var months: [String] { Array(Set(LabData.monthly.map(\.month))).sorted() }

    private func total(_ month: String) -> Double {
        LabData.monthly.filter { $0.month == month }.reduce(0) { $0 + $1.total }
    }

    private var scaleMax: Double {
        let top = months.map(total).max() ?? 100
        return (top / 100).rounded(.up) * 100
    }

    var body: some View {
        ShelfCard(title: "SPENDING BY MONTH") {
            GeometryReader { geo in
                chart(in: geo.size)
            }
            .frame(height: 148)
            .accessibilityLabel("Spending by month, stacked by category")
            legend
        }
    }

    private func chart(in size: CGSize) -> some View {
        let axisW: CGFloat = 36
        let bottom: CGFloat = 18
        let h = size.height - bottom
        let w = size.width - axisW
        let slot = w / CGFloat(max(1, months.count))
        let labels = stride(from: 0.0, through: scaleMax, by: 100).map { $0 }
        return ZStack(alignment: .topLeading) {
            // Y labels and faint shelf lines
            ForEach(labels, id: \.self) { value in
                let y = h - CGFloat(value / scaleMax) * h
                if Int(value) % 200 == 0 {
                    Text("€\(Int(value))")
                        .font(SF.shelf(11))
                        .foregroundStyle(SP.aisleText2)
                        .frame(width: axisW - 4, alignment: .trailing)
                        .position(x: (axisW - 4) / 2, y: max(6, y))
                }
                SP.floorLine.frame(width: w, height: 1).offset(x: axisW, y: y)
            }
            // Crates
            ForEach(Array(months.enumerated()), id: \.element) { index, month in
                crateStack(month, width: max(6, slot - 5), height: h)
                    .opacity(highlight == nil || highlight == month ? 1 : 0.45)
                    .offset(x: axisW + CGFloat(index) * slot + 2.5, y: 0)
                Text(monthLetter(month))
                    .font(SF.shelf(11))
                    .foregroundStyle(highlight == month ? SP.aisleText : SP.aisleText2)
                    .frame(width: slot)
                    .offset(x: axisW + CGFloat(index) * slot, y: h + 5)
            }
            // The shelf board they stand on
            SP.rail.frame(width: w, height: 3).offset(x: axisW, y: h)
        }
    }

    private func monthLetter(_ month: String) -> String {
        let names = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
        guard let m = Int(month.suffix(2)) else { return "" }
        return names[(m - 1) % 12]
    }

    /// One month, drawn as stacked goods with a thin gap every €50, so height can be read like crates.
    private func crateStack(_ month: String, width: CGFloat, height: CGFloat) -> some View {
        let rows = LabData.monthly.filter { $0.month == month }
        return Canvas { context, size in
            var y = size.height
            let perEuro = size.height / CGFloat(scaleMax)
            for category in order {
                guard let row = rows.first(where: { $0.category == category }), row.total > 0 else { continue }
                let segment = CGFloat(row.total) * perEuro
                y -= segment
                let rect = CGRect(x: 0, y: y, width: size.width, height: max(1, segment - 0.75))
                context.fill(Path(rect), with: .color(SP.category(category)))
            }
            // Crate lines across the stack, every €50
            let top = y
            var line = size.height - 50 * perEuro
            while line > top {
                context.fill(Path(CGRect(x: 0, y: line, width: size.width, height: 0.75)), with: .color(SP.shelf.opacity(0.85)))
                line -= 50 * perEuro
            }
        }
        .frame(width: width, height: height)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(order, id: \.self) { category in
                HStack(spacing: 4) {
                    SP.category(category).frame(width: 10, height: 10)
                    Text(category)
                        .font(SF.shelf(12))
                        .foregroundStyle(SP.aisleText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 6)
    }
}

// MARK: By store: shelf-edge labels

private struct StoreRail: View {
    let totals: [LabStoreTotal]

    private var shown: [LabStoreTotal] {
        guard totals.count > 8 else { return totals }
        let rest = totals.dropFirst(8).reduce(0) { $0 + $1.total }
        var other = totals[8]
        other.store = "Other"
        other.total = rest
        return Array(totals.prefix(8)) + [other]
    }

    var body: some View {
        ShelfCard(title: "BY STORE") {
            let top = shown.map(\.total).max() ?? 1
            VStack(spacing: 5) {
                ForEach(shown) { row in
                    HStack(spacing: 0) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                SP.paperShade
                                SP.tag.frame(width: max(3, geo.size.width * CGFloat(row.total / top)))
                                Text(row.store)
                                    .font(SF.shelf(14))
                                    .foregroundStyle(SP.tagInk)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                            }
                        }
                        Text(LabFormat.money(row.total))
                            .font(SF.shelf(15))
                            .foregroundStyle(SP.tagInk)
                            .frame(width: 72, height: 28)
                            .background(SP.tagWhite)
                            .overlay(Rectangle().strokeBorder(SP.tagInk, lineWidth: 1))
                    }
                    .frame(height: 28)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// MARK: The tree: aisles, shelves, tags

private struct AisleTree: View {
    @Bindable var model: StoreModel
    let summary: LabStatsSummary
    let previous: LabStatsSummary?

    private var period: String { model.range == .year ? "last year" : "last month" }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(summary.categories.enumerated()), id: \.element.id) { index, category in
                aisle(category, number: index + 1)
            }
        }
    }

    private func isOpen(_ key: String) -> Bool { model.openNodes.contains(key) }

    private func toggle(_ key: String) {
        withAnimation(ST.unfold) {
            if model.openNodes.contains(key) { model.openNodes.remove(key) } else { model.openNodes.insert(key) }
        }
    }

    private func delta(_ now: Double, _ before: Double?) -> (String, Color)? {
        guard previous != nil else { return nil }
        guard let before, before > 0 else { return ("new vs \(period)", SP.up) }
        let pct = Int(((now - before) / before * 100).rounded())
        if pct == 0 { return ("±0% vs \(period)", SP.aisleText2) }
        return pct > 0 ? ("+\(pct)% vs \(period)", SP.up) : ("\(pct)% vs \(period)", SP.down)
    }

    // Level 1: the aisle sign

    private func aisle(_ category: LabCategoryStat, number: Int) -> some View {
        let key = category.category
        let before = previous?.categories.first { $0.category == key }?.total
        let d = delta(category.total, before)
        return VStack(spacing: 0) {
            Button { toggle(key) } label: {
                HStack(spacing: 10) {
                    Text("\(number)")
                        .font(SF.sign(24))
                        .foregroundStyle(SP.sign)
                        .padding(.top, 5)
                        .frame(width: 30, height: 30)
                        .background(SP.signText, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(category.category)
                            .font(SF.sign(22))
                            .foregroundStyle(SP.signText)
                            .padding(.top, 3)
                        if let d {
                            Text(d.0)
                                .font(SF.shelf(12))
                                .foregroundStyle(SP.signText2)
                        }
                    }
                    Spacer()
                    Text(LabFormat.money(category.total))
                        .font(SF.shelf(18))
                        .foregroundStyle(SP.tagInk)
                        .padding(.horizontal, 7)
                        .frame(height: 30)
                        .background(SP.tag)
                    Image(systemName: isOpen(key) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SP.signText)
                        .frame(width: 14)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 52)
                .background(SP.sign, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen(key) {
                VStack(spacing: 0) {
                    ForEach(category.subcategories) { sub in shelf(sub, category: category.category) }
                }
                .padding(.top, 4)
            }
        }
    }

    // Level 2: a shelf

    private func shelf(_ sub: LabSubcategoryStat, category: String) -> some View {
        let key = category + "|" + sub.subcategory
        let before = previous?.categories.first { $0.category == category }?
            .subcategories.first { $0.subcategory == sub.subcategory }?.total
        let d = delta(sub.total, before)
        return VStack(spacing: 0) {
            Button { toggle(key) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen(key) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SP.aisleText2)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sub.subcategory)
                            .font(SF.shelf(16))
                            .foregroundStyle(SP.aisleText)
                        if let d {
                            Text(d.0).font(SF.shelf(12)).foregroundStyle(d.1)
                        }
                    }
                    Spacer()
                    Text(LabFormat.money(sub.total))
                        .font(SF.shelf(16))
                        .foregroundStyle(SP.aisleText)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 48)
                .background(SP.shelf)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SP.shelfEdge.frame(height: 1.5)

            if isOpen(key) {
                VStack(spacing: 0) {
                    ForEach(sub.itemGroups) { group in tag(group, category: category, sub: sub.subcategory) }
                }
                .padding(.leading, 14)
                .background(SP.floor)
            }
        }
    }

    // Level 3: a tag

    private func tag(_ group: LabItemGroupStat, category: String, sub: String) -> some View {
        let key = category + "|" + sub + "|" + group.itemGroup
        return VStack(spacing: 0) {
            Button { toggle(key) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen(key) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SP.aisleText2)
                        .frame(width: 14)
                    Text(group.itemGroup)
                        .font(SF.shelf(15))
                        .foregroundStyle(SP.aisleText)
                        .lineLimit(2)
                    Spacer()
                    Text(LabFormat.money(group.total))
                        .font(SF.shelf(14))
                        .foregroundStyle(SP.tagInk)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .background(SP.tagWhite)
                        .overlay(Rectangle().strokeBorder(SP.tagInk.opacity(0.7), lineWidth: 0.75))
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SP.floorLine.frame(height: 1)
            if isOpen(key) {
                Drilldown(model: model, category: category, subcategory: sub, itemGroup: group.itemGroup)
                    .padding(.vertical, 8)
                    .padding(.trailing, 2)
                    .id(AisleScreen.drilldownAnchor)
            }
        }
    }
}

// MARK: Drill-down: a coupon, and the purchase tags

private struct Drilldown: View {
    @Bindable var model: StoreModel
    let category: String
    let subcategory: String
    let itemGroup: String

    private var history: [LabPricePoint] {
        LabData.priceHistory(category: category, subcategory: subcategory, itemGroup: itemGroup)
    }

    private var purchases: [LabPurchaseRow] {
        LabData.purchases(category: category, subcategory: subcategory, itemGroup: itemGroup, range: model.range)
    }

    private var items: [String] {
        var seen: [String] = []
        for point in history where !seen.contains(point.item) { seen.append(point.item) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.count >= 2 { coupon }
            if purchases.isEmpty {
                Text("No purchases found.")
                    .font(SF.shelf(14))
                    .foregroundStyle(SP.aisleText2)
                    .padding(.vertical, 8)
            }
            ForEach(purchases) { purchase in row(purchase) }
        }
    }

    private var coupon: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRICE HISTORY (unit price, all time)")
                .font(SF.shelf(13))
                .foregroundStyle(SP.ink)
            Chart(history) { point in
                LineMark(x: .value("Date", point.date), y: .value("Unit price", point.unitPrice), series: .value("Item", point.item))
                    .foregroundStyle(color(point.item))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Date", point.date), y: .value("Unit price", point.unitPrice))
                    .foregroundStyle(color(point.item))
                    .symbolSize(22)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(SP.rule.opacity(0.35))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(SP.ink2).font(SF.shelf(11))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(SP.rule.opacity(0.35))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(LabFormat.money(v)).foregroundStyle(SP.ink2).font(SF.shelf(11))
                        }
                    }
                }
            }
            .frame(height: 118)
            .environment(\.colorScheme, .light)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        color(item).frame(width: 12, height: 3)
                        Text(item).font(SF.shelf(12)).foregroundStyle(SP.ink)
                    }
                }
            }
        }
        .padding(10)
        .background(SP.paper)
        .overlay(Rectangle().strokeBorder(SP.ink, style: StrokeStyle(lineWidth: 1.25, dash: [6, 4])))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "scissors")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SP.ink)
                .padding(2)
                .background(SP.paper)
                .offset(x: -14, y: -9)
                .accessibilityHidden(true)
        }
    }

    private func color(_ item: String) -> Color {
        let palette = [SP.printRed, Color(red: 0.18, green: 0.42, blue: 0.66), SP.printGreen, Color(red: 0.54, green: 0.42, blue: 0)]
        return palette[(items.firstIndex(of: item) ?? 0) % palette.count]
    }

    private func row(_ purchase: LabPurchaseRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(purchase.translationEn ?? purchase.nameDe ?? "—")
                    .font(SF.shelf(14))
                    .foregroundStyle(SP.aisleText)
                    .lineLimit(1)
                Text("\(purchase.date ?? "—")  \(purchase.store ?? "Unknown")")
                    .font(SF.print(11))
                    .foregroundStyle(SP.aisleText2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(LabFormat.money(purchase.totalPrice))
                .font(SF.shelf(15))
                .foregroundStyle(SP.aisleText)
            Button("Edit") { model.open(purchase.receiptId, expanding: purchase.lineItemId) }
                .buttonStyle(KeycapStyle(font: SF.shelf(14)))
                .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .background(SP.shelf)
    }
}
