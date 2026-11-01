import LabCore
import SwiftUI

/// The pushed detail. Holds the current receipt, so `Looks good` can move to the next one in place.
struct ReceiptDetailScreen: View {
    let store: PolishStore
    @Binding var path: [Int]
    @State private var currentId: Int
    /// A launch state applies once, to the receipt it was launched on.
    @State private var launch: LabScreen?

    init(store: PolishStore, receiptId: Int, path: Binding<[Int]>) {
        self.store = store
        _path = path
        _currentId = State(initialValue: receiptId)
        _launch = State(initialValue: store.launchScreen.fixtureReceipt?.id == receiptId ? store.launchScreen : nil)
    }

    var body: some View {
        DetailContent(store: store, receiptId: currentId, launch: launch, advance: advance, close: close)
            .id(currentId)
            .transition(.opacity)
            .toolbar(.hidden, for: .tabBar)
            .background(P.desk)
            .onAppear { store.launchScreen = .list }
            .onDisappear { store.detailReport = nil }
    }

    private func advance(_ next: LabReceipt?) {
        if let next {
            launch = nil
            withAnimation(.easeInOut(duration: 0.2)) { currentId = next.id }
        } else {
            close()
        }
    }

    private func close() {
        if !path.isEmpty { path.removeLast() }
    }
}

private struct DetailContent: View {
    let store: PolishStore
    let receiptId: Int
    let advance: (LabReceipt?) -> Void
    let close: () -> Void

    @State private var tab: Tab
    @State private var loading: Bool
    @State private var busy: Bool
    private let holdBusy: Bool
    @State private var deleteDialog: Bool
    @State private var rerunDialog: Bool
    @State private var addOpen: Bool
    @State private var scrollToAdd: Bool
    private let editedItemId: Int?

    @State private var storeText: String
    @State private var dateValue: Date?
    @State private var timeValue: Date?
    @State private var datePickerOpen = false
    @State private var timePickerOpen = false
    @State private var totalText: String
    @FocusState private var focus: Field?
    @State private var addName = ""
    @State private var addQty = "1"
    @State private var addPrice = ""
    @State private var addError = false
    @State private var adding = false

    enum Tab: String, CaseIterable { case items = "Items", photo = "Photo" }
    enum Field: Hashable { case store, total, addName, addQty, addPrice }

    init(store: PolishStore, receiptId: Int, launch: LabScreen?, advance: @escaping (LabReceipt?) -> Void, close: @escaping () -> Void) {
        self.store = store
        self.receiptId = receiptId
        self.advance = advance
        self.close = close
        let receipt = store.receipt(receiptId)
        _tab = State(initialValue: launch == .detailPhoto || launch == .detailPhotoMissing ? .photo : .items)
        _loading = State(initialValue: launch == .detailLoading)
        _busy = State(initialValue: launch == .detailBusy)
        holdBusy = launch == .detailBusy
        _deleteDialog = State(initialValue: launch == .dialogDelete)
        _rerunDialog = State(initialValue: launch == .dialogRerun)
        // Production starts the add form open when the sum does not match the printed total.
        let mismatch = receipt.map { r in r.computedSum != nil && r.total != nil && abs((r.computedSum ?? 0) - (r.total ?? 0)) > 0.004 } ?? false
        _addOpen = State(initialValue: mismatch || launch == .detailAddItem)
        _scrollToAdd = State(initialValue: launch == .detailAddItem)
        _addError = State(initialValue: false)
        editedItemId = launch == .detailItemEdited ? receipt?.items.first?.id : nil
        _storeText = State(initialValue: receipt?.store ?? "")
        _dateValue = State(initialValue: receipt?.date.flatMap(LabFormat.date))
        _timeValue = State(initialValue: Self.time(receipt?.time))
        _totalText = State(initialValue: receipt?.total.map { String(format: "%.2f", $0) } ?? "")
    }

    private static func time(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.date(from: string)
    }

    private var receipt: LabReceipt? { store.receipt(receiptId) }

    private var isReviewed: Bool { receipt?.reviewedAt != nil }
    private var isStillReading: Bool { receipt?.processing?.isActive == true }

