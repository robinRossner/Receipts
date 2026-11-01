import LabCore
import SwiftUI

struct ReceiptDetailView: View {
    let model: GlassModel

    var body: some View {
        if let detail = model.detail {
            DetailContent(model: model, detail: detail)
                .id(detail.receipt.id)
        }
    }
}

private struct DetailContent: View {
    let model: GlassModel
    @Bindable var detail: DetailState
    @FocusState private var storeFocused: Bool

    private var title: String {
        if let store = detail.receipt.store, !store.isEmpty, !detail.loading { return store }
        return "Receipt"
    }

    var body: some View {
        Group {
            if detail.loading {
                ProgressView().controlSize(.large)
            } else {
                content
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var content: some View {
        Group {
            switch detail.page {
            case .items: itemsPage
            case .photo: PhotoPage(receipt: detail.receipt)
            }
        }
        .safeAreaBar(edge: .top) {
            Picker("Page", selection: $detail.page) {
                ForEach(DetailState.Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .safeAreaBar(edge: .bottom) { actionBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete receipt", systemImage: "trash") { detail.confirmDelete = true }
                    .disabled(detail.busy)
                    .confirmationDialog("Delete this receipt?", isPresented: $detail.confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { model.deleteCurrent() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("It moves to \"Recently deleted\" and can be restored from there.")
                    }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
    }

    private func hideKeyboard() {
        storeFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Action bar

    private var actionBar: some View {
        let reviewed = detail.receipt.reviewedAt != nil
        return GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation { model.confirmCurrent() }
                } label: {
                    Text(reviewed ? "Reviewed ✓" : "Looks good")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(reviewed || detail.busy)

                Menu {
                    if detail.receipt.photoLocation == "server" {
                        Button("Re-run extraction…", systemImage: "arrow.clockwise") { detail.confirmRerun = true }
                    }
                    Button("Delete receipt…", systemImage: "trash", role: .destructive) { detail.confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(height: 22)
                        .accessibilityLabel("More")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(detail.busy)
                .confirmationDialog("Re-run extraction?", isPresented: $detail.confirmRerun, titleVisibility: .visible) {
                    Button("Re-run extraction", role: .destructive) {
                        detail.busy = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            detail.busy = false
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The server reads the photo again and marks the receipt as not yet reviewed. If you already edited or confirmed this receipt, the server keeps your version.")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Items page

    private var itemsPage: some View {
        ScrollViewReader { proxy in
            List {
                if let processing = detail.receipt.processing {
                    ProcessingSection(model: model, processing: processing)
                }
                headerSection
                if !detail.receipt.reviewReasons.isEmpty {
                    Section {
                        ForEach(detail.receipt.reviewReasons, id: \.self) { reason in
                            Label {
                                Text(reason).font(.subheadline)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            .listRowBackground(Color.orange.opacity(0.14))
                        }
                    }
                }
                Section {
                    ForEach(detail.receipt.groupedItems, id: \.first!.id) { group in
                        ItemGroupRows(detail: detail, group: group)
                    }
                    addRows
                } header: {
                    Text("Items").textCase(nil)
                }
                Section {
                    LabeledContent("Items total") {
                        Text(LabFormat.money(detail.receipt.computedSum)).amount()
                    }
                    LabeledContent("Printed total") {
                        HStack(spacing: 2) {
                            Text("€")
                            TextField("0.00", text: $detail.printedTotal)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(detail.busy)
            .overlay {
                if detail.busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Working…").font(.headline)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }
            }
            .task {
                if let target = detail.scrollTarget {
                    detail.scrollTarget = nil
                    try? await Task.sleep(for: .seconds(0.3))
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
    }

    private var storeText: Binding<String> {
        Binding(get: { detail.receipt.store ?? "" }, set: { detail.receipt.store = $0.isEmpty ? nil : $0 })
    }

    private var suggestions: [String] {
        let typed = (detail.receipt.store ?? "").lowercased()
        let matches = LabData.storeSuggestions.filter { typed.isEmpty || ($0.lowercased().contains(typed) && $0.lowercased() != typed) }
        return Array(matches.prefix(5))
    }

    @ViewBuilder
    private var headerSection: some View {
        Section {
            TextField("Store", text: storeText)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .focused($storeFocused)
            if storeFocused {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        detail.receipt.store = suggestion
                        storeFocused = false
                    }
                }
            }
            if let date = detail.date {
                DatePicker("Date", selection: Binding(get: { date }, set: { detail.date = $0 }), displayedComponents: .date)
            } else {
                Button("Set date") { detail.date = LabFormat.date("2026-10-31") }
            }
            if let time = detail.time {
                HStack {
                    DatePicker("Time", selection: Binding(get: { time }, set: { detail.time = $0 }), displayedComponents: .hourAndMinute)
                    Button("Clear time", systemImage: "xmark.circle.fill") { detail.time = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                }
            } else {
                Button("+ Add time") { detail.time = DetailState.parseTime("12:00") }
            }
        }
    }

    // MARK: Add item

    @ViewBuilder
    private var addRows: some View {
        Button {
            withAnimation(.snappy) {
                detail.addOpen.toggle()
                detail.addOpenedByHand = detail.addOpen
                detail.addError = false
            }
        } label: {
            Label(
                detail.addOpen ? "Cancel" : "Add missing item",
                systemImage: detail.addOpen ? "minus.circle.fill" : "plus.circle.fill"
            )
        }
        .id("add")
        if detail.addOpen {
            TextField("Item name", text: $detail.addName)
            HStack(spacing: 12) {
                LabeledContent("Qty") { GlassNumberField(title: "1", text: $detail.addQty, width: 60) }
                    .fixedSize()
                Spacer()
                LabeledContent("Price €") { GlassNumberField(title: "0.00", text: $detail.addPrice) }
                    .fixedSize()
            }
            if detail.addError {
                Text("Enter an item name and a price.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button(detail.addBusy ? "Adding…" : "Add") {
                Task { await detail.addItem() }
            }
            .disabled(detail.addBusy)
        }
    }
}

// MARK: Processing panel

private struct ProcessingSection: View {
    let model: GlassModel
    let processing: LabProcessing

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if processing.isActive {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(processing.label)
                        .font(.headline)
                        .foregroundStyle(processing.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            switch processing {
            case .uploadFailed:
                Button("Retry upload") {}
                Button("Remove receipt", role: .destructive) { model.deleteCurrent() }
            case .failed:
                Button("Retry extraction") {}
            default:
                EmptyView()
            }
        }
    }

    private var message: String {
        switch processing {
        case .waitingForUpload(let error):
            return "The photo is saved on this Mac and uploads as soon as the server is reachable. Last attempt: \(error ?? "")"
        case .processing:
            return "The server reads the photo; the result appears here by itself."
        case .uploadFailed(let error):
            return "\(error ?? "") Retry, or remove this receipt and add a clearer photo."
        case .failed(let error):
            return "\(error ?? "") Retry it, or fill in the fields below by hand."
        }
    }
}

// MARK: Item rows

/// One product: a single scannable row, which expands in place to the editor of each of its lines.
private struct ItemGroupRows: View {
    @Bindable var detail: DetailState
    let group: [LabLineItem]

    private var first: LabLineItem { group[0] }
    private var flagged: Bool { group.contains(where: \.needsReview) }
    private var isOpen: Bool { detail.expanded.contains(first.itemDictionaryId) }
    private var total: Double { (group.reduce(0) { $0 + $1.totalPrice } * 100).rounded() / 100 }

    private var subtitle: String {
        let amounts = group.count > 1
            ? "\(LabFormat.money(first.unitPrice)) each"
            : "\(LabFormat.quantity(first.quantity)) × \(LabFormat.money(first.unitPrice))"
        if let translation = first.translationEn { return "\(translation) · \(amounts)" }
        return amounts
    }

    var body: some View {
        Button {
            withAnimation(.snappy) {
                if isOpen {
                    detail.expanded.remove(first.itemDictionaryId)
                } else {
                    detail.expanded.insert(first.itemDictionaryId)
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if flagged {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Text(first.nameDe ?? first.rawText ?? "Item")
                            .fontWeight(.semibold)
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if group.count > 1 {
                    Text("\(group.count)×")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.fill.secondary, in: .capsule)
                }
                Text(LabFormat.money(total)).amount()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("item-\(first.itemDictionaryId)")
        .listRowBackground(flagged ? Color.orange.opacity(0.14) : nil)

        if isOpen {
            ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                ItemEditorRows(detail: detail, item: item, caption: group.count > 1 ? "Line \(index + 1) of \(group.count)" : nil)
            }
        }
    }
}

private struct ItemEditorRows: View {
    @Bindable var detail: DetailState
    let item: LabLineItem
    let caption: String?

    private var draft: Binding<ItemDraft> {
        Binding(
            get: { detail.draft(item) },
            set: {
                var value = $0
                if value.status != .saving, value.status == detail.draft(item).status { value.status = .idle }
                detail.drafts[item.id] = value
            }
        )
    }

    private var tint: Color? { item.needsReview ? Color.orange.opacity(0.14) : nil }

    private var saveTitle: String {
        switch draft.wrappedValue.status {
        case .idle: return "Save"
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .bad: return "Bad qty/price"
        }
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                if let caption {
                    Text(caption)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    GlassNumberField(title: "Qty", text: draft.quantity, width: 68)
                    Text("×").foregroundStyle(.secondary)
                    GlassNumberField(title: "Price", text: draft.price)
                    Text("=").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(LabFormat.money(draft.wrappedValue.total)).amount().fontWeight(.medium)
                }
            }
            LabeledContent("Translation") {
                TextField("Translation", text: draft.translation)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Category", selection: categoryBinding) {
                ForEach(LabTaxonomy.categoryNames, id: \.self) { Text($0) }
            }
            Picker("Subcategory", selection: subcategoryBinding) {
                ForEach(LabTaxonomy.subcategoryNames(in: draft.wrappedValue.category), id: \.self) { Text($0) }
            }
            Picker("Item group", selection: draft.itemGroup) {
                ForEach(LabTaxonomy.itemGroups(category: draft.wrappedValue.category, subcategory: draft.wrappedValue.subcategory), id: \.self) { Text($0) }
            }
            if draft.wrappedValue.pickersChanged {
                Label {
                    Text("Saving updates the dictionary entry, so it applies to 3 line items across 2 receipts.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.tint)
                }
            }
            HStack {
                Button(saveTitle) { Task { await detail.save(item) } }
                    .buttonStyle(.bordered)
                    .tint(draft.wrappedValue.status == .bad ? .red : .accentColor)
                    .disabled(draft.wrappedValue.status == .saving)
                Spacer()
                Button("Delete item", systemImage: "trash", role: .destructive) {
                    withAnimation { detail.delete(item) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tint(.red)
            }
        }
        .listRowBackground(tint)
    }

    private var categoryBinding: Binding<String> {
        Binding(
            get: { draft.wrappedValue.category },
            set: { category in
                var value = draft.wrappedValue
                value.category = category
                value.subcategory = LabTaxonomy.subcategoryNames(in: category).first ?? ""
                value.itemGroup = LabTaxonomy.itemGroups(category: category, subcategory: value.subcategory).first ?? ""
                draft.wrappedValue = value
            }
        )
    }

    private var subcategoryBinding: Binding<String> {
        Binding(
            get: { draft.wrappedValue.subcategory },
            set: { subcategory in
                var value = draft.wrappedValue
                value.subcategory = subcategory
                value.itemGroup = LabTaxonomy.itemGroups(category: value.category, subcategory: subcategory).first ?? ""
                draft.wrappedValue = value
            }
        )
    }
}

// MARK: Photo page

private struct PhotoPage: View {
    let receipt: LabReceipt
    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1

    /// `100%` shows the slip at twice its fitted size.
    private let actualSize: CGFloat = 2
    private let maxScale: CGFloat = 8

    private var note: String? {
        if receipt.photoLocation == "archived" { return receipt.photoNote ?? "This photo is on your laptop." }
        if receipt.photoLocation == nil { return "This receipt has no photo." }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let note {
                ContentUnavailableView {
                    Label(note, systemImage: "photo.badge.exclamationmark")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        ReceiptPhotoPlaceholder(receipt: receipt)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: geo.size.width * scale, height: geo.size.height * scale, alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.center)
                    .background(Color(white: 0.2))
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { scale = clamp(pinchBase * $0.magnification) }
                            .onEnded { _ in pinchBase = scale }
                    )
                }
                .clipShape(.rect(cornerRadius: 26))
            }
            zoomControls
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    /// Floats over a dark photo, so it is always the dark variant of glass, as in Photos.
    private var zoomControls: some View {
        HStack(spacing: 4) {
            control("Zoom out", systemImage: "minus.magnifyingglass") { setScale(scale / 1.5) }
            textControl("Fit") { setScale(1) }
            textControl("100%") { setScale(actualSize) }
            control("Zoom in", systemImage: "plus.magnifyingglass") { setScale(scale * 1.5) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .environment(\.colorScheme, note == nil ? .dark : colorSchemeForEmpty)
        .disabled(note != nil)
    }

    @Environment(\.colorScheme) private var colorSchemeForEmpty

    private func control(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .frame(width: 44, height: 40)
            .buttonStyle(.plain)
    }

    private func textControl(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.medium))
            .frame(minWidth: 44, minHeight: 40)
            .buttonStyle(.plain)
    }

    private func setScale(_ value: CGFloat) {
        withAnimation(.snappy) {
            scale = clamp(value)
            pinchBase = scale
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 1), maxScale) }
}
