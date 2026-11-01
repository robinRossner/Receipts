import SwiftUI

/// Ports renderItemRow() from dashboard.html: a compact summary (name, translation, `qty × price`, category path, total)
/// that expands to the inline editor with qty/price, an English translation field, and cascading category > subcategory >
/// item_group pickers. Items that need a look start open.
struct ItemRowView: View {
    @EnvironmentObject var store: ReceiptStore
    @EnvironmentObject var snacks: SnackCenter
    let receiptId: Int
    let item: LineItemDetail
    /// Overview's `Edit` (or a link from the flagged items) points at this item: it opens, also when already on screen.
    let highlighted: Bool

    enum SaveState { case idle, saving, saved, failed }

    @State private var open: Bool
    @State private var qtyText: String
    @State private var priceText: String
    @State private var translationText: String
    @State private var category: String
    @State private var subcategory: String
    @State private var itemGroup: String
    @State private var saveState: SaveState = .idle
    @State private var usage: (items: Int, receipts: Int)?

    init(receiptId: Int, item: LineItemDetail, highlighted: Bool) {
        self.receiptId = receiptId
        self.item = item
        self.highlighted = highlighted
        _open = State(initialValue: item.needsReview || highlighted)
        _qtyText = State(initialValue: trimmedNumber(item.quantity))
        _priceText = State(initialValue: String(format: "%.2f", item.unitPrice))
        _translationText = State(initialValue: item.translationEn ?? "")
        _category = State(initialValue: item.category)
        _subcategory = State(initialValue: item.subcategory)
        _itemGroup = State(initialValue: item.itemGroup)
    }

    private var previewTotal: String {
        guard let q = DecimalInput.parse(qtyText), let p = DecimalInput.parse(priceText) else { return "—" }
        return fmtMoney(round2(q * p))
    }

    private var categoryChanged: Bool {
        category != item.category || subcategory != item.subcategory || itemGroup != item.itemGroup
    }

    private var usageNote: String {
        guard let usage else { return "This changes the shared dictionary entry for this item." }
        let items = usage.items == 1 ? "1 line item" : "\(usage.items) line items"
        let receipts = usage.receipts == 1 ? "1 receipt" : "\(usage.receipts) receipts"
        return "Saving updates the dictionary entry, so it applies to \(items) across \(receipts)."
    }

    private var saveLabel: String {
        switch saveState {
        case .idle: return "Save"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .failed: return "Bad qty/price"
        }
    }

