import SwiftUI

/// Ports renderItemRow() from dashboard.html: an editable line item with qty/price, an English
/// translation field, and cascading category > subcategory > item_group pickers.
struct ItemRowView: View {
    @EnvironmentObject var store: ReceiptStore
    let receiptId: Int
    let item: LineItemDetail

    enum SaveState { case idle, saving, saved, failed }

    @State private var qtyText: String
    @State private var priceText: String
    @State private var translationText: String
    @State private var category: String
    @State private var subcategory: String
    @State private var itemGroup: String
    @State private var saveState: SaveState = .idle
    @State private var usage: (items: Int, receipts: Int)?

    init(receiptId: Int, item: LineItemDetail) {
        self.receiptId = receiptId
        self.item = item
        _qtyText = State(initialValue: trimmedNumber(item.quantity))
        _priceText = State(initialValue: String(format: "%.2f", item.unitPrice))
        _translationText = State(initialValue: item.translationEn ?? "")
        _category = State(initialValue: item.category)
        _subcategory = State(initialValue: item.subcategory)
        _itemGroup = State(initialValue: item.itemGroup)
    }

    private var previewTotal: String {
        guard let q = Double(qtyText), let p = Double(priceText) else { return "—" }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.nameDe ?? "")
                .font(AppTheme.body(14, weight: .semibold))
                .foregroundColor(AppTheme.ink)

            HStack(spacing: 4) {
                TextField("", text: $qtyText)
                    .frame(width: 56)
                    .decimalKeyboard()
                Text("×").foregroundColor(AppTheme.inkSoft)
                TextField("", text: $priceText)
                    .frame(width: 64)
                    .decimalKeyboard()
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

            categoryPickers
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
                    .fixedSize()

                Button {
                    Task { await store.deleteLineItem(lineItemId: item.id, receiptId: receiptId) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(AppTheme.inkSoft)
                }
                .buttonStyle(.plain)
                .fixedSize()

                Spacer()
            }
            .font(AppTheme.body(12))
        }
        .task(id: item.itemDictionaryId) {
            let u = await store.dictionaryUsage(itemDictionaryId: item.itemDictionaryId)
            usage = (u.items, u.receipts)
        }
        .padding(item.needsReview ? 10 : 0)
        .background(item.needsReview ? AppTheme.penRedBg : Color.clear)
        .cornerRadius(item.needsReview ? 4 : 0)
    }

    /// category > subcategory > item_group. One row on the Mac; stacked and labelled on the phone, where three
    /// pickers do not fit side by side.
    @ViewBuilder
    private var categoryPickers: some View {
        #if os(macOS)
        HStack(spacing: 6) { pickers(labelled: false) }
        #else
        VStack(alignment: .leading, spacing: 2) { pickers(labelled: true) }
        #endif
    }

    @ViewBuilder
    private func pickers(labelled: Bool) -> some View {
        Picker(labelled ? "Category" : "", selection: $category) {
            ForEach(store.taxonomy.categoryNames(), id: \.self) { Text($0).tag($0) }
        }
        .frame(minWidth: 90, idealWidth: 130)
        .onChange(of: category) {
            subcategory = store.taxonomy.subcategoryNames(in: category).first ?? ""
            itemGroup = store.taxonomy.itemGroups(category: category, subcategory: subcategory).first ?? ""
        }

        Picker(labelled ? "Subcategory" : "", selection: $subcategory) {
            ForEach(store.taxonomy.subcategoryNames(in: category), id: \.self) { Text($0).tag($0) }
        }
        .frame(minWidth: 90, idealWidth: 140)
        .onChange(of: subcategory) {
            itemGroup = store.taxonomy.itemGroups(category: category, subcategory: subcategory).first ?? ""
        }

        Picker(labelled ? "Item group" : "", selection: $itemGroup) {
            ForEach(store.taxonomy.itemGroups(category: category, subcategory: subcategory), id: \.self) { Text($0).tag($0) }
        }
        .frame(minWidth: 90, idealWidth: 140)
    }

    private func save() async {
        guard let qty = Double(qtyText), let price = Double(priceText) else {
            saveState = .failed
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                saveState = .idle
            }
            return
        }
        saveState = .saving
        await store.correctItem(
            itemDictionaryId: item.itemDictionaryId, category: category, subcategory: subcategory,
            itemGroup: itemGroup, translationEn: translationText, forReceipt: receiptId
        )
        await store.updateLineItem(lineItemId: item.id, quantity: qty, unitPrice: price, receiptId: receiptId)
        saveState = .saved
    }
}
