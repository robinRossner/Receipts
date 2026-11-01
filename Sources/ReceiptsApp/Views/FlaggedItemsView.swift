import SwiftUI

// "Items without a category": what the categoriser could not file, with its suggestion. One screen for both apps (the Mac
// shows it in the review pane, the iPhone pushes it from Overview), and a one-item version in a sheet from a receipt's row.

/// The editable name and parent of a category about to be added.
struct FlagPathDraft: Equatable {
    var category: String
    var subcategory: String
    var itemGroup: String

    enum Status: Equatable {
        case new
        case existing
        /// Why the store will refuse it (the same rule as `Taxonomy.additionProblem`).
        case invalid(String)
    }

    init(_ path: Taxonomy.Path?) {
        category = path?.category ?? ""
        subcategory = path?.subcategory ?? ""
        itemGroup = path?.itemGroup ?? ""
    }

    var path: Taxonomy.Path {
        Taxonomy.Path(category.trimmingCharacters(in: .whitespaces), subcategory.trimmingCharacters(in: .whitespaces), itemGroup.trimmingCharacters(in: .whitespaces))
    }

    var isEmpty: Bool { path.category.isEmpty && path.subcategory.isEmpty && path.itemGroup.isEmpty }

    func status(in taxonomy: Taxonomy) -> Status {
        if let problem = Taxonomy.additionProblem(path) { return .invalid(problem) }
        return taxonomy.canonicalPath(matching: path) != nil ? .existing : .new
    }
}

extension FlaggedGroup {
    /// `3 purchases · €12.40`
    var usageLine: String { FlaggedText.usage(count: itemCount, spend: totalSpend) }
}

enum FlaggedText {
    static func usage(count: Int, spend: Double) -> String {
        "\(count == 1 ? "1 purchase" : "\(count) purchases") · \(fmtMoney(spend))"
    }

    /// What a receipt link says: `ALDI SÜD · 2026-03-01`. A receipt the list does not know (yet) goes by its number.
    static func receiptLabel(id: Int, in receipts: [ReceiptSummary]) -> String {
        guard let receipt = receipts.first(where: { $0.id == id }) else { return "Receipt #\(id)" }
        return [receipt.store, receipt.date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Short message once something was filed.
    static func filed(count: Int, under path: Taxonomy.Path) -> String {
        count == 1 ? "Filed 1 item under \(path.label)." : "Filed \(count) items under \(path.label)."
    }

    /// What a flagged row in a receipt says: `No good category. Suggested: Pet Food`.
    static func mark(suggested: String?) -> String {
        guard let suggested, !suggested.isEmpty else { return "No good category" }
        return "No good category. Suggested: \(suggested)"
    }
}

private enum FlagMetrics {
    #if os(iOS)
    static let buttonHeight: CGFloat = 44
    static let fieldHeight: CGFloat = 40
    static let titleSize: CGFloat = 22
    #else
    static let buttonHeight: CGFloat = 28
    static let fieldHeight: CGFloat = 26
    static let titleSize: CGFloat = 20
    #endif
}

private struct FlagButtonStyle: ButtonStyle {
    var color: Color = AppTheme.ink
    var fill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(13, weight: .medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundColor(fill ? AppTheme.onInk : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: FlagMetrics.buttonHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill ? AppTheme.ink : AppTheme.paper))
            .overlay { if !fill { RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.45), lineWidth: 1) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

// MARK: - The screen

struct FlaggedItemsView: View {
    @EnvironmentObject var store: ReceiptStore
    /// Only this dictionary entry (the sheet from a receipt's item row).
    var onlyDictionaryId: Int? = nil
    /// Opens a receipt with this item open; nil shows the receipts as plain text.
    var openReceipt: ((_ receiptId: Int, _ itemDictionaryId: Int) -> Void)? = nil
    /// A `Done` button on the Mac pane and in the sheet.
    var close: (() -> Void)? = nil

    @State private var groups: [FlaggedGroup] = []
    @State private var loaded = false
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                if let notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(AppTheme.body(13))
                        .foregroundColor(AppTheme.greenText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(AppTheme.greenBg)
                        .cornerRadius(6)
                        .accessibilityIdentifier("flagNotice")
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        FlaggedGroupCard(group: group, openReceipt: openReceipt) { message in
                            notice = message
                            await load()
                            if onlyDictionaryId != nil { close?() }
                        }
                    }
                }
            }
            .padding(contentPadding)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .background(AppTheme.desk)
        .task { await load() }
        // A sync, or a resolve from a receipt's row, changed what is flagged.
        .onChange(of: store.flaggedItemCount) { Task { await load() } }
        .onChange(of: store.receipts) { Task { await load() } }
    }

