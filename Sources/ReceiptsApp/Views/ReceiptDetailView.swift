import SwiftUI

/// Ports renderReceipt() from dashboard.html: the "paper card" showing one receipt's store,
/// date/time, warnings, items (grouped + bracketed for repeats), an add-missing-item form,
/// totals, and the confirm button.
struct ReceiptDetailView: View {
    @EnvironmentObject var store: ReceiptStore
    let detail: ReceiptDetail

    @AppStorage("showReceiptPhoto") private var showPhoto = true
    @State private var storeText: String
    @State private var totalValue: Double?
    @State private var dateValue: Date?
    @State private var timeValue: Date?
    @FocusState private var totalFocused: Bool
    @State private var showAddForm: Bool
    @State private var addName = ""
    @State private var addQty = "1"
    @State private var addPrice = ""
    @State private var addError: String?
    @State private var addBusy = false
    @State private var confirmRerun = false
    @State private var confirmRecategorize = false

    /// Below this pane width the photo hides itself (use the toggle to bring it back when wider).
    private let photoMinPaneWidth: CGFloat = 760

    init(detail: ReceiptDetail) {
        self.detail = detail
        _storeText = State(initialValue: detail.store ?? "")
        _totalValue = State(initialValue: detail.total)
        _dateValue = State(initialValue: ReceiptDateFormat.date(from: detail.date))
        _timeValue = State(initialValue: ReceiptDateFormat.time(from: detail.time))
        _showAddForm = State(initialValue: detail.hasSumMismatch)
    }

    private var isBusy: Bool { store.busyReceiptIDs.contains(detail.id) }

    var body: some View {
        GeometryReader { geo in
            if showPhoto && geo.size.width >= photoMinPaneWidth {
                HSplitView {
                    ReceiptPhotoView(path: detail.sourceImage, note: detail.photoNote)
                        .frame(minWidth: 220, idealWidth: 340, maxWidth: .infinity)
                    receiptColumn
                        .frame(minWidth: 400, idealWidth: 520, maxWidth: .infinity)
                }
            } else {
                receiptColumn
            }
        }
    }

