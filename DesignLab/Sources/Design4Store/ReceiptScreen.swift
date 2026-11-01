import LabCore
import SwiftUI

// MARK: The receipt: paper fed from a fixed printer, a key deck below

struct ReceiptScreen: View {
    @Bindable var model: StoreModel
    private let route: DetailRoute

    @State private var keyboard = KeyboardWatcher()
    @State private var stamp: StampPhase = .none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum StampPhase { case none, falling, inked }

    init(model: StoreModel) {
        self.model = model
        route = model.route ?? DetailRoute(receiptID: 0)
    }

    private var current: DetailRoute { model.route ?? route }
    private var receipt: LabReceipt? { model.receipt(id: current.receiptID) }
    private var title: String { current.loading ? "Receipt" : (receipt?.store?.isEmpty == false ? receipt!.store! : "Receipt") }
    private var isReviewed: Bool { receipt?.reviewedAt != nil }

    var body: some View {
        VStack(spacing: 0) {
            printer
            ZStack {
                content
                stampOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if keyboard.isVisible {
                doneDeck
            } else if !current.loading {
                keyDeck
            }
        }
        .background(SP.counter.ignoresSafeArea())
        .overlay(alignment: .leading) {
            // Edge swipe back, since this is a custom push
            Color.clear
                .frame(width: 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                    if value.translation.width > 50 { close() }
                })
        }
    }

    private func close() {
        KeyboardWatcher.dismiss()
        model.route = nil
    }

    // MARK: Printer

