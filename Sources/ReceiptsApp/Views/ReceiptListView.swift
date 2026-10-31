import SwiftUI

/// Ports the sidebar's receipt list from dashboard.html: split into "Needs review" and
/// "Reviewed" sections (SQL already orders them by date descending), with search and filters.
struct ReceiptListView: View {
    @EnvironmentObject var store: ReceiptStore
    @State private var showDeleted = false
    @State private var pendingPermanentDelete: ReceiptSummary?
    @State private var confirmAll = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    // store.receipts comes from SQL ordered by date DESC, id DESC; filtering keeps that order.
    private var unreviewed: [ReceiptSummary] { store.filteredReceipts.filter { $0.reviewedAt == nil } }
    private var reviewed: [ReceiptSummary] { store.filteredReceipts.filter { $0.reviewedAt != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RECENT")
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundColor(AppTheme.inkSoft)
                Spacer()
                if !unreviewed.isEmpty {
                    Text("\(unreviewed.count) to review")
                        .font(AppTheme.body(11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(AppTheme.penRed)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }

            searchAndFilters

            if store.receipts.isEmpty {
                Text("No receipts yet.")
                    .font(AppTheme.body(13))
                    .foregroundColor(AppTheme.inkSoft)
            } else if store.filteredReceipts.isEmpty {
                Text("No receipts match.")
                    .font(AppTheme.body(13))
                    .foregroundColor(AppTheme.inkSoft)
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
            .onKeyPress(.upArrow) { Task { await store.selectAdjacentReceipt(offset: -1) }; return .handled }
            .onKeyPress(.downArrow) { Task { await store.selectAdjacentReceipt(offset: 1) }; return .handled }
        }
        .onChange(of: store.searchFocusToken) { searchFocused = true }
        .confirmationDialog(
            "Confirm \(store.unflaggedUnreviewedCount) receipts without flags?",
            isPresented: $confirmAll
        ) {
            Button("Confirm all") { Task { await store.confirmAllWithoutFlags() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks every unreviewed receipt that has no review reasons as reviewed, including ones hidden by the current filters. Receipts with warnings stay in \"Needs review\".")
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

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(AppTheme.inkSoft)
                TextField("Search store, item or amount", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false; listFocused = true }
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(AppTheme.body(12))
            .padding(8)
            .background(AppTheme.paper)
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
                if store.isFiltering {
                    Button("Clear") {
                        store.searchText = ""; store.dateRange = .all; store.storeFilter = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(AppTheme.penRed)
                }
            }
            .labelsHidden()
            .font(AppTheme.body(11))

            if store.unflaggedUnreviewedCount > 0 {
                Button("Confirm all without flags (\(store.unflaggedUnreviewedCount))") { confirmAll = true }
                    .buttonStyle(.plain)
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.stampGreen)
            }
        }
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
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundColor(AppTheme.inkSoft)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func section(_ label: String, _ items: [ReceiptSummary]) -> some View {
        if !items.isEmpty {
            Text(label.uppercased())
                .font(AppTheme.body(11, weight: .medium))
                .foregroundColor(AppTheme.inkSoft)
                .padding(.top, 4)
            ForEach(items) { receipt in
                ReceiptStubView(receipt: receipt) { listFocused = true }
            }
        }
    }
}

private struct ReceiptStubView: View {
    @EnvironmentObject var store: ReceiptStore
    let receipt: ReceiptSummary
    var onSelect: () -> Void = {}

    private var isUnreviewed: Bool { receipt.reviewedAt == nil }
    private var isSelected: Bool { store.selectedReceiptID == receipt.id }

    var body: some View {
        Button {
            onSelect()
            Task { await store.loadReceiptDetail(id: receipt.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(receipt.store ?? (receipt.processing == nil ? "Unknown" : "New receipt"))
                            .font(AppTheme.body(13, weight: .semibold))
                            .foregroundColor(AppTheme.ink)
                        if let processing = receipt.processing {
                            HStack(spacing: 4) {
                                if processing.isActive { ProgressView().controlSize(.mini) }
                                Text(processing.label)
                                    .font(AppTheme.body(11))
                                    .foregroundColor(processing.isActive ? AppTheme.inkSoft : AppTheme.penRed)
                            }
                        } else {
                            Text(receipt.date ?? "")
                                .font(AppTheme.mono(12))
                                .foregroundColor(AppTheme.inkSoft)
                        }
                    }
                    Spacer()
                    if receipt.processing == nil || receipt.total != nil {
                        Text(fmtMoney(receipt.total))
                            .font(AppTheme.mono(13))
                            .foregroundColor(AppTheme.ink)
                    }
                }
                .padding(10)

                if receipt.needsReview {
                    Text("⚠")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.penRed)
                        .padding(6)
                }
            }
            .background(isSelected ? Color(hex: 0xFBF8F1) : AppTheme.paper)
            .overlay(Rectangle().fill(AppTheme.penRed).frame(width: isUnreviewed ? 3 : 0), alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .id(receipt.id)
    }
}
