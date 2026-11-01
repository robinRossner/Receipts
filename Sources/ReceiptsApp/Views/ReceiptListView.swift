import SwiftUI

/// Ports the sidebar's receipt list from dashboard.html: split into "Needs review" and
/// "Reviewed" sections (SQL already orders them by date descending), with search and filters.
struct ReceiptListView: View {
    @EnvironmentObject var store: ReceiptStore
    @EnvironmentObject var snacks: SnackCenter
    @State private var showDeleted = false
    @State private var pendingPermanentDelete: ReceiptSummary?
    @State private var confirmAll = false
    @State private var reviewReasons: [Int: [String]] = [:]
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    // store.receipts comes from SQL ordered by date DESC, id DESC; filtering keeps that order.
    private var unreviewed: [ReceiptSummary] { store.filteredReceipts.filter { $0.reviewedAt == nil } }
    private var reviewed: [ReceiptSummary] { store.filteredReceipts.filter { $0.reviewedAt != nil } }
    /// The badge counts everything waiting, also what the filters hide.
    private var toReview: Int { store.receipts.filter { $0.reviewedAt == nil }.count }
    private var hasFilterTags: Bool { !store.searchText.isEmpty || store.dateRange != .all || store.storeFilter != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RECENT")
                    .font(AppTheme.body(11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundColor(AppTheme.label)
                Spacer()
                if toReview > 0 {
                    Text("\(toReview) to review")
                        .font(AppTheme.body(11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(AppTheme.penRed)
                        .foregroundColor(AppTheme.onRed)
                        .clipShape(Capsule())
                }
            }

            searchAndFilters

            if store.receipts.isEmpty {
                noReceipts
            } else if store.filteredReceipts.isEmpty {
                noMatch
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        section("Needs review", unreviewed)
                        section("Reviewed", reviewed)
                        recentlyDeleted
                    }
                }
                .onChange(of: store.selectedReceiptID) {
                    if let id = store.selectedReceiptID { withAnimation { proxy.scrollTo(id) } }
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { store.flaggedPaneOpen = false; Task { await store.selectAdjacentReceipt(offset: -1) }; return .handled }
            .onKeyPress(.downArrow) { store.flaggedPaneOpen = false; Task { await store.selectAdjacentReceipt(offset: 1) }; return .handled }
        }
        .onChange(of: store.searchFocusToken) { searchFocused = true }
        // Reasons are not in the list's summaries; any reload of the list may have changed them.
        .onReceive(store.$receipts) { _ in
            Task { reviewReasons = await store.reviewReasonsByReceipt() }
        }
        .confirmationDialog(
            "Confirm \(store.confirmableWithoutFlagsCount) receipts without flags?",
            isPresented: $confirmAll
        ) {
            Button("Confirm all") { Task { await store.confirmAllFinishedWithoutFlags() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks every unreviewed receipt that has no review reasons as reviewed, including ones hidden by the current filters. Receipts with warnings, and ones still being read or that failed, stay in \"Needs review\".")
        }
        .confirmationDialog(
            "Permanently delete this receipt?",
            isPresented: Binding(get: { pendingPermanentDelete != nil }, set: { if !$0 { pendingPermanentDelete = nil } }),
            presenting: pendingPermanentDelete
        ) { receipt in
            Button("Delete permanently", role: .destructive) {
                Task { await store.permanentlyDeleteReceipt(id: receipt.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the receipt, its items and its image file. It cannot be undone.")
        }
    }

    private var noReceipts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No receipts yet.")
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.label)
            Button("Import receipts…") { store.isImporterPresented = true }
                .font(AppTheme.body(12, weight: .medium))
        }
    }

    private var noMatch: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(AppTheme.label)
            Text("No receipts match.")
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.label)
            Spacer()
            Button("Clear filters") { store.clearReceiptFilters() }
                .font(AppTheme.body(12, weight: .medium))
        }
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(AppTheme.inkSoft)
                TextField("Search store, item or amount", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(AppTheme.ink)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false; listFocused = true }
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .font(AppTheme.body(12))
            .padding(8)
            .background(AppTheme.card)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(searchFocused ? AppTheme.ink : AppTheme.rule, lineWidth: 1))
            .cornerRadius(4)

