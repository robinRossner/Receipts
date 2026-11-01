import LabCore
import SwiftUI

struct BrutalDetailScreen: View {
    @Bindable var model: BrutalModel
    @State private var keyboard = KeyboardWatcher()
    @State private var menuOpen = false
    @State private var dragX: CGFloat = 0

    private var route: DetailRoute? { model.route }
    private var receipt: LabReceipt? { route.flatMap { model.receipt(id: $0.receiptID) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if route?.loading == true {
                ZStack {
                    BP.page
                    BlockSpinner(size: 44)
                }
            } else if let receipt {
                tabs
                ZStack(alignment: .bottomTrailing) {
                    if route?.photoTab == true {
                        BrutalPhotoTab(receipt: receipt)
                    } else {
                        BrutalItemsTab(model: model, receipt: receipt)
                    }
                    if menuOpen { menu(receipt) }
                }
                .frame(maxHeight: .infinity)
                actionBar(receipt)
            }
        }
        .background(BP.page.ignoresSafeArea())
        .offset(x: dragX)
        .overlay(alignment: .leading) {
            // Edge swipe back, since this is a custom push.
            Color.clear
                .frame(width: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { dragX = max(0, $0.translation.width) }
                    .onEnded { value in
                        if value.translation.width > 110 { back() } else {
                            withAnimation(.easeOut(duration: 0.12)) { dragX = 0 }
                        }
                    })
        }
    }

    private func back() {
        KeyboardWatcher.dismiss()
        model.route = nil
    }

    private var title: String {
        if route?.loading == true { return "Receipt" }
        return receipt?.store ?? "Receipt"
    }

