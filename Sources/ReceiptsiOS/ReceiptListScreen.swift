import PhotosUI
import SwiftUI

/// Receipt list: "Needs review" first, search, filters, pull to refresh, add by camera or photo library, and the
/// detail screen (review and edit) one tap away.
struct ReceiptListScreen: View {
    @EnvironmentObject var store: ReceiptStore
    let goToSettings: () -> Void

    var body: some View { ListContent(store: store, sync: store.sync, goToSettings: goToSettings) }
}

private struct ListContent: View {
    @ObservedObject var store: ReceiptStore
    @ObservedObject var sync: SyncCoordinator
    let goToSettings: () -> Void

    @State private var path: [Int] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var scannerUnavailable = false
    @State private var confirmAll = false
    @State private var showDeleted = false
    @State private var pendingPermanentDelete: ReceiptSummary?
    @State private var importNote: String?

    private var unreviewed: [ReceiptSummary] { store.filteredReceipts.filter { $0.reviewedAt == nil } }
    private var reviewed: [ReceiptSummary] { store.filteredReceipts.filter { $0.reviewedAt != nil } }
    private var isConfigured: Bool { SyncSettings.load().isConfigured }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !isConfigured && store.receipts.isEmpty {
                    setupPrompt
                } else {
                    list
                }
            }
            .background(AppTheme.desk)
            .navigationTitle("Receipts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.paper, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(for: Int.self) { id in ReceiptDetailScreen(id: id) }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView(
                onScan: { image, pages in
                    showScanner = false
                    ReceiptImporter.importScan(image, pages: pages, store: store) { importNote = $0 }
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .alert("Document camera not available", isPresented: $scannerUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device cannot scan documents. Use “Choose photos” instead.")
        }
        .alert("Scan", isPresented: Binding(get: { importNote != nil }, set: { if !$0 { importNote = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importNote ?? "") }
        .confirmationDialog(
            "Confirm \(store.unflaggedUnreviewedCount) receipts without flags?",
            isPresented: $confirmAll
        ) {
            Button("Confirm all") { Task { await store.confirmAllWithoutFlags() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks every unreviewed receipt that has no review reasons as reviewed. Receipts with warnings stay in “Needs review”.")
        }
        .confirmationDialog(
            "Permanently delete this receipt?",
            isPresented: Binding(get: { pendingPermanentDelete != nil }, set: { if !$0 { pendingPermanentDelete = nil } }),
            presenting: pendingPermanentDelete
        ) { receipt in
            Button("Delete permanently", role: .destructive) { Task { await store.permanentlyDeleteReceipt(id: receipt.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the receipt, its items and the photo copy on this phone. It cannot be undone.")
        }
        .onChange(of: pickerItems) {
            let items = pickerItems
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await ReceiptImporter.importPhotos(items, store: store) { importNote = $0 } }
        }
    }

    // MARK: Content

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 40))
                .foregroundColor(AppTheme.inkSoft)
            Text("Connect to your server")
                .font(AppTheme.display(20))
                .foregroundColor(AppTheme.ink)
            Text("Receipts are read by your own backend. Enter its address and the receipts token in Settings.")
                .font(AppTheme.body(14))
                .foregroundColor(AppTheme.inkSoft)
                .multilineTextAlignment(.center)
            Button(action: goToSettings) {
                Text("Open Settings")
                    .font(AppTheme.body(14, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(AppTheme.ink)
                    .foregroundColor(AppTheme.onInk)
                    .cornerRadius(4)
            }
            .accessibilityIdentifier("openSettingsButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            if sync.phase != .off {
                HStack { SyncStatusView(sync: sync); Spacer() }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !store.uploadQueue.isEmpty {
                UploadQueueView()
                    .environmentObject(store)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if store.receipts.isEmpty {
                emptyNote("No receipts yet. Scan one with the camera or choose photos.")
            } else if store.filteredReceipts.isEmpty {
                emptyNote("No receipts match.")
            }
            section("Needs review", unreviewed, badge: unreviewed.count)
            section("Reviewed", reviewed, badge: nil)
            recentlyDeleted
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Store, item or amount")
        .refreshable { await refresh() }
        .accessibilityIdentifier("receiptList")
    }

    private func refresh() async {
        await sync.syncNow()
        await store.refreshList()
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.body(14))
            .foregroundColor(AppTheme.inkSoft)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ReceiptSummary], badge: Int?) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { receipt in
                    NavigationLink(value: receipt.id) { ReceiptRow(receipt: receipt) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { Task { await store.deleteReceipt(id: receipt.id) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text(title.uppercased())
                        .font(AppTheme.body(11, weight: .medium))
                        .foregroundColor(AppTheme.inkSoft)
                    Spacer()
                    if let badge, badge > 0 {
                        Text("\(badge) to review")
                            .font(AppTheme.body(11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(AppTheme.penRed)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentlyDeleted: some View {
        if !store.deletedReceipts.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showDeleted) {
                    ForEach(store.deletedReceipts) { receipt in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(receipt.store ?? "Unknown")
                                    .font(AppTheme.body(13, weight: .semibold))
                                    .foregroundColor(AppTheme.ink)
                                Text("\(receipt.date ?? "") · \(fmtMoney(receipt.total))")
                                    .font(AppTheme.mono(11))
                                    .foregroundColor(AppTheme.inkSoft)
                            }
                            Spacer()
                            Button("Restore") { Task { await store.restoreReceipt(id: receipt.id) } }
                                .buttonStyle(.borderless)
                            Button("Delete") { pendingPermanentDelete = receipt }
                                .buttonStyle(.borderless)
                                .foregroundColor(AppTheme.penRed)
                        }
                        .font(AppTheme.body(12))
                    }
                } label: {
                    Text("RECENTLY DELETED (\(store.deletedReceipts.count))")
                        .font(AppTheme.body(11, weight: .medium))
                        .foregroundColor(AppTheme.inkSoft)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Date", selection: $store.dateRange) {
                    ForEach(ReceiptStore.DateRange.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Store", selection: $store.storeFilter) {
                    Text("All stores").tag(String?.none)
                    ForEach(store.storesInUse, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                if store.isFiltering {
                    Button("Clear filters") { store.searchText = ""; store.dateRange = .all; store.storeFilter = nil }
                }
                if store.unflaggedUnreviewedCount > 0 {
                    Divider()
                    Button("Confirm all without flags (\(store.unflaggedUnreviewedCount))") { confirmAll = true }
                }
            } label: {
                Image(systemName: store.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filters")
            .accessibilityIdentifier("filtersMenu")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                if DocumentScannerView.isSupported { showScanner = true } else { scannerUnavailable = true }
            } label: { Image(systemName: "doc.viewfinder") }
                .accessibilityLabel("Scan receipt")
                .accessibilityIdentifier("scanButton")
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
            }
            .accessibilityLabel("Choose photos")
            .accessibilityIdentifier("photosButton")
        }
    }
}

private struct ReceiptRow: View {
    let receipt: ReceiptSummary

    private var isUnreviewed: Bool { receipt.reviewedAt == nil }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.store ?? (receipt.processing == nil ? "Unknown" : "New receipt"))
                    .font(AppTheme.body(15, weight: .semibold))
                    .foregroundColor(AppTheme.ink)
                if let processing = receipt.processing {
                    HStack(spacing: 4) {
                        if processing.isActive { ProgressView().controlSize(.mini) }
                        Text(processing.label)
                            .font(AppTheme.body(12))
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
                    .font(AppTheme.mono(14))
                    .foregroundColor(AppTheme.ink)
            }
        }
        .padding(12)
        .background(AppTheme.paper)
        .overlay(alignment: .leading) { Rectangle().fill(AppTheme.penRed).frame(width: isUnreviewed ? 3 : 0) }
        .overlay(alignment: .topTrailing) {
            if receipt.needsReview {
                Text("⚠").font(.system(size: 11)).foregroundColor(AppTheme.penRed).padding(5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
        .cornerRadius(4)
        .accessibilityElement(children: .combine)
    }
}
