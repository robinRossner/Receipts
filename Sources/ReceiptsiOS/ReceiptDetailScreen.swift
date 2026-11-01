import SwiftUI

/// One receipt in a navigation screen. "Looks good" confirms and moves on to the next receipt to review, in place; with
/// nothing left it goes back to where it came from. `highlightDictionaryId`: the Overview's `Edit`, opens that item.
struct ReceiptDetailScreen: View {
    let id: Int
    var highlightDictionaryId: Int?
    @EnvironmentObject var store: ReceiptStore
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let detail = store.selectedReceipt {
                DetailContent(detail: detail, close: { dismiss() })
                    .id(detail.id)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.desk)
        .navigationTitle(loaded ? (store.selectedReceipt?.store ?? "Receipt") : "Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)   // room for the items and the confirm bar
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(loaded ? (store.selectedReceipt?.store ?? "Receipt") : "Receipt")
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
        .task {
            if let highlightDictionaryId {
                await store.jumpToItem(receiptId: id, itemDictionaryId: highlightDictionaryId)
            } else {
                await store.loadReceiptDetail(id: id)
            }
            loaded = true
            if store.selectedReceipt == nil { dismiss() }   // it no longer exists
        }
        .onChange(of: store.selectedReceipt?.id) {
            // Deleted (or gone after a sync): back to the list.
            if loaded, store.selectedReceipt == nil { dismiss() }
        }
    }
}

private struct DetailContent: View {
    @EnvironmentObject var store: ReceiptStore
    @EnvironmentObject private var snacks: SnackCenter
    let detail: ReceiptDetail
    let close: () -> Void