    private var printer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                IconKey(systemName: "chevron.left", label: "Back", action: close)
                Text(title)
                    .font(SF.sign(26))
                    .foregroundStyle(SP.tillText)
                    .padding(.top, 5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Color.clear.frame(width: 44, height: 44)
            }
            if !current.loading {
                HStack(spacing: 6) {
                    tabKey("Items", selected: !current.photoTab) { model.route?.photoTab = false }
                    tabKey("Photo", selected: current.photoTab) {
                        KeyboardWatcher.dismiss()
                        model.route?.photoTab = true
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(SP.till.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { PrinterSlot().offset(y: 7) }
        .padding(.bottom, 7)
        .zIndex(1)
    }

    private func tabKey(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { WideLabel(text: title) }
            .buttonStyle(KeycapStyle(face: selected ? SP.tag : SP.key, lip: selected ? SP.dividerBottom : SP.keyLip,
                                     ink: selected ? SP.tagInk : SP.keyText, font: SF.shelf(15)))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if current.loading {
            ScanBeam(width: 120, height: 56, barColor: SP.counterText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let receipt {
            if current.photoTab {
                PegboardPhoto(receipt: receipt)
            } else {
                ReceiptPaper(model: model, receipt: receipt, route: current)
                    .overlay {
                        if current.busy { workingBox }
                    }
            }
        }
    }

    private var workingBox: some View {
        VStack(spacing: 10) {
            ScanBeam(width: 92, height: 34)
            Text("Working…").font(SF.print(14, bold: true)).foregroundStyle(SP.ink)
        }
        .padding(18)
        .slip(top: true, bottom: true, shadow: 8)
    }

    // MARK: Stamp

    @ViewBuilder private var stampOverlay: some View {
        switch stamp {
        case .none: EmptyView()
        case .falling:
            StampMark(size: 34)
                .opacity(0)
                .overlay(RoundedRectangle(cornerRadius: 6).fill(SP.slot).shadow(radius: 10))
                .rotationEffect(.degrees(ST.stampTilt))
                .transition(.scale(scale: 2.4).combined(with: .opacity))
        case .inked:
            StampMark(size: 34)
                .rotationEffect(.degrees(ST.stampTilt))
                .transition(.identity)
        }
    }

    private func looksGood(_ id: Int) {
        KeyboardWatcher.dismiss()
        guard !reduceMotion else {
            Haptic.stamp()
            model.looksGood(id)
            return
        }
        Task {
            withAnimation(.easeIn(duration: 0.11)) { stamp = .falling }
            try? await Task.sleep(for: .seconds(0.11))
            Haptic.stamp()
            stamp = .inked
            try? await Task.sleep(for: .seconds(ST.stampSeconds - 0.11))
            model.looksGood(id)
        }
    }

    // MARK: Key deck

    private var keyDeck: some View {
        HStack(spacing: 8) {
            if isReviewed {
                Button {} label: { WideLabel(text: "Reviewed ✓") }
                    .buttonStyle(.key)
                    .disabled(true)
            } else {
                Button {
                    if let id = receipt?.id, stamp == .none { looksGood(id) }
                } label: { WideLabel(text: "Looks good") }
                    .buttonStyle(.keyGo)
                    .disabled(current.busy)
            }
            Menu {
                if receipt?.photoLocation == "server" {
                    Button("Re-run extraction…") { model.dialog = .rerun }
                }
                Button("Delete receipt…", role: .destructive) { model.dialog = .delete }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(current.busy ? SP.keyDisabledText : SP.keyText)
                    .frame(width: 48, height: 41)
                    .background(current.busy ? SP.keyDisabled : SP.key, in: RoundedRectangle(cornerRadius: ST.keyRadius, style: .continuous))
                    .background(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: ST.keyRadius, style: .continuous).fill(SP.keyLip).offset(y: ST.keyLip)
                    }
                    .padding(.bottom, ST.keyLip)
            }
            .disabled(current.busy)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(SP.till.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { SP.tillEdge.frame(height: 1) }
    }

    private var doneDeck: some View {
        HStack {
            Spacer()
            Button("Done") { KeyboardWatcher.dismiss() }
                .buttonStyle(.keyTag)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(SP.till)
    }
}

/// The ink a `REVIEWED` stamp leaves.
struct StampMark: View {
    var size: CGFloat = 26

    var body: some View {
        Text("REVIEWED")
            .font(SF.sign(size))
            .tracking(size / 12)
            .foregroundStyle(SP.stampInk)
            .padding(.top, size * 0.2)
            .padding(.horizontal, size * 0.4)
            .padding(.vertical, size * 0.1)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SP.stampInk, lineWidth: max(2, size / 12)))
            .accessibilityLabel("Reviewed")
    }
}

// MARK: The paper

private struct ReceiptPaper: View {
    @Bindable var model: StoreModel
    let receipt: LabReceipt
    let route: DetailRoute

    @State private var storeText: String
    @FocusState private var storeFocused: Bool
    @State private var expanded: Set<Int>
    @State private var addOpen: Bool
    @State private var printedTotal: String

    init(model: StoreModel, receipt: LabReceipt, route: DetailRoute) {
        self.model = model
        self.receipt = receipt
        self.route = route
        _storeText = State(initialValue: receipt.store ?? "")
        var open = Set(receipt.items.filter(\.needsReview).map(\.id))
        if let id = route.expandItemID { open.insert(id) }
        if route.editedFixture, let first = receipt.items.first { open.insert(first.id) }
        _expanded = State(initialValue: open)
        _addOpen = State(initialValue: route.addItemFixture)
        _printedTotal = State(initialValue: receipt.total.map { String(format: "%.2f", $0) } ?? "")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let processing = receipt.processing { processingPanel(processing) }
                    head
                    dateRow
                    if !receipt.reviewReasons.isEmpty && receipt.processing == nil { warningNote }
                    items
                    addItem
                    footer
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .top) {
                    TornPaper(top: false, bottom: true)
                        .fill(SP.paper)
                        .shadow(color: SP.shadow.opacity(0.28), radius: 3, y: 2)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
                .disabled(route.busy)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                guard let id = route.expandItemID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Head

    private var head: some View {
        VStack(spacing: 4) {
            Text("— KASSENBON #\(String(receipt.id)) —")
                .font(SF.print(11))
                .foregroundStyle(SP.ink2)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            ZStack(alignment: .trailing) {
                TextField("", text: $storeText, prompt: Text("Store").foregroundStyle(SP.ink2))
                    .font(SF.print(22, bold: true))
                    .foregroundStyle(SP.ink)
                    .tint(SP.printRed)
                    .multilineTextAlignment(.center)
                    .focused($storeFocused)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 44)
                    .frame(minHeight: 44)
                    .onChange(of: storeText) { _, value in
                        model.update(receipt.id) { $0.store = value.isEmpty ? nil : value }
                    }
                Button { model.dialog = .delete } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SP.ink)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(SP.ink, lineWidth: 1.25))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete receipt")
                .padding(.trailing, -8)
            }
            if storeFocused && !suggestions.isEmpty { suggestionList }
        }
        .overlay(alignment: .topLeading) {
            // The ink stays where it landed, clear of the data
            if receipt.reviewedAt != nil {
                StampMark(size: 19)
                    .rotationEffect(.degrees(ST.stampTilt))
                    .offset(x: 2, y: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var suggestions: [String] {
        let query = storeText.trimmingCharacters(in: .whitespaces).lowercased()
        let list = LabData.storeSuggestions.filter { query.isEmpty || $0.lowercased().contains(query) }
        return Array(list.filter { $0 != storeText }.prefix(5))
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions, id: \.self) { store in
                Button {
                    storeText = store
                    storeFocused = false
                } label: {
                    Text(store)
                        .font(SF.print(14))
                        .foregroundStyle(SP.ink)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { DottedRule() }
            }
        }
        .background(SP.paperShade)
    }

    // MARK: Date and time

    private var dateRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if let date = receipt.date {
                printedPicker(date, components: .date, selection: dateBinding)
            } else {
                Button("Set date") { model.update(receipt.id) { $0.date = "2026-10-31" } }
                    .buttonStyle(paperText)
            }
            if let time = receipt.time {
                printedPicker(time, components: .hourAndMinute, selection: timeBinding)
                Button { model.update(receipt.id) { $0.time = nil } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SP.ink2)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear time")
            } else {
                Button("+ Add time") { model.update(receipt.id) { $0.time = "12:00" } }
                    .buttonStyle(paperText)
            }
            Spacer(minLength: 0)
        }
    }

    private var paperText: PaperTextStyle { PaperTextStyle() }

    /// Printed text in Menlo, with the real compact system picker invisibly on top to take the tap.
    private func printedPicker(_ text: String, components: DatePickerComponents, selection: Binding<Date>) -> some View {
        ZStack {
            DatePicker("", selection: selection, displayedComponents: components)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(SP.pickerTint)
                .scaleEffect(1.2)
                .colorMultiply(.clear)
            Text(text)
                .font(SF.print(15))
                .foregroundStyle(SP.ink)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) { DottedRule() }
                .allowsHitTesting(false)
        }
        .frame(minHeight: 44)
    }

    private var dateBinding: Binding<Date> {
        Binding {
            LabFormat.date(receipt.date ?? "") ?? Date()
        } set: { date in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            model.update(receipt.id) { $0.date = f.string(from: date) }
        }
    }

    private var timeBinding: Binding<Date> {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return Binding {
            f.date(from: receipt.time ?? "") ?? Date()
        } set: { date in
            model.update(receipt.id) { $0.time = f.string(from: date) }
        }
    }

    // MARK: Note and processing

    /// The till staff's note, taped on the receipt.
    private var warningNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(receipt.reviewReasons, id: \.self) { reason in
                Text("⚠ \(reason)")
                    .font(SF.note(14))
                    .foregroundStyle(SP.tagInk)
                    .lineSpacing(-2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(SP.note)
        .overlay(alignment: .top) {
            SP.tape.opacity(0.85).frame(width: 62, height: 14).rotationEffect(.degrees(-2)).offset(y: -6)
        }
        .shadow(color: SP.shadow.opacity(0.22), radius: 2, y: 1.5)
        .rotationEffect(.degrees(ST.noteTilt))
        .padding(.vertical, 4)
    }

    @ViewBuilder private func processingPanel(_ processing: LabProcessing) -> some View {
        let isFailure = !processing.isActive
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !isFailure { ScanBeam(width: 34, height: 20) }
                Text(processing.label)
                    .font(SF.print(15, bold: true))
                    .foregroundStyle(isFailure ? SP.printRed : SP.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(panelMessage(processing))
                .font(SF.print(13))
                .foregroundStyle(isFailure ? SP.printRed : SP.ink2)
                .fixedSize(horizontal: false, vertical: true)
            switch processing {
            case .uploadFailed:
                HStack(spacing: 8) {
                    Button("Retry upload") { model.update(receipt.id) { $0.processing = .waitingForUpload(nil) } }
                        .buttonStyle(KeycapStyle(font: SF.shelf(14)))
                    Button("Remove receipt") {
                        model.softDelete(receipt.id)
                        model.route = nil
                    }
                    .buttonStyle(KeycapStyle(face: SP.keyRed, lip: SP.keyRedLip, ink: .white, font: SF.shelf(14)))
                }
            case .failed:
                Button("Retry extraction") { model.update(receipt.id) { $0.processing = .processing } }
                    .buttonStyle(KeycapStyle(font: SF.shelf(14)))
            default:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().strokeBorder(isFailure ? SP.printRed : SP.rule, style: StrokeStyle(lineWidth: isFailure ? 1.5 : 1, dash: isFailure ? [] : [3, 3])))
    }

    private func panelMessage(_ processing: LabProcessing) -> String {
        switch processing {
        case .waitingForUpload(let error):
            let last = error.map { " Last attempt: \($0)" } ?? ""
            return "The photo is saved on this Mac and uploads as soon as the server is reachable.\(last)"
        case .processing:
            return "The server reads the photo; the result appears here by itself."
        case .uploadFailed(let error):
            return "\(error ?? "") Retry, or remove this receipt and add a clearer photo."
        case .failed(let error):
            return "\(error ?? "") Retry it, or fill in the fields below by hand."
        }
    }

    // MARK: Items

    @ViewBuilder private var items: some View {
        if !receipt.items.isEmpty {
            VStack(spacing: 0) {
                DottedRule()
                ForEach(receipt.groupedItems, id: \.first?.id) { group in
                    itemGroup(group)
                    DottedRule()
                }
            }
        }
    }

    private func itemGroup(_ group: [LabLineItem]) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(group) { item in
                    PrintedItem(
                        model: model, receiptID: receipt.id, item: item,
                        isOpen: Binding(
                            get: { expanded.contains(item.id) },
                            set: { open in
                                withAnimation(ST.unfold) {
                                    if open { expanded.insert(item.id) } else { expanded.remove(item.id) }
                                }
                            }
                        ),
                        editedFixture: route.editedFixture && item.id == receipt.items.first?.id
                    )
                    .id(item.id)
                }
            }
            if group.count > 1 { repeatBracket(group.count) }
        }
    }

    private func repeatBracket(_ count: Int) -> some View {
        HStack(spacing: 3) {
            VStack(spacing: 0) {
                SP.ink.frame(width: 6, height: 1.5)
                SP.ink.frame(width: 1.5).frame(maxHeight: .infinity).frame(width: 6, alignment: .trailing)
                SP.ink.frame(width: 6, height: 1.5)
            }
            .padding(.vertical, 8)
            Text("\(count)×")
                .font(SF.print(13, bold: true))
                .foregroundStyle(SP.ink)
        }
        .padding(.leading, 4)
    }

    // MARK: Add item

    private var addItem: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(ST.unfold) { addOpen.toggle() }
            } label: {
                Text(addOpen ? "– Cancel" : "+ Add missing item")
                    .font(SF.print(14, bold: true))
                    .foregroundStyle(SP.ink)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if addOpen { AddItemForm(model: model, receiptID: receipt.id) { addOpen = false } }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                SP.ink.frame(height: 1.5)
                SP.ink.frame(height: 1.5)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Items total:").font(SF.print(14))
                DotLeader()
                Text(LabFormat.money(receipt.computedSum)).font(SF.print(14, bold: true))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Printed total:").font(SF.print(15, bold: true)).lineLimit(1).fixedSize()
                DotLeader()
                Text("€").font(SF.print(17, bold: true))
                TextField("", text: $printedTotal, prompt: Text("0.00").foregroundStyle(SP.ink2))
                    .font(SF.print(17, bold: true))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .tint(SP.printRed)
                    .frame(width: 72)
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { DottedRule().padding(.bottom, 8) }
                    .onChange(of: printedTotal) { _, value in
                        model.update(receipt.id) { $0.total = Double(value.replacingOccurrences(of: ",", with: ".")) }
                    }
            }
            VStack(spacing: 6) {
                Barcode(seed: receipt.id)
                    .frame(height: 44)
                    .padding(.horizontal, 36)
                Text("VIELEN DANK")
                    .font(SF.print(11))
                    .accessibilityHidden(true)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(SP.ink)
    }
}

private struct PaperTextStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SF.print(15, bold: true))
            .foregroundStyle(SP.ink)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
    }
}