    private var report: LabScreen {
        guard let receipt else { return .detail }
        if loading { return .detailLoading }
        if deleteDialog { return .dialogDelete }
        if rerunDialog { return .dialogRerun }
        if busy { return .detailBusy }
        if tab == .photo { return receipt.photoLocation == "archived" ? .detailPhotoMissing : .detailPhoto }
        switch receipt.processing {
        case .waitingForUpload: return .detailWaiting
        case .processing: return .detailProcessing
        case .uploadFailed: return .detailUploadFailed
        case .failed: return .detailFailed
        case nil: break
        }
        if editedItemId != nil { return .detailItemEdited }
        if scrollToAdd { return .detailAddItem }
        return receipt.reviewedAt != nil ? .detailReviewed : .detail
    }

    var body: some View {
        Group {
            if loading || receipt == nil {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let receipt {
                content(receipt)
            }
        }
        .navigationTitle(loading ? "Receipt" : (receipt?.store ?? "Receipt"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(P.paper, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(loading ? "Receipt" : (receipt?.store ?? "Receipt"))
                    .font(P.display(18))
                    .foregroundStyle(P.ink)
                    .lineLimit(1)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil; dismissKeyboard() }
            }
        }
        .confirmationDialog("Delete this receipt?", isPresented: $deleteDialog, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let receipt { store.delete(receipt) }
                close()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to \"Recently deleted\" and can be restored from there.")
        }
        .confirmationDialog("Re-run extraction?", isPresented: $rerunDialog, titleVisibility: .visible) {
            Button("Re-run extraction", role: .destructive) { runBusy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server reads the photo again and marks the receipt as not yet reviewed. If you already edited or confirmed this receipt, the server keeps your version.")
        }
        .onChange(of: report, initial: true) { store.detailReport = report }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func runBusy() {
        busy = true
        guard !holdBusy else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            busy = false
        }
    }

    @ViewBuilder
    private func content(_ receipt: LabReceipt) -> some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .items: itemsTab(receipt)
                case .photo: ReceiptPhotoTab(receipt: receipt)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let snack = store.snack {
                SnackbarView(snack: snack) { store.snack = nil }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            actionBar(receipt)
        }
    }

    // MARK: Items tab