    @State private var photoTab = false
    @State private var storeText: String
    @State private var totalText: String
    @State private var dateValue: Date?
    @State private var timeValue: Date?
    @State private var datePickerOpen = false
    @State private var timePickerOpen = false
    @State private var showAddForm: Bool
    @State private var addName = ""
    @State private var addQty = "1"
    @State private var addPrice = ""
    @State private var addError: String?
    @State private var addBusy = false
    @State private var confirmDelete = false
    @State private var confirmRerun = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case store, total, addName, addQty, addPrice }

    init(detail: ReceiptDetail, close: @escaping () -> Void) {
        self.detail = detail
        self.close = close
        _storeText = State(initialValue: detail.store ?? "")
        _totalText = State(initialValue: Self.totalString(detail.total))
        _dateValue = State(initialValue: ReceiptDateFormat.date(from: detail.date))
        _timeValue = State(initialValue: ReceiptDateFormat.time(from: detail.time))
        _showAddForm = State(initialValue: detail.hasSumMismatch)
    }

    private static func totalString(_ total: Double?) -> String { total.map { String(format: "%.2f", $0) } ?? "" }

    private var isBusy: Bool { store.busyReceiptIDs.contains(detail.id) }
    private var isStillReading: Bool { detail.processing?.isActive == true }
    /// A failed download only says something about a photo the server should have.
    private var photoNote: String? {
        (detail.photoLocation == "server" ? store.photoFetchNotes[detail.id] : nil) ?? detail.photoNote
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $photoTab) {
                Text("Items").tag(false)
                Text("Photo").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Group {
                if photoTab {
                    ReceiptPhotoView(path: detail.sourceImage, note: photoNote)
                } else {
                    itemsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let snack = snacks.current {
                SnackbarView(snack: snack, undo: snacks.performUndo)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            actionBar
        }
        .background(Theme.desk)
        .task(id: detail.id) { await store.ensureLocalPhoto(id: detail.id) }
        .onChange(of: detail.store) { storeText = detail.store ?? "" }
        .onChange(of: detail.total) { if focus != .total { totalText = Self.totalString(detail.total) } }
        .onChange(of: detail.date) { dateValue = ReceiptDateFormat.date(from: detail.date) }
        .onChange(of: detail.time) { timeValue = ReceiptDateFormat.time(from: detail.time) }
        .confirmationDialog("Delete this receipt?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteReceipt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to \"Recently deleted\" and can be restored from there.")
        }
        .confirmationDialog("Re-run extraction?", isPresented: $confirmRerun, titleVisibility: .visible) {
            Button("Re-run extraction", role: .destructive) { Task { await store.rerunExtraction(id: detail.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server reads the photo again and marks the receipt as not yet reviewed. If you already edited or confirmed this receipt, the server keeps your version.")
        }
    }

    private func deleteReceipt() {
        let id = detail.id
        Task {
            await store.deleteReceipt(id: id)   // clears the selection, which takes this screen away
            snacks.show("Moved to Recently deleted") { await store.restoreReceipt(id: id) }
        }
    }

    // MARK: Items tab

    private var itemsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let processing = detail.processing { processingPanel(processing) }
                    header
                    if detail.needsReview && !detail.reviewReasons.isEmpty { warnings }
                    if !detail.items.isEmpty { itemsSection }
                    addSection
                    footer
                }
                .paperCard()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .disabled(isBusy)
                .opacity(isBusy ? 0.45 : 1)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if isBusy { busyBox }
            }
            .task {
                // The Overview's `Edit`: scroll to the item and let its tint fade.
                guard let request = store.highlightRequest, request.receiptId == detail.id else { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation { proxy.scrollTo(request.itemDictionaryId, anchor: .center) }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if store.highlightRequest?.token == request.token { store.highlightRequest = nil }
            }
        }
    }

    private var busyBox: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Working…").font(Theme.body(15, .medium)).foregroundStyle(Theme.ink)
        }
        .paperCard(padding: 18)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    TextField("Store", text: $storeText)
                        .font(Theme.display(24))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .focused($focus, equals: .store)
                        .submitLabel(.done)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 44)
                        .onSubmit { focus = nil }
                        .onChange(of: focus) { old, _ in
                            if old == .store { commitStore() }
                            if old == .total { commitTotal() }
                        }
                    if focus == .store { suggestions }
                }
                IconButton(systemName: "trash", label: "Delete receipt", size: 15) { confirmDelete = true }
                    .padding(.trailing, -8)
            }
            HStack(spacing: 8) {
                if let dateValue {
                    pickerPill(ReceiptDateFormat.dateString(from: dateValue), label: "Date", isOpen: $datePickerOpen) {
                        DatePicker("Date", selection: Binding(get: { self.dateValue ?? Date() }, set: { self.dateValue = $0; datePickerOpen = false }), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .frame(width: 320)
                    }
                } else {
                    Button("Set date") { dateValue = Date() }
                        .buttonStyle(OutlineButtonStyle())
                }
                if let timeValue {
                    pickerPill(ReceiptDateFormat.timeString(from: timeValue), label: "Time", isOpen: $timePickerOpen) {
                        DatePicker("Time", selection: Binding(get: { self.timeValue ?? Date() }, set: { self.timeValue = $0 }), displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                    }
                    Button {
                        self.timeValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.inkSoft)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear time")
                } else {
                    Button("+ Add time") { self.timeValue = Date() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            .onChange(of: dateValue) { saveDateTime() }
            .onChange(of: timeValue) { saveDateTime() }
        }
    }

    /// The compact system picker changes its date format with the space it gets, so the pill shows the value in the
    /// app's own `2026-10-30` format and opens the system picker in a popover.
    private func pickerPill(_ text: String, label: String, isOpen: Binding<Bool>, @ViewBuilder picker: @escaping () -> some View) -> some View {
        Button {
            isOpen.wrappedValue = true
        } label: {
            Text(text)
                .font(Theme.mono(14, .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(text)")
        .popover(isPresented: isOpen) {
            picker()
                .labelsHidden()
                .padding(10)
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder private var suggestions: some View {
        let query = storeText.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = Array(store.knownStores.filter { $0.lowercased() != query && (query.isEmpty || $0.lowercased().contains(query)) }.prefix(5))
        if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(matches, id: \.self) { name in
                    Button {
                        storeText = name
                        focus = nil
                    } label: {
                        Text(name)
                            .font(Theme.body(15))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if name != matches.last { Rectangle().fill(Theme.rule).frame(height: 1) }
                }
            }
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule, lineWidth: 1))
            .padding(.top, 4)
        }
    }

    private func commitStore() {
        let trimmed = storeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { storeText = detail.store ?? ""; return }
        guard trimmed != detail.store else { return }
        Task { await store.updateReceiptStore(id: detail.id, store: trimmed) }
    }

    private func commitTotal() {
        let text = totalText.trimmingCharacters(in: .whitespaces)
        let parsed = text.isEmpty ? nil : DecimalInput.parse(text)
        guard text.isEmpty || parsed != nil else {
            totalText = Self.totalString(detail.total)   // not a number: back to what is saved
            return
        }
        guard parsed != detail.total else { return }
        Task { await store.updateReceiptTotal(id: detail.id, total: parsed) }
    }

    private func saveDateTime() {
        guard let dateValue else { return }
        let date = ReceiptDateFormat.dateString(from: dateValue)
        let time = timeValue.map(ReceiptDateFormat.timeString(from:))
        guard date != detail.date || time != detail.time.map({ String($0.prefix(5)) }) else { return }
        Task { await store.updateReceiptDateTime(id: detail.id, date: date, time: time) }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(detail.reviewReasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .padding(.top, 2)
                    Text(reason).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Theme.body(14))
        .foregroundStyle(Theme.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.redBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(Theme.red).frame(width: 3)
        }
    }

    // MARK: Processing panel

    @ViewBuilder
    private func processingPanel(_ processing: ReceiptProcessing) -> some View {
        switch processing {
        case .waitingForUpload(let error):
            panel(title: processing.label, red: false,
                  text: "The photo is saved on this iPhone and uploads as soon as the server is reachable." + (error.map { " Last attempt: \($0)" } ?? ""))
        case .processing:
            panel(title: processing.label, red: false, text: "The server reads the photo; the result appears here by itself.")
        case .uploadFailed(let error):
            panel(title: processing.label, red: true,
                  text: (error ?? "The server did not accept this photo.") + " Retry, or remove this receipt and add a clearer photo.") {
                Button("Retry upload") { Task { await store.retryUpload(id: detail.id) } }
                    .buttonStyle(OutlineButtonStyle(fill: true))
                Button("Remove receipt") { Task { await store.discardFailedUpload(id: detail.id) } }
                    .buttonStyle(OutlineButtonStyle(color: Theme.red))
            }
        case .failed(let error):
            panel(title: processing.label, red: true,
                  text: (error ?? "The server could not read the receipt.") + " Retry it, or fill in the fields below by hand.") {
                Button("Retry extraction") { Task { await store.retryServerExtraction(id: detail.id) } }
                    .buttonStyle(OutlineButtonStyle(fill: true))
            }
        }
    }

    private func panel(title: String, red: Bool, text: String, @ViewBuilder buttons: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if red {
                    Image(systemName: "exclamationmark.circle.fill")
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title).font(Theme.body(15, .semibold))
            }
            .foregroundStyle(red ? Theme.red : Theme.ink)
            Text(text)
                .font(Theme.body(13.5))
                .foregroundStyle(red ? Theme.red : Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { buttons() }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(red ? Theme.redBg : Theme.desk.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Items

    private var groupedItems: [[LineItemDetail]] {
        var order: [Int] = []
        var groups: [Int: [LineItemDetail]] = [:]
        for item in detail.items {
            if groups[item.itemDictionaryId] == nil { order.append(item.itemDictionaryId) }
            groups[item.itemDictionaryId, default: []].append(item)
        }
        return order.map { groups[$0]! }
    }

    private func isHighlighted(_ itemDictionaryId: Int) -> Bool {
        guard let request = store.highlightRequest else { return false }
        return request.receiptId == detail.id && request.itemDictionaryId == itemDictionaryId
    }

    private var itemsSection: some View {
        VStack(spacing: 0) {
            ForEach(groupedItems, id: \.first!.itemDictionaryId) { group in
                let groupId = group.first!.itemDictionaryId
                HStack(alignment: .center, spacing: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                            ReceiptItemRow(receiptId: detail.id, item: item, startOpen: item.needsReview || isHighlighted(groupId))
                            if index < group.count - 1 {
                                Rectangle().fill(Theme.rule.opacity(0.5)).frame(height: 1)
                            }
                        }
                    }
                    if group.count > 1 {
                        Text("\(group.count)×")
                            .font(Theme.mono(12, .medium))
                            .foregroundStyle(Theme.inkSoft)
                            .padding(.leading, 6)
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.inkSoft).frame(width: 1) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(isHighlighted(groupId) ? Theme.redBg : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .animation(.easeOut(duration: 1.2), value: store.highlightRequest)
                .id(groupId)
                Rectangle().fill(Theme.rule).frame(height: 1)
            }
        }
    }

    // MARK: Add item

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showAddForm.toggle() }
                addError = nil
            } label: {
                Text(showAddForm ? "– Cancel" : "+ Add missing item")
                    .font(Theme.body(14, .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAddForm {
                TextField("Item name", text: $addName)
                    .font(Theme.body(15))
                    .focused($focus, equals: .addName)
                    .fieldBox()
                HStack(spacing: 8) {
                    TextField("Qty", text: $addQty)
                        .font(Theme.mono(14))
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .addQty)
                        .fieldBox()
                        .frame(width: 72)
                    TextField("Price €", text: $addPrice)
                        .font(Theme.mono(14))
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .addPrice)
                        .fieldBox()
                    Button(addBusy ? "Adding…" : "Add") { Task { await addItem() } }
                        .buttonStyle(OutlineButtonStyle(fill: true))
                        .disabled(addBusy)
                        .fixedSize()
                }
                if let addError {
                    Text(addError)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.red)
                }
            }
        }
    }

    private func addItem() async {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let price = DecimalInput.parse(addPrice) else {
            addError = "Enter an item name and a price."
            return
        }
        addError = nil
        addBusy = true
        let quantity = DecimalInput.parse(addQty) ?? 1
        await store.addItem(receiptId: detail.id, name: name, quantity: quantity, unitPrice: price, rawText: nil)
        addName = ""
        addQty = "1"
        addPrice = ""
        addBusy = false
    }

    // MARK: Footer

    private var footer: some View {
        let difference = detail.computedSum.flatMap { sum in DecimalInput.parse(totalText).map { $0 - sum } }
        return VStack(spacing: 8) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack {
                Text("Items total:").font(Theme.body(14)).foregroundStyle(Theme.inkSoft)
                Spacer()
                Text(fmtMoney(detail.computedSum)).font(Theme.mono(15, .semibold)).foregroundStyle(Theme.ink)
            }
            HStack {
                Text("Printed total:").font(Theme.body(14)).foregroundStyle(Theme.inkSoft)
                Spacer()
                HStack(spacing: 2) {
                    Text("€").font(Theme.mono(14)).foregroundStyle(Theme.inkSoft)
                    TextField("0.00", text: $totalText)
                        .font(Theme.mono(14, .medium))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .total)
                        .frame(width: 66)
                        .accessibilityLabel("Printed total")
                        .accessibilityIdentifier("printedTotalField")
                }
                .fieldBox()
            }
            if let difference, abs(difference) > 0.004 {
                HStack {
                    Text("Difference:").font(Theme.body(14, .medium))
                    Spacer()
                    Text(fmtMoney(abs(difference))).font(Theme.mono(14, .semibold))
                }
                .foregroundStyle(Theme.red)
            }
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        VStack(spacing: 6) {
            if detail.reviewedAt == nil && detail.processing == nil {
                Text(ReviewQueue.hint(for: detail.id, in: store.receipts))
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .accessibilityIdentifier("nextToReviewHint")
            }
            HStack(spacing: 8) {
                if detail.reviewedAt != nil {
                    // A status rather than a dimmed button, so it stays readable in both modes.
                    Text("Reviewed ✓")
                        .font(Theme.body(16, .semibold))
                        .foregroundStyle(Theme.greenText)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.greenBg, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Button { Task { await looksGood() } } label: {
                        Label("Looks good", systemImage: "checkmark")
                            .font(Theme.body(16, .semibold))
                            .foregroundStyle(Theme.onGreen)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.green, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || isStillReading)
                    .opacity(isBusy || isStillReading ? 0.45 : 1)
                }

                Menu {
                    // The phone has no AI of its own: the server re-reads a photo it still holds.
                    if detail.photoLocation == "server" {
                        Button("Re-run extraction…") { confirmRerun = true }
                    }
                    Button("Delete receipt…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    private func looksGood() async {
        focus = nil
        let id = detail.id
        await store.markReviewed(id: id)
        if let next = ReviewQueue.next(after: id, in: store.receipts) {
            await store.loadReceiptDetail(id: next.id)
        } else {
            close()
        }
    }
}