// MARK: A printed line that unfolds

private struct PrintedItem: View {
    @Bindable var model: StoreModel
    let receiptID: Int
    let item: LabLineItem
    @Binding var isOpen: Bool

    @State private var qty: String
    @State private var price: String
    @State private var translation: String
    @State private var category: String
    @State private var subcategory: String
    @State private var itemGroup: String
    @State private var save: SaveState = .idle

    private enum SaveState { case idle, saving, saved, bad }

    init(model: StoreModel, receiptID: Int, item: LabLineItem, isOpen: Binding<Bool>, editedFixture: Bool) {
        self.model = model
        self.receiptID = receiptID
        self.item = item
        _isOpen = isOpen
        _qty = State(initialValue: LabFormat.quantity(item.quantity))
        _price = State(initialValue: String(format: "%.2f", item.unitPrice))
        _translation = State(initialValue: item.translationEn ?? "")
        _category = State(initialValue: item.category)
        _subcategory = State(initialValue: editedFixture ? "Beverages" : item.subcategory)
        _itemGroup = State(initialValue: editedFixture ? "Juice" : item.itemGroup)
    }

    private var pickersChanged: Bool {
        category != item.category || subcategory != item.subcategory || itemGroup != item.itemGroup
    }

    private var liveTotal: Double? {
        guard let q = number(qty), let p = number(price) else { return nil }
        return ((q * p) * 100).rounded() / 100
    }

