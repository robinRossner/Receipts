import SwiftUI

/// Ports renderReceipt() from dashboard.html: the "paper card" showing one receipt's store,
/// date/time, warnings, items (grouped + bracketed for repeats), an add-missing-item form,
/// totals, and the confirm button.
struct ReceiptDetailView: View {
    @EnvironmentObject var store: ReceiptStore
    let detail: ReceiptDetail

    @State private var dateText: String
    @State private var timeText: String
    @State private var dtSaving = false
    @State private var showAddForm: Bool
    @State private var addName = ""
    @State private var addQty = "1"
    @State private var addPrice = ""
    @State private var addError: String?
    @State private var addBusy = false

    init(detail: ReceiptDetail) {
        self.detail = detail
        _dateText = State(initialValue: detail.date ?? "")
        _timeText = State(initialValue: String((detail.time ?? "").prefix(5)))
        _showAddForm = State(initialValue: detail.hasSumMismatch)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if detail.needsReview && !detail.reviewReasons.isEmpty {
                    warningBanner
                }
                Rectangle().fill(AppTheme.rule).frame(height: 1).opacity(0.6)
                itemsSection
                addItemSection
                Rectangle().fill(AppTheme.rule).frame(height: 1).opacity(0.6)
                totalsFooter
            }
            .padding(32)
            .background(AppTheme.paper)
            .shadow(color: .black.opacity(0.14), radius: 20, y: 12)

            actions
        }
        .frame(maxWidth: 560)
        .onChange(of: store.highlightRequest) {
            guard let req = store.highlightRequest, req.receiptId == detail.id else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if store.highlightRequest?.token == req.token {
                    store.highlightRequest = nil
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Text(detail.store ?? "Unknown store")
                    .font(AppTheme.display(21))
                    .foregroundColor(AppTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .center)

                Button {
                    Task { await store.deleteReceipt(id: detail.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.inkSoft)
                        .frame(width: 24, height: 24)
                        .background(Circle().stroke(AppTheme.rule))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                TextField("YYYY-MM-DD", text: $dateText)
                    .frame(width: 100)
                TextField("HH:MM", text: $timeText)
                    .frame(width: 64)
                Button(dtSaving ? "Saving…" : "Save") {
                    Task {
                        dtSaving = true
                        await store.updateReceiptDateTime(id: detail.id, date: dateText, time: timeText)
                        dtSaving = false
                    }
                }
                .disabled(dtSaving)
            }
            .textFieldStyle(.roundedBorder)
            .font(AppTheme.mono(12))
        }
    }

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(detail.reviewReasons, id: \.self) { reason in
                Text("⚠ \(reason)")
            }
        }
        .font(AppTheme.body(13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.penRedBg)
        .foregroundColor(AppTheme.penRed)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.penRed))
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groupedItems, id: \.first!.itemDictionaryId) { group in
                let groupId = group.first!.itemDictionaryId
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                            ItemRowView(receiptId: detail.id, item: item)
                            if index < group.count - 1 {
                                Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
                            }
                        }
                    }
                    if group.count > 1 {
                        VStack {
                            Spacer()
                            Text("\(group.count)×")
                                .font(AppTheme.mono(12))
                                .foregroundColor(AppTheme.inkSoft)
                            Spacer()
                        }
                        .padding(.leading, 6)
                        .overlay(Rectangle().fill(AppTheme.inkSoft).frame(width: 1), alignment: .leading)
                    }
                }
                .id(groupId)
                .padding(isHighlighted(groupId) ? 8 : 0)
                .background(isHighlighted(groupId) ? AppTheme.penRedBg : Color.clear)
                .cornerRadius(4)
                .animation(.easeOut(duration: 1.2), value: store.highlightRequest)
            }
        }
    }

    private func isHighlighted(_ itemDictionaryId: Int) -> Bool {
        guard let req = store.highlightRequest else { return false }
        return req.receiptId == detail.id && req.itemDictionaryId == itemDictionaryId
    }

    private var groupedItems: [[LineItemDetail]] {
        var order: [Int] = []
        var groups: [Int: [LineItemDetail]] = [:]
        for item in detail.items {
            if groups[item.itemDictionaryId] == nil {
                order.append(item.itemDictionaryId)
                groups[item.itemDictionaryId] = []
            }
            groups[item.itemDictionaryId]!.append(item)
        }
        return order.map { groups[$0]! }
    }

    private var addItemSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(showAddForm ? "– Cancel" : "+ Add missing item") {
                showAddForm.toggle()
            }
            .buttonStyle(.plain)
            .font(AppTheme.body(12))
            .foregroundColor(AppTheme.inkSoft)

            if showAddForm {
                HStack(spacing: 6) {
                    TextField("Item name", text: $addName)
                    TextField("Qty", text: $addQty).frame(width: 60)
                    TextField("Price €", text: $addPrice).frame(width: 70)
                    Button(addBusy ? "Adding…" : "Add") {
                        Task { await addItem() }
                    }
                    .disabled(addBusy)
                }
                .textFieldStyle(.roundedBorder)
                .font(AppTheme.body(12))

                if let addError {
                    Text(addError).font(AppTheme.body(12)).foregroundColor(AppTheme.penRed)
                }
            }
        }
    }

    private func addItem() async {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let price = Double(addPrice) else {
            addError = "Enter an item name and a price."
            return
        }
        addError = nil
        addBusy = true
        let qty = Double(addQty) ?? 1
        await store.addItem(receiptId: detail.id, name: name, quantity: qty, unitPrice: price, rawText: nil)
        addName = ""; addPrice = ""; addQty = "1"
        addBusy = false
    }

    private var totalsFooter: some View {
        HStack {
            Text("Items total: \(fmtMoney(detail.computedSum))")
            Spacer()
            Text("Printed total: \(fmtMoney(detail.total))")
        }
        .font(AppTheme.mono(14))
        .foregroundColor(AppTheme.ink)
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button {
                Task { await store.confirmReceipt(id: detail.id) }
            } label: {
                Text(detail.reviewedAt != nil ? "Reviewed ✓" : "Looks good")
                    .font(AppTheme.body(14, weight: .semibold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 11)
                    .background(AppTheme.stampGreen.opacity(detail.reviewedAt != nil ? 0.55 : 1))
                    .foregroundColor(.white)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .disabled(detail.reviewedAt != nil)
            Spacer()
        }
        .padding(.vertical, 20)
    }
}