    private var contentPadding: CGFloat {
        #if os(iOS)
        12
        #else
        24
        #endif
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(onlyDictionaryId == nil ? "Items without a category" : "Item without a category")
                    .font(AppTheme.display(FlagMetrics.titleSize))
                    .foregroundColor(AppTheme.ink)
                Text("Filed under Other > Miscellaneous > General until you decide. One decision fixes every receipt with the item.")
                    .font(AppTheme.body(12))
                    .foregroundColor(AppTheme.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let close {
                Button("Done", action: close)
                    .buttonStyle(FlagButtonStyle())
                    .fixedSize()
                    .accessibilityIdentifier("flagDoneButton")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundColor(AppTheme.label)
            Text("Every item has a category.")
                .font(AppTheme.body(14))
                .foregroundColor(AppTheme.label)
                .accessibilityIdentifier("flagEmptyState")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func load() async {
        let all = await store.flaggedItems()
        let filtered = onlyDictionaryId.map { id in all.filter { $0.id == id } } ?? all
        let new = FlaggedItems.group(filtered)
        if new != groups { groups = new }
        loaded = true
    }
}

// MARK: - One suggestion

private struct FlaggedGroupCard: View {
    @EnvironmentObject var store: ReceiptStore
    let group: FlaggedGroup
    let openReceipt: ((Int, Int) -> Void)?
    /// Something was filed; the screen reloads.
    let resolved: (String) async -> Void

    /// Which entries the category chooser is for: the whole group or one item.
    private struct ChooserTarget: Identifiable {
        let ids: [Int]
        var id: [Int] { ids }
    }

    @State private var draft: FlagPathDraft
    @State private var editing = false
    @State private var chooser: ChooserTarget?
    @State private var message: String?
    @State private var busy = false

    init(group: FlaggedGroup, openReceipt: ((Int, Int) -> Void)?, resolved: @escaping (String) async -> Void) {
        self.group = group
        self.openReceipt = openReceipt
        self.resolved = resolved
        _draft = State(initialValue: FlagPathDraft(group.suggestedPath))
        _editing = State(initialValue: group.suggestedPath == nil)
    }

    private var these: String { group.items.count == 1 ? "this" : "these" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(AppTheme.rule.opacity(0.5)).frame(height: 1) }
                    itemRow(item)
                }
            }
            if editing { editor }
            if let message {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("flagResolveMessage")
                }
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.penRed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppTheme.penRedBg)
                .cornerRadius(6)
            }
            actions
        }
        .padding(14)
        .background(AppTheme.paper)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.rule, lineWidth: 1))
        .cornerRadius(8)
        .disabled(busy)
        .sheet(item: $chooser) { target in
            CategoryChooser(initial: group.suggestedPath) { path in
                chooser = nil
                file(target.ids) { await store.resolveFlaggedItems(target.ids, to: path) } under: { path }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.suggestedCategory.flatMap { $0.isEmpty ? nil : $0 } ?? "No suggestion")
                    .font(AppTheme.body(15, weight: .semibold))
                    .foregroundColor(AppTheme.ink)
                if let parent = group.suggestedParent, !parent.isEmpty {
                    Text("Suggested under \(parent)")
                        .font(AppTheme.body(12))
                        .foregroundColor(AppTheme.inkSoft)
                }
            }
            Spacer(minLength: 8)
            Text(group.usageLine)
                .font(AppTheme.mono(12))
                .foregroundColor(AppTheme.inkSoft)
        }
    }

    private func itemRow(_ item: FlaggedItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(AppTheme.body(14, weight: .medium))
                        .foregroundColor(AppTheme.ink)
                    if let translation = item.translationEn, !translation.isEmpty {
                        Text(translation)
                            .font(AppTheme.body(12))
                            .foregroundColor(AppTheme.inkSoft)
                    }
                }
                Spacer(minLength: 4)
                Text(FlaggedText.usage(count: item.itemCount, spend: item.totalSpend))
                    .font(AppTheme.mono(11))
                    .foregroundColor(AppTheme.inkSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if group.items.count > 1 { itemMenu(item) }
            }
            FlexibleReceiptLinks(item: item, receipts: store.receipts, open: openReceipt)
        }
        .padding(.vertical, 7)
    }

    /// One item of a group can be the odd one out.
    private func itemMenu(_ item: FlaggedItem) -> some View {
        Menu {
            Button("Choose a category for this item…") { chooser = ChooserTarget(ids: [item.id]) }
            Button("Keep this item in Other") { keepInOther([item.id]) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(AppTheme.inkSoft)
                #if os(iOS)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .fixedSize()
        #endif
        .accessibilityLabel("Options for \(item.name)")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            PathField(title: "Category", text: $draft.category, options: store.taxonomy.categoryNames(), identifier: "flagCategoryField")
            PathField(title: "Subcategory", text: $draft.subcategory, options: store.taxonomy.subcategoryNames(in: store.taxonomy.canonicalCategory(draft.path.category) ?? ""), identifier: "flagSubcategoryField")
            PathField(title: "Item group", text: $draft.itemGroup, options: [], identifier: "flagItemGroupField")
            switch draft.status(in: store.taxonomy) {
            case .new:
                Text("New category: added to the list on all your devices.")
                    .font(AppTheme.body(12)).foregroundColor(AppTheme.inkSoft)
            case .existing:
                Text("This category already exists; the items are filed there.")
                    .font(AppTheme.body(12)).foregroundColor(AppTheme.inkSoft)
            case .invalid:
                EmptyView()   // the store says why when the button is pressed
            }
        }
        .padding(10)
        .background(AppTheme.desk.opacity(0.5))
        .cornerRadius(6)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { addCategory() } label: {
                    Text(draft.isEmpty ? "Add a category and file \(these)" : "Add “\(draft.path.label)” and file \(these)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FlagButtonStyle(fill: true))
                .accessibilityIdentifier("flagAddButton")
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { editing.toggle() }
                } label: {
                    Image(systemName: editing ? "chevron.up" : "pencil")
                }
                .buttonStyle(FlagButtonStyle())
                .fixedSize()
                .help("Edit the name and parent")
                .accessibilityLabel(editing ? "Close editor" : "Edit name and parent")
                .accessibilityIdentifier("flagEditButton")
            }
            HStack(spacing: 6) {
                Button { chooser = ChooserTarget(ids: group.dictionaryIds) } label: {
                    Text("Choose existing category").frame(maxWidth: .infinity)
                }
                .buttonStyle(FlagButtonStyle())
                .accessibilityIdentifier("flagChooseButton")
                Button { keepInOther(group.dictionaryIds) } label: {
                    Text("Keep in Other").frame(maxWidth: .infinity)
                }
                .buttonStyle(FlagButtonStyle())
                .accessibilityIdentifier("flagKeepButton")
            }
        }
    }

    private func addCategory() {
        let path = draft.path
        file(group.dictionaryIds) { await store.resolveFlaggedItems(group.dictionaryIds, addingCategory: path) } under: { store.taxonomy.canonicalPath(matching: path) ?? path }
    }

    private func keepInOther(_ ids: [Int]) {
        file(ids) { await store.resolveFlaggedItems(ids, to: Taxonomy.fallback) } under: { Taxonomy.fallback }
    }

    private func file(_ ids: [Int], run: @escaping () async -> FlagResolution, under path: @escaping () -> Taxonomy.Path) {
        message = nil
        busy = true
        Task {
            let result = await run()
            busy = false
            switch result {
            case .resolved(let count):
                await resolved(FlaggedText.filed(count: count, under: path()))
            case .invalid(let why):
                message = why
                if case .invalid = draft.status(in: store.taxonomy) { editing = true }
            }
        }
    }
}