    private func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(SP.ink2)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.nameDe ?? item.rawText ?? "—")
                            .font(SF.print(14, bold: true))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        if item.quantity != 1 && !isOpen {
                            Text("\(LabFormat.quantity(item.quantity)) × \(LabFormat.money(item.unitPrice))")
                                .font(SF.print(12))
                                .foregroundStyle(SP.ink2)
                        }
                    }
                    .layoutPriority(1)
                    DotLeader()
                    Text(LabFormat.money(item.totalPrice))
                        .font(SF.print(14, bold: true))
                        .layoutPriority(2)
                }
                .foregroundStyle(SP.ink)
                .padding(.horizontal, 4)
                .padding(.vertical, 9)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Collapses the editor" : "Opens the editor")

            if isOpen { editor }
        }
        .background(item.needsReview ? SP.highlighter : Color.clear)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                numberField("Qty", text: $qty, width: 62)
                Text("×").font(SF.print(14, bold: true))
                numberField("Price", text: $price, width: 76)
                Text("=").font(SF.print(14, bold: true))
                Text(liveTotal.map { LabFormat.money($0) } ?? "—")
                    .font(SF.print(14, bold: true))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Translation").font(SF.print(12)).foregroundStyle(SP.ink2)
                TextField("", text: $translation, prompt: Text("Translation").foregroundStyle(SP.ink2))
                    .font(SF.print(14))
                    .tint(SP.printRed)
                    .autocorrectionDisabled()
                    .frame(minHeight: 40)
                    .overlay(alignment: .bottom) { SP.ink.frame(height: 1) }
            }
            VStack(spacing: 0) {
                picker("Category", value: category, options: LabTaxonomy.categoryNames) { new in
                    category = new
                    subcategory = LabTaxonomy.subcategoryNames(in: new).first ?? ""
                    itemGroup = LabTaxonomy.itemGroups(category: new, subcategory: subcategory).first ?? ""
                }
                DottedRule()
                picker("Subcategory", value: subcategory, options: LabTaxonomy.subcategoryNames(in: category)) { new in
                    subcategory = new
                    itemGroup = LabTaxonomy.itemGroups(category: category, subcategory: new).first ?? ""
                }
                DottedRule()
                picker("Item group", value: itemGroup, options: LabTaxonomy.itemGroups(category: category, subcategory: subcategory)) { new in
                    itemGroup = new
                }
            }
            if pickersChanged {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 14, weight: .semibold))
                    Text("Saving updates the dictionary entry, so it applies to 3 line items across 2 receipts.")
                        .font(SF.print(12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(SP.ink)
            }
            HStack(spacing: 8) {
                Button { commit() } label: { WideLabel(text: saveTitle) }
                    .buttonStyle(save == .bad ? KeycapStyle.keyStop : KeycapStyle(face: SP.tag, lip: SP.dividerBottom, ink: SP.tagInk, font: SF.shelf(15)))
                    .disabled(save == .saving)
                Button {
                    model.update(receiptID) { $0.items.removeAll { $0.id == item.id } }
                } label: {
                    Image(systemName: "trash").font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(KeycapStyle(face: SP.paperShade, lip: SP.rule, ink: SP.printRed, width: 48))
                .accessibilityLabel("Delete item")
            }
        }
        .font(SF.print(14))
        .foregroundStyle(SP.ink)
        .padding(.leading, 22)
        .padding(.trailing, 4)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var saveTitle: String {
        switch save {
        case .idle: return "Save"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .bad: return "Bad qty/price"
        }
    }

    private func commit() {
        guard let q = number(qty), let p = number(price), q > 0 else {
            save = .bad
            return
        }
        KeyboardWatcher.dismiss()
        save = .saving
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            model.update(receiptID) { receipt in
                guard let i = receipt.items.firstIndex(where: { $0.id == item.id }) else { return }
                receipt.items[i].quantity = q
                receipt.items[i].unitPrice = p
                receipt.items[i].translationEn = translation.isEmpty ? nil : translation
                receipt.items[i].category = category
                receipt.items[i].subcategory = subcategory
                receipt.items[i].itemGroup = itemGroup
                receipt.items[i].needsReview = false
            }
            save = .saved
        }
    }

    private func numberField(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField("", text: text, prompt: Text(label).foregroundStyle(SP.ink2))
            .font(SF.print(14, bold: true))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .tint(SP.printRed)
            .frame(width: width, height: 40)
            .overlay(alignment: .bottom) { SP.ink.frame(height: 1) }
            .accessibilityLabel(label)
    }

    private func picker(_ label: String, value: String, options: [String], choose: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(Array(Set(options)).sorted { (options.firstIndex(of: $0) ?? 0) < (options.firstIndex(of: $1) ?? 0) }, id: \.self) { option in
                Button {
                    choose(option)
                    save = .idle
                } label: {
                    if option == value { Label(option, systemImage: "checkmark") } else { Text(option) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(SF.print(12)).foregroundStyle(SP.ink2)
                Spacer(minLength: 4)
                Text(value)
                    .font(SF.print(13, bold: true))
                    .foregroundStyle(SP.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SP.ink2)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}

// MARK: Add form

private struct AddItemForm: View {
    @Bindable var model: StoreModel
    let receiptID: Int
    let done: () -> Void

    @State private var name = ""
    @State private var qty = "1"
    @State private var price = ""
    @State private var error = false
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Item name", text: $name).autocorrectionDisabled()
            HStack(spacing: 12) {
                field("Qty", text: $qty).keyboardType(.decimalPad).frame(width: 80)
                field("Price €", text: $price).keyboardType(.decimalPad)
            }
            if error {
                Text("Enter an item name and a price.")
                    .font(SF.print(13, bold: true))
                    .foregroundStyle(SP.printRed)
            }
            Button { add() } label: { WideLabel(text: adding ? "Adding…" : "Add") }
                .buttonStyle(.keyTag)
                .disabled(adding)
        }
        .padding(10)
        .background(SP.paperShade)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(label).foregroundStyle(SP.ink2))
            .font(SF.print(14))
            .foregroundStyle(SP.ink)
            .tint(SP.printRed)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) { SP.ink.frame(height: 1).padding(.bottom, 4) }
            .accessibilityLabel(label)
    }

    private func add() {
        let q = Double(qty.replacingOccurrences(of: ",", with: ".")) ?? 1
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let p = Double(price.replacingOccurrences(of: ",", with: ".")) else {
            error = true
            return
        }
        error = false
        adding = true
        KeyboardWatcher.dismiss()
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            model.update(receiptID) { receipt in
                let id = (receipt.items.map(\.id).max() ?? receipt.id * 100) + 1
                receipt.items.append(LabLineItem(id: id, itemDictionaryId: 10_000 + id, rawText: name, nameDe: name, quantity: q,
                                                 unitPrice: p, translationEn: nil, category: "Other",
                                                 subcategory: "Miscellaneous", itemGroup: "General"))
            }
            done()
        }
    }
}