            HStack(spacing: 8) {
                Picker("Date", selection: $store.dateRange) {
                    ForEach(ReceiptStore.DateRange.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Store", selection: $store.storeFilter) {
                    Text("All stores").tag(String?.none)
                    ForEach(store.storesInUse, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            .labelsHidden()
            .font(AppTheme.body(11))

            if hasFilterTags { activeFilters }

            if store.flaggedItemCount > 0 {
                flaggedEntry
            }

            if store.confirmableWithoutFlagsCount > 0 {
                Button("Confirm all without flags (\(store.confirmableWithoutFlagsCount))") { confirmAll = true }
                    .buttonStyle(.plain)
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundColor(AppTheme.greenText)
            }
        }
    }

    /// What is filtering the list right now (click to remove) and how many receipts are left.
    private var activeFilters: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                if !store.searchText.isEmpty { filterTag("“\(store.searchText)”") { store.searchText = "" } }
                if store.dateRange != .all { filterTag(store.dateRange.rawValue) { store.dateRange = .all } }
                if let storeFilter = store.storeFilter { filterTag(storeFilter) { store.storeFilter = nil } }
            }
            Text("\(store.filteredReceipts.count) of \(store.receipts.count) receipts")
                .font(AppTheme.mono(11))
                .foregroundColor(AppTheme.label)
        }
    }

    private func filterTag(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .font(AppTheme.body(11, weight: .medium))
            .foregroundColor(AppTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(AppTheme.paper)
            .overlay(Capsule().strokeBorder(AppTheme.rule, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove this filter")
    }

    /// Quiet: only there with something to sort out, and above the list so it does not scroll away.
    private var flaggedEntry: some View {
        Button {
            store.flaggedPaneOpen = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag.slash").font(.system(size: 11))
                Text("Items without a category (\(store.flaggedItemCount))")
                    .font(AppTheme.body(11, weight: store.flaggedPaneOpen ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(AppTheme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Items the categoriser found no good category for (⌘3)")
    }

    @ViewBuilder
    private var recentlyDeleted: some View {
        if !store.deletedReceipts.isEmpty {
            DisclosureGroup(isExpanded: $showDeleted) {
                ForEach(store.deletedReceipts) { receipt in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(receipt.store ?? "Unknown")
                                .font(AppTheme.body(12, weight: .semibold))
                                .foregroundColor(AppTheme.ink)
                            Text("\(receipt.date ?? "") · \(fmtMoney(receipt.total))")
                                .font(AppTheme.mono(11))
                                .foregroundColor(AppTheme.inkSoft)
                        }
                        Spacer()
                        Button("Restore") { Task { await store.restoreReceipt(id: receipt.id) } }
                            .foregroundColor(AppTheme.ink)
                        Button("Delete permanently") { pendingPermanentDelete = receipt }
                            .foregroundColor(AppTheme.penRed)
                    }
                    .buttonStyle(.plain)
                    .font(AppTheme.body(11))
                    .padding(8)
                    .background(AppTheme.paper)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
                    .cornerRadius(4)
                }
            } label: {
                Text("RECENTLY DELETED (\(store.deletedReceipts.count))")
                    .font(AppTheme.body(11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundColor(AppTheme.label)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func section(_ label: String, _ items: [ReceiptSummary]) -> some View {
        if !items.isEmpty {
            Text(label.uppercased())
                .font(AppTheme.body(11, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(AppTheme.label)
                .padding(.top, 4)
            ForEach(items) { receipt in
                ReceiptStubView(receipt: receipt, firstReason: reviewReasons[receipt.id]?.first) { listFocused = true }
            }
        }
    }
}

private struct ReceiptStubView: View {
    @EnvironmentObject var store: ReceiptStore
    @EnvironmentObject var snacks: SnackCenter
    let receipt: ReceiptSummary
    let firstReason: String?
    var onSelect: () -> Void = {}

    private var isUnreviewed: Bool { receipt.reviewedAt == nil }
    private var isSelected: Bool { store.selectedReceiptID == receipt.id && !store.flaggedPaneOpen }

    /// A flagged, unreviewed receipt says why right here. One without a stored reason still shows the flag.
    private var inlineWarning: String? {
        guard isUnreviewed, receipt.needsReview else { return nil }
        return firstReason ?? "Needs review"
    }

    var body: some View {
        Button {
            onSelect()
            store.flaggedPaneOpen = false
            Task { await store.loadReceiptDetail(id: receipt.id) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(receipt.store ?? (receipt.processing == nil ? "Unknown" : "New receipt"))
                        .font(AppTheme.body(13, weight: .semibold))
                        .foregroundColor(AppTheme.ink)
                        .lineLimit(1)
                    if let processing = receipt.processing {
                        HStack(spacing: 4) {
                            if processing.isActive { ProgressView().controlSize(.mini) }
                            Text(processing.label)
                                .font(AppTheme.body(11))
                                .foregroundColor(processing.isActive ? AppTheme.inkSoft : AppTheme.penRed)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text(receipt.date ?? "")
                                .font(AppTheme.mono(12))
                                .foregroundColor(AppTheme.inkSoft)
                            // Confirmed with its flag still set: the warning stays on the receipt.
                            if !isUnreviewed && receipt.needsReview {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(AppTheme.penRed)
                                    .help("Has warnings")
                            }
                        }
                    }
                    if let inlineWarning {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                            Text(inlineWarning).lineLimit(1)
                        }
                        .font(AppTheme.body(11))
                        .foregroundColor(AppTheme.penRed)
                        .help(inlineWarning)
                    }
                }
                Spacer(minLength: 4)
                if receipt.processing == nil || receipt.total != nil {
                    Text(fmtMoney(receipt.total))
                        .font(AppTheme.mono(13))
                        .foregroundColor(AppTheme.ink)
                }
            }
            .padding(10)
            .hoverHighlight()
            .background(isSelected ? AppTheme.raised : AppTheme.paper)
            .overlay(Rectangle().fill(AppTheme.penRed).frame(width: isUnreviewed ? 3 : 0), alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? AppTheme.ink : AppTheme.rule, lineWidth: 1))
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isUnreviewed && receipt.processing?.isActive != true {
                Button("Looks good") { Task { await confirm() } }
            }
            Button("Delete") { Task { await store.deleteWithUndo(id: receipt.id, snacks: snacks) } }
        }
        .id(receipt.id)
    }

    private func confirm() async {
        let id = receipt.id
        await store.markReviewed(id: id)
        snacks.show("\(receipt.store ?? "Receipt") reviewed") { await store.markUnreviewed(id: id) }
    }
}