    private var receiptColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let processing = detail.processing {
                            ReceiptProcessingPanel(detail: detail, processing: processing)
                        }
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
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .disabled(isBusy)
                    .overlay {
                        if isBusy {
                            ProgressView("Working…")
                                .padding(20)
                                .background(AppTheme.paper)
                                .cornerRadius(4)
                                .shadow(radius: 8)
                        }
                    }
                }
                .onChange(of: store.highlightRequest) {
                    guard let req = store.highlightRequest, req.receiptId == detail.id else { return }
                    withAnimation { proxy.scrollTo(req.itemDictionaryId, anchor: .center) }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        if store.highlightRequest?.token == req.token {
                            store.highlightRequest = nil
                        }
                    }
                }
            }
            Rectangle().fill(AppTheme.rule).frame(height: 1)
            actions
        }
        .background(AppTheme.desk)
        .onChange(of: detail.store) { storeText = detail.store ?? "" }
        .onChange(of: detail.total) { totalValue = detail.total }
        .onChange(of: detail.date) { dateValue = ReceiptDateFormat.date(from: detail.date) }
        .onChange(of: detail.time) { timeValue = ReceiptDateFormat.time(from: detail.time) }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                StoreNameField(
                    text: $storeText,
                    suggestions: store.knownStores,
                    onCommit: commitStore
                )
                .frame(maxWidth: .infinity)

                Button {
                    store.deleteConfirmationPresented = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.inkSoft)
                        .frame(width: 24, height: 24)
                        .background(Circle().stroke(AppTheme.rule))
                }
                .buttonStyle(.plain)
                .help("Delete receipt (⌘⌫)")
                .confirmationDialog("Delete this receipt?", isPresented: $store.deleteConfirmationPresented) {
                    Button("Delete", role: .destructive) {
                        Task { await store.deleteReceipt(id: detail.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("It moves to \"Recently deleted\" and can be restored from there.")
                }
            }

            HStack(spacing: 8) {
                if dateValue != nil {
                    DatePicker("", selection: Binding(get: { dateValue ?? Date() }, set: { dateValue = $0 }), displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                } else {
                    Button("Set date") { dateValue = Date() }
                }
                if timeValue != nil {
                    DatePicker("", selection: Binding(get: { timeValue ?? Date() }, set: { timeValue = $0 }), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .labelsHidden()
                    Button {
                        timeValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .help("Clear time")
                } else {
                    Button("+ Add time") { timeValue = Date() }
                }
            }
            .font(AppTheme.mono(12))
            .onChange(of: dateValue) { saveDateTime() }
            .onChange(of: timeValue) { saveDateTime() }
        }
    }

    private func commitStore() {
        let trimmed = storeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { storeText = detail.store ?? ""; return }
        guard trimmed != detail.store else { return }
        Task { await store.updateReceiptStore(id: detail.id, store: trimmed) }
    }

    private func commitTotal() {
        guard totalValue != detail.total else { return }
        Task { await store.updateReceiptTotal(id: detail.id, total: totalValue) }
    }

    private func saveDateTime() {
        guard let dateValue else { return }
        let date = ReceiptDateFormat.dateString(from: dateValue)
        let time = timeValue.map(ReceiptDateFormat.timeString(from:))
        guard date != detail.date || time != detail.time.map({ String($0.prefix(5)) }) else { return }
        Task { await store.updateReceiptDateTime(id: detail.id, date: date, time: time) }
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
            HStack(spacing: 6) {
                Text("Printed total:")
                TextField("Total", value: $totalValue, format: .currency(code: "EUR"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .focused($totalFocused)
                    .onSubmit(commitTotal)
                    .onChange(of: totalFocused) { if !totalFocused { commitTotal() } }
            }
        }
        .font(AppTheme.mono(14))
        .foregroundColor(AppTheme.ink)
    }

    private var actions: some View {
        HStack {
            Button {
                showPhoto.toggle()
            } label: {
                Label(showPhoto ? "Hide photo" : "Show photo", systemImage: "photo")
                    .font(AppTheme.body(12))
            }
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.inkSoft)
            .help("Show the archived photo beside the items (needs a wide window)")

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
            .disabled(detail.reviewedAt != nil || isBusy)
            .help("Confirm (⌘↩)")
            Spacer()

            Menu {
                Button("Re-run extraction…") { confirmRerun = true }
                Button("Re-categorize items…") { confirmRecategorize = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy)
            .help("More actions")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(AppTheme.paper)
        .confirmationDialog("Re-run extraction?", isPresented: $confirmRerun) {
            Button("Re-run extraction", role: .destructive) {
                Task { await store.rerunExtraction(id: detail.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The archived photo is read again with the current AI provider. This replaces the store, date, total and all line items (including your edits) and marks the receipt as not yet reviewed.")
        }
        .confirmationDialog("Re-categorize items?", isPresented: $confirmRecategorize) {
            Button("Re-categorize") {
                Task { await store.recategorizeItems(id: detail.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items you categorized by hand are kept. The rest are classified again; since categories live in the shared dictionary, other receipts with the same items change too.")
        }
    }
}

/// Store name as an editable title with suggestions (known chains + stores already in use)
/// listed under the field while it's focused.
private struct StoreNameField: View {
    @Binding var text: String
    let suggestions: [String]
    let onCommit: () -> Void
    @FocusState private var focused: Bool

    private var matches: [String] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        return suggestions.filter { $0.lowercased() != q && (q.isEmpty || $0.lowercased().contains(q)) }.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(spacing: 4) {
            TextField("Store", text: $text)
                .textFieldStyle(.plain)
                .font(AppTheme.display(21))
                .foregroundColor(AppTheme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .focused($focused)
                .onSubmit(onCommit)
                .onChange(of: focused) { if !focused { onCommit() } }
            Rectangle().fill(focused ? AppTheme.ink : AppTheme.rule).frame(height: 1).padding(.horizontal, 32)
            if focused && !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.self) { name in
                        Button {
                            text = name
                            onCommit()
                            focused = false
                        } label: {
                            Text(name)
                                .font(AppTheme.body(12))
                                .foregroundColor(AppTheme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(AppTheme.paper)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
                .cornerRadius(4)
                .frame(maxWidth: 260)
            }
        }
    }
}