// MARK: The original, clipped to a pegboard

private struct PegboardPhoto: View {
    let receipt: LabReceipt
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat = 1

    private var missing: Bool { receipt.photoNote != nil }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                Pegboard()
                if let note = receipt.photoNote {
                    missingCard(note)
                } else {
                    photo
                }
            }
            .clipped()
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Text("PHOTO")
                .font(SF.sign(19))
                .foregroundStyle(SP.counterText)
                .padding(.top, 3)
            Spacer(minLength: 4)
            IconKey(systemName: "minus.magnifyingglass", label: "Zoom out") { setScale(scale / 1.5) }
            Button("Fit") { setScale(1) }.buttonStyle(KeycapStyle(font: SF.shelf(14)))
            Button("100%") { setScale(2) }.buttonStyle(KeycapStyle(font: SF.shelf(14)))
            IconKey(systemName: "plus.magnifyingglass", label: "Zoom in") { setScale(scale * 1.5) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .disabled(missing)
    }

    private func setScale(_ value: CGFloat) {
        withAnimation(.snappy(duration: 0.18)) {
            scale = min(8, max(1, value))
            pinchStart = scale
        }
    }

    private var photo: some View {
        GeometryReader { geo in
            let inset: CGFloat = 16
            let w = geo.size.width - inset * 2
            let h = geo.size.height - inset * 2 - 16
            ScrollView([.horizontal, .vertical]) {
                ReceiptPhotoPlaceholder(receipt: receipt)
                    .frame(width: w, height: h)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: w * scale, height: h * scale, alignment: .topLeading)
            }
            .frame(width: w, height: h)
            .shadow(color: SP.shadow.opacity(0.35), radius: 4, y: 2)
            .gesture(MagnifyGesture()
                .onChanged { scale = min(8, max(1, pinchStart * $0.magnification)) }
                .onEnded { _ in pinchStart = scale })
            .overlay(alignment: .top) { BulldogClip().offset(y: -14) }
            .position(x: geo.size.width / 2, y: inset + 16 + h / 2)
        }
    }

    private func missingCard(_ note: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 30, weight: .medium))
            Text(note)
                .font(SF.print(15, bold: true))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(SP.ink)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 26)
        .frame(maxWidth: 280)
        .slip(shadow: 4)
        .overlay(alignment: .top) { BulldogClip().offset(y: -14) }
    }
}

/// A perforated board, drawn cheaply.
private struct Pegboard: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            var y: CGFloat = 8
            while y < size.height {
                var x: CGFloat = 8
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 4, height: 4)), with: .color(SP.pegHole))
                    x += step
                }
                y += step
            }
        }
        .background(SP.peg)
        .accessibilityHidden(true)
    }
}

private struct BulldogClip: View {
    var body: some View {
        VStack(spacing: 0) {
            // Loop
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(SP.clip, lineWidth: 2.5)
                .frame(width: 34, height: 14)
                .padding(.bottom, -3)
            // Jaw
            RoundedRectangle(cornerRadius: 3)
                .fill(SP.slot)
                .frame(width: 66, height: 18)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}