    private func itemsTab(_ receipt: LabReceipt) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let processing = receipt.processing { processingPanel(processing) }
                    header(receipt)
                    if !receipt.reviewReasons.isEmpty { warnings(receipt) }
                    if !receipt.items.isEmpty {
                        itemsSection(receipt)
                    }
                    addSection(receipt).id("add")
                    footer(receipt)
                }
                .paperCard()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .disabled(busy)
                .opacity(busy ? 0.45 : 1)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if busy { busyBox }
            }
            .task {
                if scrollToAdd {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo("add", anchor: .center) }
                }
                if let highlight = store.highlightItem {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo(highlight, anchor: .center) }
                }
            }
        }
    }

    private var busyBox: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Working…").font(P.body(15, .medium)).foregroundStyle(P.ink)
        }
        .paperCard(padding: 18)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private func header(_ receipt: LabReceipt) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    TextField("Store", text: $storeText)
                        .font(P.display(24))
                        .foregroundStyle(P.ink)
                        .multilineTextAlignment(.center)
                        .focused($focus, equals: .store)
                        .submitLabel(.done)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 44)
                        .onChange(of: focus) { old, _ in
                            if old == .store { commitStore() }
                        }
                    if focus == .store { suggestions }
                }
                IconButton(systemName: "trash", label: "Delete receipt", size: 15) { deleteDialog = true }
                    .padding(.trailing, -8)
            }
            HStack(spacing: 8) {
                if dateValue != nil {
                    pickerPill(dateText, isOpen: $datePickerOpen) {
                        DatePicker("Date", selection: Binding(get: { dateValue ?? Date() }, set: { dateValue = $0; datePickerOpen = false }), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .frame(width: 320)
                    }
                } else {
                    Button("Set date") { dateValue = LabFormat.date("2026-10-31") }
                        .buttonStyle(OutlineButtonStyle())
                }
                if timeValue != nil {
                    pickerPill(timeText, isOpen: $timePickerOpen) {
                        DatePicker("Time", selection: Binding(get: { timeValue ?? Date() }, set: { timeValue = $0 }), displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                    }
                    Button {
                        timeValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(P.inkSoft)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear time")
                } else {
                    Button("+ Add time") { timeValue = Date() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return dateValue.map { f.string(from: $0) } ?? ""
    }

    private var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return timeValue.map { f.string(from: $0) } ?? ""
    }

    /// The compact system picker changes its date format with the space it gets, so the pill shows the value in the
    /// app's own `2026-10-30` format and opens the system picker in a popover.
    private func pickerPill(_ text: String, isOpen: Binding<Bool>, @ViewBuilder picker: @escaping () -> some View) -> some View {
        Button {
            isOpen.wrappedValue = true
        } label: {
            Text(text)
                .font(P.mono(14, .medium))
                .foregroundStyle(P.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(P.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(P.rule, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: isOpen) {
            picker()
                .labelsHidden()
                .padding(10)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var suggestions: some View {
        let query = storeText.lowercased()
        let matches = LabData.storeSuggestions
            .filter { query.isEmpty || ($0.lowercased().contains(query) && $0.lowercased() != query) }
            .prefix(5)
        return VStack(spacing: 0) {
            ForEach(Array(matches), id: \.self) { name in
                Button {
                    storeText = name
                    focus = nil
                } label: {
                    Text(name)
                        .font(P.body(15))
                        .foregroundStyle(P.ink)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if name != matches.last { Rectangle().fill(P.rule).frame(height: 1) }
            }
        }
        .background(P.field, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(P.rule, lineWidth: 1))
        .padding(.top, 4)
    }

    private func commitStore() {
        let trimmed = storeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { storeText = receipt?.store ?? ""; return }
        store.update(receiptId) { $0.store = trimmed }
    }

    private func warnings(_ receipt: LabReceipt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(receipt.reviewReasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .padding(.top, 2)
                    Text(reason).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(P.body(14))
        .foregroundStyle(P.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(P.redBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(P.red).frame(width: 3)
        }
    }

    // MARK: Processing panel

    @ViewBuilder
    private func processingPanel(_ processing: LabProcessing) -> some View {
        switch processing {
        case .waitingForUpload(let error):
            panel(title: processing.label, red: false,
                  text: "The photo is saved on this iPhone and uploads as soon as the server is reachable. Last attempt: \(error ?? "")")
        case .processing:
            panel(title: processing.label, red: false, text: "The server reads the photo; the result appears here by itself.")
        case .uploadFailed(let error):
            panel(title: processing.label, red: true, text: "\(error ?? "") Retry, or remove this receipt and add a clearer photo.") {
                Button("Retry upload") { retry() }
                    .buttonStyle(OutlineButtonStyle(fill: true))
                Button("Remove receipt") {
                    if let receipt { store.delete(receipt) }
                    close()
                }
                .buttonStyle(OutlineButtonStyle(color: P.red))
            }
        case .failed(let error):
            panel(title: processing.label, red: true, text: "\(error ?? "") Retry it, or fill in the fields below by hand.") {
                Button("Retry extraction") { retry() }
                    .buttonStyle(OutlineButtonStyle(fill: true))
            }
        }
    }

    private func retry() { store.update(receiptId) { $0.processing = .processing } }

    private func panel(title: String, red: Bool, text: String, @ViewBuilder buttons: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if red {
                    Image(systemName: "exclamationmark.circle.fill")
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title).font(P.body(15, .semibold))
            }
            .foregroundStyle(red ? P.red : P.ink)
            Text(text)
                .font(P.body(13.5))
                .foregroundStyle(red ? P.red : P.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { buttons() }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(red ? P.redBg : P.desk.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Items

    private func itemsSection(_ receipt: LabReceipt) -> some View {
        VStack(spacing: 0) {
            ForEach(receipt.groupedItems, id: \.first!.itemDictionaryId) { group in
                HStack(alignment: .center, spacing: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                            ItemRow(store: store, receiptId: receiptId, item: item,
                                    startOpen: item.needsReview || item.id == editedItemId || item.id == store.highlightItem,
                                    startEdited: item.id == editedItemId)
                                .id(item.id)
                            if index < group.count - 1 {
                                Rectangle().fill(P.rule.opacity(0.5)).frame(height: 1)
                            }
                        }
                    }
                    if group.count > 1 {
                        Text("\(group.count)×")
                            .font(P.mono(12, .medium))
                            .foregroundStyle(P.inkSoft)
                            .padding(.leading, 6)
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) { Rectangle().fill(P.inkSoft).frame(width: 1) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(P.rule).frame(height: 1)
            }
        }
    }

    // MARK: Add item

    private func addSection(_ receipt: LabReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { addOpen.toggle() }
                addError = false
            } label: {
                Text(addOpen ? "– Cancel" : "+ Add missing item")
                    .font(P.body(14, .medium))
                    .foregroundStyle(P.ink)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if addOpen {
                TextField("Item name", text: $addName)
                    .font(P.body(15))
                    .focused($focus, equals: .addName)
                    .fieldBox()
                HStack(spacing: 8) {
                    TextField("Qty", text: $addQty)
                        .font(P.mono(14))
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .addQty)
                        .fieldBox()
                        .frame(width: 72)
                    TextField("Price €", text: $addPrice)
                        .font(P.mono(14))
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .addPrice)
                        .fieldBox()
                    Button(adding ? "Adding…" : "Add") { add() }
                        .buttonStyle(OutlineButtonStyle(fill: true))
                        .disabled(adding)
                        .fixedSize()
                }
                if addError {
                    Text("Enter an item name and a price.")
                        .font(P.body(13))
                        .foregroundStyle(P.red)
                }
            }
        }
    }

    private func add() {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let price = Double(addPrice.replacingOccurrences(of: ",", with: ".")) else {
            addError = true
            return
        }
        addError = false
        adding = true
        let quantity = Double(addQty.replacingOccurrences(of: ",", with: ".")) ?? 1
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            store.update(receiptId) { r in
                let id = (r.items.map(\.id).max() ?? r.id * 100) + 1
                r.items.append(LabLineItem(id: id, itemDictionaryId: 10_000 + id, rawText: name, nameDe: name, quantity: quantity,
                                           unitPrice: price, translationEn: nil, category: "Other", subcategory: "Miscellaneous", itemGroup: "General"))
            }
            addName = ""
            addQty = "1"
            addPrice = ""
            adding = false
        }
    }

    // MARK: Footer

    private func footer(_ receipt: LabReceipt) -> some View {
        let printed = Double(totalText.replacingOccurrences(of: ",", with: "."))
        let difference = receipt.computedSum.flatMap { sum in printed.map { $0 - sum } }
        return VStack(spacing: 8) {
            Rectangle().fill(P.rule).frame(height: 1)
            HStack {
                Text("Items total:").font(P.body(14)).foregroundStyle(P.inkSoft)
                Spacer()
                Text(LabFormat.money(receipt.computedSum)).font(P.mono(15, .semibold)).foregroundStyle(P.ink)
            }
            HStack {
                Text("Printed total:").font(P.body(14)).foregroundStyle(P.inkSoft)
                Spacer()
                HStack(spacing: 2) {
                    Text("€").font(P.mono(14)).foregroundStyle(P.inkSoft)
                    TextField("0.00", text: $totalText)
                        .font(P.mono(14, .medium))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .total)
                        .frame(width: 66)
                }
                .fieldBox()
            }
            if let difference, abs(difference) > 0.004 {
                HStack {
                    Text("Difference:").font(P.body(14, .medium))
                    Spacer()
                    Text(LabFormat.money(abs(difference))).font(P.mono(14, .semibold))
                }
                .foregroundStyle(P.red)
            }
        }
    }

    // MARK: Action bar

    private func actionBar(_ receipt: LabReceipt) -> some View {
        let reviewed = receipt.reviewedAt != nil
        return VStack(spacing: 6) {
            if !reviewed && receipt.processing == nil { nextHint }
            HStack(spacing: 8) {
                if reviewed {
                    // A status rather than a dimmed button, so it stays readable in both modes.
                    Text("Reviewed ✓")
                        .font(P.body(16, .semibold))
                        .foregroundStyle(P.greenText)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(P.greenBg, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Button {
                        advance(store.confirm(receiptId))
                    } label: {
                        Label("Looks good", systemImage: "checkmark")
                            .font(P.body(16, .semibold))
                            .foregroundStyle(P.onGreen)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(P.green, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || isStillReading)
                }

                Menu {
                    if receipt.photoLocation == "server" {
                        Button("Re-run extraction…") { rerunDialog = true }
                    }
                    Button("Delete receipt…", role: .destructive) { deleteDialog = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(P.ink)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
                .disabled(busy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(P.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(P.rule).frame(height: 1) }
    }

    private var nextHint: some View {
        let more = store.receipts.filter { $0.reviewedAt == nil && $0.processing == nil && $0.id != receiptId }.count
        let next = store.nextToReview(after: receiptId)?.store
        let text: String
        if more == 0 {
            text = "Last one to review"
        } else if let next {
            text = "\(more) more to review · next: \(next)"
        } else {
            text = "\(more) more to review"
        }
        return Text(text)
            .font(P.body(12.5))
            .foregroundStyle(P.inkSoft)
            .lineLimit(1)
    }
}

// MARK: Item row

private struct ItemRow: View {
    let store: PolishStore
    let receiptId: Int
    let item: LabLineItem

    @State private var open: Bool
    @State private var qtyText: String
    @State private var priceText: String
    @State private var translation: String
    @State private var category: String
    @State private var subcategory: String
    @State private var itemGroup: String
    @State private var saveState = SaveState.idle

    enum SaveState { case idle, saving, saved, bad }

    init(store: PolishStore, receiptId: Int, item: LabLineItem, startOpen: Bool, startEdited: Bool) {
        self.store = store
        self.receiptId = receiptId
        self.item = item
        _open = State(initialValue: startOpen)
        _qtyText = State(initialValue: LabFormat.quantity(item.quantity))
        _priceText = State(initialValue: String(format: "%.2f", item.unitPrice))
        _translation = State(initialValue: item.translationEn ?? "")
        _category = State(initialValue: item.category)
        if startEdited {
            _subcategory = State(initialValue: "Beverages")
            _itemGroup = State(initialValue: "Juice")
        } else {
            _subcategory = State(initialValue: item.subcategory)
            _itemGroup = State(initialValue: item.itemGroup)
        }
    }

    private var categoryChanged: Bool {
        category != item.category || subcategory != item.subcategory || itemGroup != item.itemGroup
    }

    private var previewTotal: String {
        let q = Double(qtyText.replacingOccurrences(of: ",", with: ".")) ?? item.quantity
        let p = Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? item.unitPrice
        return LabFormat.money((q * p * 100).rounded() / 100)
    }

    private var saveLabel: String {
        switch saveState {
        case .idle: return "Save"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .bad: return "Bad qty/price"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if open { editor }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, item.needsReview ? 8 : 0)
        .background(item.needsReview ? P.redBg : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, item.needsReview ? 4 : 0)
    }

    private var summary: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.nameDe ?? "")
                        .font(P.body(15, .semibold))
                        .foregroundStyle(P.ink)
                        .multilineTextAlignment(.leading)
                    if !open {
                        if let en = item.translationEn {
                            Text(en).font(P.body(13)).foregroundStyle(P.inkSoft).lineLimit(1)
                        }
                        Text("\(LabFormat.quantity(item.quantity)) × \(LabFormat.money(item.unitPrice)) · \(item.subcategory) › \(item.itemGroup)")
                            .font(P.mono(11))
                            .foregroundStyle(P.inkSoft)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(open ? previewTotal : LabFormat.money(item.totalPrice))
                    .font(P.mono(14, .medium))
                    .foregroundStyle(P.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(P.inkSoft)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(open ? "Collapses the editor" : "Opens the editor")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("", text: $qtyText)
                    .keyboardType(.decimalPad)
                    .fieldBox()
                    .frame(width: 76)
                    .accessibilityLabel("Quantity")
                Text("×").foregroundStyle(P.inkSoft)
                TextField("", text: $priceText)
                    .keyboardType(.decimalPad)
                    .fieldBox()
                    .frame(width: 84)
                    .accessibilityLabel("Unit price")
                Text("=").foregroundStyle(P.inkSoft)
                Text(previewTotal)
                    .fontWeight(.semibold)
                    .foregroundStyle(P.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .font(P.mono(14))

            TextField("Translation", text: $translation)
                .font(P.body(15))
                .fieldBox()

            VStack(spacing: 0) {
                pickerRow("Category", selection: $category, options: LabTaxonomy.categoryNames)
                    .onChange(of: category) {
                        subcategory = LabTaxonomy.subcategoryNames(in: category).first ?? ""
                        itemGroup = LabTaxonomy.itemGroups(category: category, subcategory: subcategory).first ?? ""
                    }
                Rectangle().fill(P.rule).frame(height: 1)
                pickerRow("Subcategory", selection: $subcategory, options: LabTaxonomy.subcategoryNames(in: category))
                    .onChange(of: subcategory) {
                        let groups = LabTaxonomy.itemGroups(category: category, subcategory: subcategory)
                        if !groups.contains(itemGroup) { itemGroup = groups.first ?? "" }
                    }
                Rectangle().fill(P.rule).frame(height: 1)
                pickerRow("Item group", selection: $itemGroup, options: LabTaxonomy.itemGroups(category: category, subcategory: subcategory))
            }
            .padding(.horizontal, 10)
            .background(P.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(P.rule, lineWidth: 1))

            if categoryChanged {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Saving updates the dictionary entry, so it applies to 3 line items across 2 receipts.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(P.body(12.5))
                .foregroundStyle(P.inkSoft)
            }

            HStack(spacing: 8) {
                Button(saveLabel) { save() }
                    .buttonStyle(OutlineButtonStyle(color: saveState == .bad ? P.red : P.ink, fill: saveState == .idle))
                    .disabled(saveState == .saving)
                    .fixedSize()
                Spacer()
                IconButton(systemName: "trash", label: "Delete item", size: 15) { deleteItem() }
                    .padding(.trailing, -10)
            }
        }
        .padding(.top, 2)
    }

    private func pickerRow(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(title).font(P.body(13)).foregroundStyle(P.inkSoft)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(P.ink)
            .font(P.body(14))
        }
        .frame(minHeight: 40)
    }

    private func save() {
        guard let quantity = Double(qtyText.replacingOccurrences(of: ",", with: ".")),
              let price = Double(priceText.replacingOccurrences(of: ",", with: ".")) else {
            saveState = .bad
            return
        }
        saveState = .saving
        let (id, en, c, s, g) = (item.id, translation, category, subcategory, itemGroup)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            store.update(receiptId) { receipt in
                guard let index = receipt.items.firstIndex(where: { $0.id == id }) else { return }
                receipt.items[index].quantity = quantity
                receipt.items[index].unitPrice = price
                receipt.items[index].translationEn = en.isEmpty ? nil : en
                receipt.items[index].category = c
                receipt.items[index].subcategory = s
                receipt.items[index].itemGroup = g
            }
            saveState = .saved
            try? await Task.sleep(for: .seconds(1.5))
            if saveState == .saved { saveState = .idle }
        }
    }

    private func deleteItem() {
        let removed = item
        let receiptId = receiptId
        let index = store.receipt(receiptId)?.items.firstIndex { $0.id == removed.id } ?? 0
        withAnimation { store.update(receiptId) { $0.items.removeAll { $0.id == removed.id } } }
        store.show(snack: "Item deleted") { [store] in
            store.update(receiptId) { $0.items.insert(removed, at: min(index, $0.items.count)) }
        }
    }
}

// MARK: Photo tab

private struct ReceiptPhotoTab: View {
    let receipt: LabReceipt
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?

    private var hasPhoto: Bool { receipt.photoNote == nil }
    private let actualSize: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            bar
            if hasPhoto { photo } else { missing }
        }
    }

    private var bar: some View {
        HStack(spacing: 2) {
            SectionLabel(text: "Photo")
            Spacer()
            IconButton(systemName: "minus.magnifyingglass", label: "Zoom out", color: P.ink, size: 16) { setZoom(zoom / 1.5) }
            barText("Fit", active: zoom == 1) { setZoom(1) }
            barText("100%", active: zoom == actualSize) { setZoom(actualSize) }
            IconButton(systemName: "plus.magnifyingglass", label: "Zoom in", color: P.ink, size: 16) { setZoom(zoom * 1.5) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .background(P.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(P.rule).frame(height: 1) }
        .disabled(!hasPhoto)
        .opacity(hasPhoto ? 1 : 0.4)
    }

    private func barText(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(P.mono(13, active ? .semibold : .regular))
                .foregroundStyle(P.ink)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 32)
                .background(active ? P.rule.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var photo: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ReceiptPhotoPlaceholder(receipt: receipt)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(zoom)
                    .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
            }
            .background(Color(white: 0.2))
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? zoom
                        pinchStart = start
                        zoom = min(8, max(1, start * value.magnification))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
        }
    }

    private var missing: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(P.label)
            Text(receipt.photoNote ?? "")
                .font(P.body(15))
                .foregroundStyle(P.label)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) { zoom = min(8, max(1, value)) }
    }
}