private struct FlexibleReceiptLinks: View {
    let item: FlaggedItem
    let receipts: [ReceiptSummary]
    let open: ((Int, Int) -> Void)?
    private let limit = 4

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(item.receiptIds.prefix(limit), id: \.self) { id in
                let label = FlaggedText.receiptLabel(id: id, in: receipts)
                if let open {
                    Button { open(id, item.id) } label: {
                        Text(label)
                            .font(AppTheme.mono(11))
                            .underline()
                            .foregroundColor(AppTheme.inkSoft)
                            #if os(iOS)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            #endif
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(label).font(AppTheme.mono(11)).foregroundColor(AppTheme.inkSoft)
                }
            }
            if item.receiptIds.count > limit {
                Text("+\(item.receiptIds.count - limit) more")
                    .font(AppTheme.mono(11))
                    .foregroundColor(AppTheme.inkSoft)
            }
        }
    }
}

/// A name to type, with the existing names one click away.
private struct PathField: View {
    let title: String
    @Binding var text: String
    let options: [String]
    let identifier: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppTheme.body(12))
                .foregroundColor(AppTheme.inkSoft)
                .frame(width: 80, alignment: .leading)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.ink)
                .autocorrectionDisabled()
                .accessibilityIdentifier(identifier)
                .padding(.horizontal, 8)
                .frame(minHeight: FlagMetrics.fieldHeight)
                .background(AppTheme.card)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AppTheme.rule, lineWidth: 1))
                .cornerRadius(5)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { name in Button(name) { text = name } }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.inkSoft)
                        #if os(iOS)
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                        #endif
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .fixedSize()
                #endif
                .accessibilityLabel("Existing \(title.lowercased()) names")
            }
        }
    }
}