    /// `1 × €2.49 · Dairy › Milk`
    private var summaryLine: String {
        let path = [item.subcategory, item.itemGroup].filter { !$0.isEmpty }.joined(separator: " › ")
        let amount = "\(trimmedNumber(item.quantity)) × \(fmtMoney(item.unitPrice))"
        return path.isEmpty ? amount : "\(amount) · \(path)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if item.categoryFlagged { FlaggedItemMark(item: item) }
            if open { editor }
        }
        .padding(item.needsReview ? 10 : 0)
        .background(item.needsReview ? AppTheme.penRedBg : Color.clear)
        .cornerRadius(item.needsReview ? 4 : 0)
        .onChange(of: highlighted) { if highlighted { open = true } }
        // Another row of the same product saved, or a sync arrived: show what is true now.
        .onChange(of: item.quantity) { qtyText = trimmedNumber(item.quantity) }
        .onChange(of: item.unitPrice) { priceText = String(format: "%.2f", item.unitPrice) }
        .onChange(of: item.translationEn) { translationText = item.translationEn ?? "" }
        .onChange(of: item.category) { category = item.category }
        .onChange(of: item.subcategory) { subcategory = item.subcategory }
        .onChange(of: item.itemGroup) { itemGroup = item.itemGroup }
    }

    private var summary: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.inkSoft)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.nameDe ?? item.rawText ?? "")
                        .font(AppTheme.body(14, weight: .semibold))
                        .foregroundColor(AppTheme.ink)
                        .multilineTextAlignment(.leading)
                    if !open {
                        if let translation = item.translationEn, !translation.isEmpty {
                            Text(translation)
                                .font(AppTheme.body(12))
                                .foregroundColor(AppTheme.inkSoft)
                                .lineLimit(1)
                        }
                        Text(summaryLine)
                            .font(AppTheme.mono(11))
                            .foregroundColor(AppTheme.inkSoft)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(open ? previewTotal : fmtMoney(item.totalPrice))
                    .font(AppTheme.mono(13, weight: .medium))
                    .foregroundColor(AppTheme.ink)
            }
            .padding(.vertical, 2)
            .hoverHighlight()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Collapse" : "Edit this item")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                TextField("", text: $qtyText)
                    .frame(width: 56)
                    .accessibilityLabel("Quantity")
                    .accessibilityIdentifier("qtyField")
                Text("×").foregroundColor(AppTheme.inkSoft)
                TextField("", text: $priceText)
                    .frame(width: 64)
                    .accessibilityLabel("Unit price")
                    .accessibilityIdentifier("priceField")
                Text("=").foregroundColor(AppTheme.inkSoft)
                Text(previewTotal)
                    .fontWeight(.semibold)
                    .foregroundColor(AppTheme.ink)
            }
            .textFieldStyle(.roundedBorder)
            .font(AppTheme.mono(12))
            .foregroundColor(AppTheme.inkSoft)

            // Split into logical rows (translation / pickers / actions) rather than one long
            // HStack - dashboard.html's `.item-controls` could flex-wrap onto multiple lines
            // when it ran out of room, but a plain SwiftUI HStack instead compresses whichever
            // child has no size preference, which was the Save button - it was rendering as an
            // ellipsis instead of being pushed to a new line.
            TextField("Translation", text: $translationText)
                .textFieldStyle(.roundedBorder)
                .font(AppTheme.body(12))

            HStack(spacing: 6) { pickers }
                .labelsHidden()
                .font(AppTheme.body(12))

            if categoryChanged {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                    Text(usageNote)
                }
                .font(AppTheme.body(11))
                .foregroundColor(AppTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                // .fixedSize() guarantees these never get compressed by the layout system -
                // any squeezing lands on the pickers above (which have a minWidth to shrink
                // to) instead of truncating this button's label.
                Button(saveLabel) { Task { await save() } }
                    .disabled(saveState == .saving)
                    .accessibilityIdentifier("saveItemButton")
                    .fixedSize()

                Button { deleteItem() } label: {
                    Image(systemName: "trash")
                        .foregroundColor(AppTheme.inkSoft)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Delete item")

                Spacer()
            }
            .font(AppTheme.body(12))
        }
        .padding(.leading, 18)
        .task(id: item.itemDictionaryId) {
            let u = await store.dictionaryUsage(itemDictionaryId: item.itemDictionaryId)
            usage = (u.items, u.receipts)
        }
    }

    /// category > subcategory > item_group. Through setters rather than onChange, so a change from outside (a sync) cannot
    /// reset the lower levels.
    @ViewBuilder
    private var pickers: some View {
        Picker("Category", selection: Binding(get: { category }, set: selectCategory)) {
            ForEach(store.taxonomy.categoryNames(), id: \.self) { Text($0).tag($0) }
        }
        .frame(minWidth: 90, idealWidth: 130)
        Picker("Subcategory", selection: Binding(get: { subcategory }, set: selectSubcategory)) {
            ForEach(store.taxonomy.subcategoryNames(in: category), id: \.self) { Text($0).tag($0) }
        }
        .frame(minWidth: 90, idealWidth: 140)
        Picker("Item group", selection: $itemGroup) {
            ForEach(store.taxonomy.itemGroups(category: category, subcategory: subcategory), id: \.self) { Text($0).tag($0) }
        }
        .frame(minWidth: 90, idealWidth: 140)
    }

    private func selectCategory(_ value: String) {
        category = value
        subcategory = store.taxonomy.subcategoryNames(in: value).first ?? ""
        itemGroup = store.taxonomy.itemGroups(category: value, subcategory: subcategory).first ?? ""
    }

    private func selectSubcategory(_ value: String) {
        subcategory = value
        let groups = store.taxonomy.itemGroups(category: category, subcategory: value)
        if !groups.contains(itemGroup) { itemGroup = groups.first ?? "" }
    }

    private func save() async {
        guard let qty = DecimalInput.parse(qtyText), let price = DecimalInput.parse(priceText) else {
            saveState = .failed
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if saveState == .failed { saveState = .idle }
            return
        }
        saveState = .saving
        await store.correctItem(
            itemDictionaryId: item.itemDictionaryId, category: category, subcategory: subcategory,
            itemGroup: itemGroup, translationEn: translationText, forReceipt: receiptId
        )
        await store.updateLineItem(lineItemId: item.id, quantity: qty, unitPrice: price, receiptId: receiptId)
        saveState = .saved
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if saveState == .saved { saveState = .idle }
    }

    private func deleteItem() {
        let (lineItemId, receiptId) = (item.id, receiptId)
        Task {
            guard let removed = await store.deleteLineItemForUndo(lineItemId: lineItemId, receiptId: receiptId) else { return }
            snacks.show("Item deleted") { await store.restoreDeletedLineItem(removed) }
        }
    }
}
