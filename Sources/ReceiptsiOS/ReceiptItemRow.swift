import SwiftUI

/// One line item: a compact summary (name, translation, `qty × price`, category path, total) that expands to the inline
/// editor. Flagged items start open. Saving also confirms the category, as on the Mac (`correctItem`).
struct ReceiptItemRow: View {
    @EnvironmentObject var store: ReceiptStore
    @EnvironmentObject private var snacks: SnackCenter
    let receiptId: Int
    let item: LineItemDetail

    private enum SaveState { case idle, saving, saved, bad }

    @State private var open: Bool
    @State private var qtyText: String
    @State private var priceText: String
    @State private var translationText: String
    @State private var category: String
    @State private var subcategory: String
    @State private var itemGroup: String
    @State private var saveState = SaveState.idle
    @State private var usage: (items: Int, receipts: Int)?

    init(receiptId: Int, item: LineItemDetail, startOpen: Bool) {
        self.receiptId = receiptId
        self.item = item
        _open = State(initialValue: startOpen)
        _qtyText = State(initialValue: trimmedNumber(item.quantity))
        _priceText = State(initialValue: String(format: "%.2f", item.unitPrice))
        _translationText = State(initialValue: item.translationEn ?? "")
        _category = State(initialValue: item.category)
        _subcategory = State(initialValue: item.subcategory)
        _itemGroup = State(initialValue: item.itemGroup)
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

    private var previewTotal: String {
        guard let q = DecimalInput.parse(qtyText), let p = DecimalInput.parse(priceText) else { return "—" }
        return fmtMoney(round2(q * p))
    }

    private var saveLabel: String {
        switch saveState {
        case .idle: return "Save"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .bad: return "Bad qty/price"
        }
    }

    /// `1 × €2.49 · Dairy › Milk`
    private var summaryLine: String {
        let path = [item.subcategory, item.itemGroup].filter { !$0.isEmpty }.joined(separator: " › ")
        let amount = "\(trimmedNumber(item.quantity)) × \(fmtMoney(item.unitPrice))"
        return path.isEmpty ? amount : "\(amount) · \(path)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if item.categoryFlagged { FlaggedItemMark(item: item) }
            if open { editor }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, item.needsReview ? 8 : 0)
        .background(item.needsReview ? Theme.redBg : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, item.needsReview ? 4 : 0)
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
            withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.nameDe ?? item.rawText ?? "")
                        .font(Theme.body(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    if !open {
                        if let translation = item.translationEn, !translation.isEmpty {
                            Text(translation).font(Theme.body(13)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        }
                        Text(summaryLine)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(open ? previewTotal : fmtMoney(item.totalPrice))
                    .font(Theme.mono(14, .medium))
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft)
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
                    .accessibilityIdentifier("qtyField")
                Text("×").foregroundStyle(Theme.inkSoft)
                TextField("", text: $priceText)
                    .keyboardType(.decimalPad)
                    .fieldBox()
                    .frame(width: 84)
                    .accessibilityLabel("Unit price")
                    .accessibilityIdentifier("priceField")
                Text("=").foregroundStyle(Theme.inkSoft)
                Text(previewTotal)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .font(Theme.mono(14))

            TextField("Translation", text: $translationText)
                .font(Theme.body(15))
                .fieldBox()

            VStack(spacing: 0) {
                pickerRow("Category", selection: Binding(get: { category }, set: selectCategory), options: store.taxonomy.categoryNames())
                Rectangle().fill(Theme.rule).frame(height: 1)
                pickerRow("Subcategory", selection: Binding(get: { subcategory }, set: selectSubcategory), options: store.taxonomy.subcategoryNames(in: category))
                Rectangle().fill(Theme.rule).frame(height: 1)
                pickerRow("Item group", selection: $itemGroup, options: store.taxonomy.itemGroups(category: category, subcategory: subcategory))
            }
            .padding(.horizontal, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule, lineWidth: 1))

            if categoryChanged {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(usageNote).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.inkSoft)
            }

            HStack(spacing: 8) {
                Button(saveLabel) { Task { await save() } }
                    .buttonStyle(OutlineButtonStyle(color: saveState == .bad ? Theme.red : Theme.ink, fill: saveState == .idle))
                    .disabled(saveState == .saving)
                    .fixedSize()
                    .accessibilityIdentifier("saveItemButton")
                Spacer()
                IconButton(systemName: "trash", label: "Delete item", size: 15) { deleteItem() }
                    .padding(.trailing, -10)
            }
        }
        .padding(.top, 2)
        .task(id: item.itemDictionaryId) {
            let found = await store.dictionaryUsage(itemDictionaryId: item.itemDictionaryId)
            usage = (found.items, found.receipts)
        }
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

    /// A menu with its own label: the system menu picker wraps long taxonomy names over the neighbouring rows.
    private func pickerRow(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.body(13)).foregroundStyle(Theme.inkSoft).fixedSize()
            Spacer(minLength: 0)
            Menu {
                Picker(title, selection: selection) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.isEmpty ? "—" : selection.wrappedValue)
                        .font(Theme.body(14))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(title)
            .accessibilityValue(selection.wrappedValue)
        }
    }

    private func save() async {
        guard let quantity = DecimalInput.parse(qtyText), let price = DecimalInput.parse(priceText) else {
            saveState = .bad
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if saveState == .bad { saveState = .idle }
            return
        }
        saveState = .saving
        await store.correctItem(
            itemDictionaryId: item.itemDictionaryId, category: category, subcategory: subcategory,
            itemGroup: itemGroup, translationEn: translationText, forReceipt: receiptId
        )
        await store.updateLineItem(lineItemId: item.id, quantity: quantity, unitPrice: price, receiptId: receiptId)
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