// MARK: - Choosing an existing category

/// The cascading category > subcategory > item group picker, in a sheet.
struct CategoryChooser: View {
    @EnvironmentObject var store: ReceiptStore
    @Environment(\.dismiss) private var dismiss
    let initial: Taxonomy.Path?
    let choose: (Taxonomy.Path) -> Void

    @State private var category = ""
    @State private var subcategory = ""
    @State private var itemGroup = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a category")
                .font(AppTheme.display(FlagMetrics.titleSize))
                .foregroundColor(AppTheme.ink)
            VStack(spacing: 0) {
                row("Category", Binding(get: { category }, set: selectCategory), store.taxonomy.categoryNames())
                Rectangle().fill(AppTheme.rule).frame(height: 1)
                row("Subcategory", Binding(get: { subcategory }, set: selectSubcategory), store.taxonomy.subcategoryNames(in: category))
                Rectangle().fill(AppTheme.rule).frame(height: 1)
                row("Item group", $itemGroup, store.taxonomy.itemGroups(category: category, subcategory: subcategory))
            }
            .padding(.horizontal, 10)
            .background(AppTheme.card)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppTheme.rule, lineWidth: 1))
            .cornerRadius(6)
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(FlagButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("flagChooserCancel")
                Spacer()
                Button("File here") { choose(Taxonomy.Path(category, subcategory, itemGroup)) }
                    .buttonStyle(FlagButtonStyle(fill: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(category.isEmpty || subcategory.isEmpty || itemGroup.isEmpty)
                    .accessibilityIdentifier("flagChooserFile")
            }
            #if os(iOS)
            Spacer(minLength: 0)
            #endif
        }
        .padding(20)
        .background(AppTheme.desk)
        #if os(macOS)
        .frame(width: 460)
        #else
        .presentationDetents([.medium])
        .presentationBackground(AppTheme.desk)
        #endif
        .onAppear(perform: preselect)
    }

    /// Starts where the suggestion points when that part of the list exists, else at the top.
    private func preselect() {
        let taxonomy = store.taxonomy
        category = initial.flatMap { taxonomy.canonicalCategory($0.category) } ?? taxonomy.categoryNames().first ?? ""
        subcategory = initial.flatMap { taxonomy.canonicalSubcategory($0.subcategory, in: category) } ?? taxonomy.subcategoryNames(in: category).first ?? ""
        itemGroup = taxonomy.itemGroups(category: category, subcategory: subcategory).first ?? ""
    }

    private func selectCategory(_ value: String) {
        category = value
        subcategory = store.taxonomy.subcategoryNames(in: value).first ?? ""
        itemGroup = store.taxonomy.itemGroups(category: value, subcategory: subcategory).first ?? ""
    }

    private func selectSubcategory(_ value: String) {
        subcategory = value
        itemGroup = store.taxonomy.itemGroups(category: category, subcategory: value).first ?? ""
    }

    private func row(_ title: String, _ selection: Binding<String>, _ options: [String]) -> some View {
        HStack(spacing: 10) {
            Text(title).font(AppTheme.body(13)).foregroundColor(AppTheme.inkSoft).fixedSize()
            Spacer(minLength: 0)
            #if os(iOS)
            // A menu with its own label: the system menu picker wraps long taxonomy names over the neighbouring rows.
            Menu {
                Picker(title, selection: selection) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.isEmpty ? "—" : selection.wrappedValue)
                        .font(AppTheme.body(14))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(AppTheme.ink)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(title)
            .accessibilityValue(selection.wrappedValue)
            #else
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.vertical, 6)
            #endif
        }
    }
}

// MARK: - On a receipt's item row

/// The small mark on a flagged item with what was suggested, and the way to resolve it from here.
struct FlaggedItemMark: View {
    let item: LineItemDetail
    @State private var open = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag.slash")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(FlaggedText.mark(suggested: item.suggestedCategory))
                .font(AppTheme.body(12))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("flagMark")
            Spacer(minLength: 4)
            Button("Sort out…") { open = true }
                .font(AppTheme.body(12, weight: .semibold))
                .buttonStyle(.plain)
                .underline()
                #if os(iOS)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
                #endif
                .accessibilityIdentifier("flagSortOutButton")
        }
        .foregroundColor(AppTheme.penRed)
        .sheet(isPresented: $open) {
            FlaggedItemsView(onlyDictionaryId: item.itemDictionaryId, close: { open = false })
                #if os(macOS)
                .frame(width: 620, height: 520)
                #else
                .presentationDetents([.large])
                .presentationBackground(AppTheme.desk)
                #endif
        }
    }
}