    private var header: some View {
        HeroSlab {
            HStack(spacing: 10) {
                IconBlock(system: "chevron.left", label: "Back") { back() }
                Text(title)
                    .font(BF.display(18))
                    .foregroundStyle(BP.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private var tabs: some View {
        BrutalSegmented(
            options: [(false, "Items"), (true, "Photo")],
            selection: Binding(get: { route?.photoTab ?? false }, set: { value in
                KeyboardWatcher.dismiss()
                model.route?.photoTab = value
            })
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func actionBar(_ receipt: LabReceipt) -> some View {
        let busy = route?.busy == true
        VStack(spacing: 0) {
            BP.line.frame(height: BT.barRule)
            if keyboard.isVisible {
                HStack {
                    Spacer()
                    Button("Done") { KeyboardWatcher.dismiss() }
                        .buttonStyle(.slabSmall(BP.yellow, ink: BP.onAccent))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 12) {
                    let reviewed = receipt.reviewedAt != nil
                    Button(reviewed ? "Reviewed ✓" : "Looks good") { model.looksGood(receipt.id) }
                        .buttonStyle(SlabButtonStyle(fill: BP.green, height: 48, font: BF.label(17)))
                        .disabled(reviewed || busy)
                    IconBlock(system: "ellipsis", label: "More actions", size: 48) {
                        withAnimation(.easeOut(duration: 0.1)) { menuOpen.toggle() }
                    }
                    .disabled(busy)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
        }
        .background(BP.card.ignoresSafeArea(edges: .bottom))
    }

    private func menu(_ receipt: LabReceipt) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.001)
                .onTapGesture { menuOpen = false }
            VStack(spacing: 0) {
                if receipt.photoLocation == "server" {
                    menuButton("Re-run extraction…", color: BP.text) { model.dialog = .rerun }
                    HeavyRule()
                }
                menuButton("Delete receipt…", color: BP.redText) { model.dialog = .delete }
            }
            .frame(width: 240)
            .slab(BP.card, shadow: BT.shadowCard)
            .padding(.trailing, 20)
            .padding(.bottom, 12)
        }
    }

    private func menuButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            menuOpen = false
            action()
        } label: {
            Text(title)
                .font(BF.body(15, .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Items tab

struct BrutalItemsTab: View {
    let model: BrutalModel
    let receipt: LabReceipt

    private var busy: Bool { model.route?.busy == true }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    BrutalReceiptCard(model: model, receipt: receipt)
                        .disabled(busy)
                        .opacity(busy ? 0.4 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .padding(.top, 2)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if busy {
                    HStack(spacing: 10) {
                        BlockSpinner(size: 20, color: BP.onAccent)
                        Text("Working…")
                            .font(BF.label(17))
                            .foregroundStyle(BP.onAccent)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .slab(BP.yellow, shadow: BT.shadowCard)
                }
            }
            .task {
                if model.route?.addItemFixture == true {
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo("addForm", anchor: .center)
                } else if let id = model.route?.expandItemID {
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo("item-\(id)", anchor: .top)
                }
            }
        }
    }
}

struct BrutalReceiptCard: View {
    let model: BrutalModel
    let receipt: LabReceipt

    @State private var store: String
    @State private var date: Date?
    @State private var time: Date?
    @State private var addOpen: Bool
    @State private var printed: String
    @FocusState private var storeFocused: Bool

    init(model: BrutalModel, receipt: LabReceipt) {
        self.model = model
        self.receipt = receipt
        _store = State(initialValue: receipt.store ?? "")
        _date = State(initialValue: receipt.date.flatMap(LabFormat.date))
        _time = State(initialValue: receipt.time.flatMap { Self.timeFormatter.date(from: $0) })
        _addOpen = State(initialValue: model.route?.addItemFixture == true)
        _printed = State(initialValue: receipt.total.map { String(format: "%.2f", $0) } ?? "")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var suggestions: [String] {
        let query = store.lowercased()
        let list = LabData.storeSuggestions.filter { query.isEmpty || ($0.lowercased().contains(query) && $0.lowercased() != query) }
        return Array(list.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let processing = receipt.processing {
                BrutalProcessingPanel(model: model, receipt: receipt, processing: processing)
                HeavyRule()
            }
            VStack(spacing: 12) {
                storeField
                dateRow
            }
            .padding(14)
            if !receipt.reviewReasons.isEmpty {
                warning
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
            HeavyRule()
            VStack(spacing: 0) {
                ForEach(Array(receipt.groupedItems.enumerated()), id: \.element.first?.id) { index, group in
                    BrutalItemGroup(model: model, receipt: receipt, group: group,
                                    startsEdited: index == 0 && model.route?.editedFixture == true)
                    HeavyRule(height: BT.ruleThin)
                }
            }
            addSection.id("addForm")
            HeavyRule()
            footer
        }
        .slab(BP.card)
    }

    private var storeField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 44, height: 44)
                TextField("", text: $store, prompt: Text("Store").foregroundStyle(BP.text2), axis: .vertical)
                    .lineLimit(1...2)
                    .focused($storeFocused)
                    .font(BF.display(19))
                    .foregroundStyle(BP.text)
                    .multilineTextAlignment(.center)
                    .tint(BP.text)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
                IconBlock(system: "xmark", label: "Delete receipt") { model.dialog = .delete }
            }
            if storeFocused && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            store = suggestion
                            storeFocused = false
                        } label: {
                            Text(suggestion)
                                .font(BF.body(15, .medium))
                                .foregroundStyle(BP.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if suggestion != suggestions.last { BP.line.frame(height: BT.ruleThin) }
                    }
                }
                .slab(BP.focusFill, border: BT.borderThin)
            }
        }
    }

    private var dateRow: some View {
        HStack(spacing: 10) {
            if let date {
                pickerChip(text: Self.dateFormatter.string(from: date), selection: Binding(get: { date }, set: { self.date = $0 }), components: .date)
            } else {
                Button("Set date") { date = LabFormat.date("2026-10-31") }
                    .buttonStyle(.slabSmall())
            }
            if let time {
                pickerChip(text: Self.timeFormatter.string(from: time), selection: Binding(get: { time }, set: { self.time = $0 }), components: .hourAndMinute)
                Button {
                    self.time = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(BP.text2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear time")
            } else {
                Button("+ Add time") { time = Self.timeFormatter.date(from: "12:00") }
                    .buttonStyle(.slabSmall())
            }
            Spacer(minLength: 0)
        }
    }

    private func pickerChip(text: String, selection: Binding<Date>, components: DatePickerComponents) -> some View {
        BrutalDateChip(text: text, selection: selection, components: components)
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(receipt.reviewReasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 8) {
                    Text("⚠").font(BF.label(15))
                    Text(reason)
                        .font(BF.body(14, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(BP.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .slab(BP.flagFill, border: BT.borderThin)
    }

    // MARK: Add form

    @State private var newName = ""
    @State private var newQty = "1"
    @State private var newPrice = ""
    @State private var adding = false
    @State private var addError = false

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(addOpen ? "– Cancel" : "+ Add missing item") {
                addOpen.toggle()
                addError = false
            }
            .buttonStyle(.slabSmall())
            if addOpen {
                BrutalField(prompt: "Item name", text: $newName)
                HStack(spacing: 8) {
                    BrutalField(prompt: "Qty", text: $newQty, keyboard: .decimalPad, mono: true)
                        .frame(width: 80)
                    BrutalField(prompt: "Price €", text: $newPrice, keyboard: .decimalPad, mono: true)
                    Button(adding ? "Adding…" : "Add") { add() }
                        .buttonStyle(SlabButtonStyle(fill: BP.yellow, border: BT.borderThin, shadow: 0, height: 46, fullWidth: false, font: BF.label(15)))
                        .disabled(adding)
                }
                if addError {
                    Text("Enter an item name and a price.")
                        .font(BF.body(13, .semibold))
                        .foregroundStyle(BP.redText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func add() {
        let price = Double(newPrice.replacingOccurrences(of: ",", with: "."))
        let qty = Double(newQty.replacingOccurrences(of: ",", with: ".")) ?? 1
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty, let price else {
            addError = true
            return
        }
        addError = false
        adding = true
        let id = receipt.id
        let name = newName
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            model.update(id) { receipt in
                let next = (receipt.items.map(\.id).max() ?? id * 100) + 1
                receipt.items.append(LabLineItem(id: next, itemDictionaryId: 9000 + next, rawText: nil, nameDe: name, quantity: qty,
                                                 unitPrice: price, translationEn: nil, category: "Other",
                                                 subcategory: "Miscellaneous", itemGroup: "General"))
            }
            adding = false
            newName = ""
            newQty = "1"
            newPrice = ""
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Items total:")
                    .font(BF.body(15, .semibold))
                    .foregroundStyle(BP.text)
                Spacer()
                Text(LabFormat.money(receipt.computedSum))
                    .font(BF.mono(16))
                    .foregroundStyle(BP.text)
            }
            HStack {
                Text("Printed total:")
                    .font(BF.body(15, .semibold))
                    .foregroundStyle(BP.text)
                Spacer()
                HStack(spacing: 4) {
                    Text("€").font(BF.mono(16)).foregroundStyle(BP.text)
                    BrutalField(prompt: "0.00", text: $printed, keyboard: .decimalPad, mono: true, alignment: .trailing, height: 44, fontSize: 17)
                        .frame(width: 104)
                }
            }
        }
        .padding(14)
    }
}

// MARK: Processing panel

struct BrutalProcessingPanel: View {
    let model: BrutalModel
    let receipt: LabReceipt
    let processing: LabProcessing

    private var failed: Bool { !processing.isActive }

    private var message: String {
        switch processing {
        case .waitingForUpload(let error):
            return "The photo is saved on this Mac and uploads as soon as the server is reachable." + (error.map { " Last attempt: \($0)" } ?? "")
        case .processing:
            return "The server reads the photo; the result appears here by itself."
        case .uploadFailed(let error):
            return (error.map { $0 + " " } ?? "") + "Retry, or remove this receipt and add a clearer photo."
        case .failed(let error):
            return (error.map { $0 + " " } ?? "") + "Retry it, or fill in the fields below by hand."
        }
    }

    private var ink: Color { failed ? BP.onRed : BP.onAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if processing.isActive { BlockSpinner(size: 18, color: ink) }
                Text(processing.label)
                    .font(BF.label(16))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message)
                .font(BF.body(14))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            switch processing {
            case .uploadFailed:
                HStack(spacing: 10) {
                    Button("Retry upload") { model.update(receipt.id) { $0.processing = .waitingForUpload(nil) } }
                        .buttonStyle(.slabSmall())
                    Button("Remove receipt") {
                        model.softDelete(receipt.id)
                        model.route = nil
                    }
                    .buttonStyle(.slabSmall(BP.card, ink: BP.redText))
                }
            case .failed:
                Button("Retry extraction") { model.update(receipt.id) { $0.processing = .processing } }
                    .buttonStyle(.slabSmall())
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(failed ? BP.redFill : BP.blue)
    }
}

// MARK: Items

struct BrutalItemGroup: View {
    let model: BrutalModel
    let receipt: LabReceipt
    let group: [LabLineItem]
    let startsEdited: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                    BrutalItemRow(model: model, receiptID: receipt.id, item: item, startsEdited: startsEdited && index == 0)
                        .id("item-\(item.id)")
                    if index < group.count - 1 { BP.line.frame(height: BT.ruleThin) }
                }
            }
            if group.count > 1 {
                ZStack {
                    BracketShape()
                        .stroke(BP.line, style: StrokeStyle(lineWidth: BT.border, lineCap: .square, lineJoin: .miter))
                        .frame(width: 10)
                        .padding(.vertical, 12)
                    Sticker(text: "\(group.count)×", angle: -BT.tiltSticker, font: BF.mono(12))
                        .offset(x: 3)
                }
                .frame(width: 38)
                .padding(.trailing, 6)
            }
        }
    }
}

/// A compact summary that taps open into the full inline editor. Flagged items start open.
struct BrutalItemRow: View {
    let model: BrutalModel
    let receiptID: Int
    let item: LabLineItem

    enum SaveState { case idle, saving, saved, failed }

    @State private var expanded: Bool
    @State private var qty: String
    @State private var price: String
    @State private var translation: String
    @State private var category: String
    @State private var subcategory: String
    @State private var itemGroup: String
    @State private var pickersChanged: Bool
    @State private var saveState: SaveState = .idle

    init(model: BrutalModel, receiptID: Int, item: LabLineItem, startsEdited: Bool) {
        self.model = model
        self.receiptID = receiptID
        self.item = item
        _expanded = State(initialValue: item.needsReview || startsEdited || model.route?.expandItemID == item.id)
        _qty = State(initialValue: LabFormat.quantity(item.quantity))
        _price = State(initialValue: String(format: "%.2f", item.unitPrice))
        _translation = State(initialValue: item.translationEn ?? "")
        // The edited fixture moves the row to another item group, unsaved.
        let group = startsEdited ? "Butter & Cream" : item.itemGroup
        _category = State(initialValue: item.category)
        _subcategory = State(initialValue: item.subcategory)
        _itemGroup = State(initialValue: group)
        _pickersChanged = State(initialValue: startsEdited)
    }

    private var parsedQty: Double? { Double(qty.replacingOccurrences(of: ",", with: ".")) }
    private var parsedPrice: Double? { Double(price.replacingOccurrences(of: ",", with: ".")) }
    private var total: Double? {
        guard let parsedQty, let parsedPrice else { return nil }
        return ((parsedQty * parsedPrice) * 100).rounded() / 100
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
        VStack(alignment: .leading, spacing: 0) {
            summary
            if expanded { editor }
        }
        .background(item.needsReview ? BP.flagFill : Color.clear)
    }

    private var summary: some View {
        Button {
            KeyboardWatcher.dismiss()
            withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(BP.text)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.nameDe ?? "")
                        .font(BF.body(15, .semibold))
                        .foregroundStyle(BP.text)
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    if !expanded {
                        HStack(spacing: 0) {
                            if !translation.isEmpty {
                                Text(translation + " · ").lineLimit(1)
                            }
                            Text(category).lineLimit(1).fixedSize()
                        }
                        .font(BF.body(12))
                        .foregroundStyle(BP.text2)
                    }
                }
                Spacer(minLength: 6)
                if !expanded {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(LabFormat.money(total))
                            .font(BF.mono(14))
                            .foregroundStyle(BP.text)
                        Text("\(qty) × \(price)")
                            .font(BF.mono(11, .regular))
                            .foregroundStyle(BP.text2)
                            .lineLimit(1)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the editor")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BrutalField(prompt: "Qty", text: $qty, keyboard: .decimalPad, mono: true, alignment: .center, height: 44, fontSize: 14)
                    .frame(width: 66)
                Text("×").font(BF.mono(15)).foregroundStyle(BP.text)
                BrutalField(prompt: "Price", text: $price, keyboard: .decimalPad, mono: true, alignment: .center, height: 44, fontSize: 14)
                    .frame(width: 72)
                Text("=").font(BF.mono(15)).foregroundStyle(BP.text)
                Text(LabFormat.money(total))
                    .font(BF.mono(15))
                    .foregroundStyle(BP.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            BrutalField(prompt: "Translation", text: $translation, height: 44, fontSize: 14)
            BrutalPicker(label: "Category", value: category, options: LabTaxonomy.categoryNames) { value in
                guard value != category else { return }
                category = value
                subcategory = LabTaxonomy.subcategoryNames(in: value).first ?? ""
                itemGroup = LabTaxonomy.itemGroups(category: value, subcategory: subcategory).first ?? ""
                changed()
            }
            BrutalPicker(label: "Subcategory", value: subcategory, options: LabTaxonomy.subcategoryNames(in: category)) { value in
                guard value != subcategory else { return }
                subcategory = value
                itemGroup = LabTaxonomy.itemGroups(category: category, subcategory: value).first ?? ""
                changed()
            }
            BrutalPicker(label: "Item group", value: itemGroup, options: LabTaxonomy.itemGroups(category: category, subcategory: subcategory)) { value in
                guard value != itemGroup else { return }
                itemGroup = value
                changed()
            }
            if pickersChanged {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Saving updates the dictionary entry, so it applies to 3 line items across 2 receipts.")
                        .font(BF.body(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(BP.onAccent)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BP.blue)
                .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
            }
            HStack(spacing: 10) {
                Button(saveLabel) { save() }
                    .buttonStyle(.slabSmall(saveState == .failed ? BP.redFill : BP.yellow,
                                            ink: saveState == .failed ? BP.onRed : BP.onAccent))
                    .disabled(saveState == .saving)
                Spacer()
                IconBlock(system: "trash", label: "Delete item") {
                    model.update(receiptID) { $0.items.removeAll { $0.id == item.id } }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func changed() {
        pickersChanged = true
        saveState = .idle
    }

    private func save() {
        guard parsedQty != nil, parsedPrice != nil else {
            saveState = .failed
            return
        }
        saveState = .saving
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            saveState = .saved
            pickersChanged = false
            try? await Task.sleep(for: .seconds(1.4))
            if saveState == .saved { saveState = .idle }
        }
    }
}

// MARK: Photo tab

struct BrutalPhotoTab: View {
    let receipt: LabReceipt

    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat = 1

    private var hasPhoto: Bool { receipt.photoNote == nil }

    var body: some View {
        VStack(spacing: 0) {
            bar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            if hasPhoto { photo } else { missing }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Text("Photo")
                .font(BF.label(14))
                .foregroundStyle(BP.text)
            Spacer(minLength: 0)
            IconBlock(system: "minus.magnifyingglass", label: "Zoom out") { scale = max(1, scale / 1.5) }
            Button("Fit") { scale = 1 }.buttonStyle(.slabSmall())
            Button("100%") { scale = 2 }.buttonStyle(.slabSmall())
            IconBlock(system: "plus.magnifyingglass", label: "Zoom in") { scale = min(8, scale * 1.5) }
        }
        .disabled(!hasPhoto)
        .opacity(hasPhoto ? 1 : 0.45)
    }

    private var photo: some View {
        GeometryReader { geo in
            ScrollView(scale > 1 ? [.horizontal, .vertical] : []) {
                ReceiptPhotoPlaceholder(receipt: receipt)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: geo.size.width * scale, height: geo.size.height * scale, alignment: .topLeading)
            }
            .gesture(MagnifyGesture()
                .onChanged { scale = min(8, max(1, pinchStart * $0.magnification)) }
                .onEnded { _ in pinchStart = scale })
        }
        .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.border))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var missing: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(BP.onAccent)
                .frame(width: 60, height: 60)
                .background(BP.yellow)
                .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.border))
                .rotationEffect(.degrees(-BT.tiltSticker))
            Text(receipt.photoNote ?? "")
                .font(BF.body(17, .semibold))
                .foregroundStyle(BP.text)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}
