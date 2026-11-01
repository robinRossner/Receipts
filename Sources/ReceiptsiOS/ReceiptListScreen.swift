import PhotosUI
import SwiftUI

/// Receipt list: "Needs review" first, search, filters, pull to refresh, add by camera or photo library, and the
/// detail screen (review and edit) one tap away. Swipe right confirms, swipe left deletes, both with Undo.
struct ReceiptListScreen: View {
    @EnvironmentObject var store: ReceiptStore
    let goToSettings: () -> Void

    var body: some View { ListContent(store: store, sync: store.sync, goToSettings: goToSettings) }
}

private struct ListContent: View {
    @ObservedObject var store: ReceiptStore
    @ObservedObject var sync: SyncCoordinator
    let goToSettings: () -> Void
    @EnvironmentObject private var snacks: SnackCenter

    @State private var path: [Int] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var scannerUnavailable = false
    @State private var showFilters = false
    /// The filter panel asks for this; the dialog opens once the panel has gone.
    @State private var confirmAllAfterFilters = false
    @State private var confirmAll = false
    @State private var showDeleted = false
    @State private var pendingPermanentDelete: ReceiptSummary?
    @State private var importNote: String?
    @State private var reviewReasons: [Int: [String]] = [:]

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
            .background(Theme.desk)
            .navigationTitle("Receipts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(for: Int.self) { id in ReceiptDetailScreen(id: id) }
            .safeAreaInset(edge: .bottom) { snackbar }
        }
        .sheet(isPresented: $showFilters, onDismiss: {
            if confirmAllAfterFilters {
                confirmAllAfterFilters = false
                confirmAll = true
            }
        }) {
            FilterPanel(store: store, confirmAll: {
                confirmAllAfterFilters = true
                showFilters = false
            })
            .presentationDetents([.fraction(0.72), .large])
            .presentationBackground(Theme.desk)
            .presentationDragIndicator(.visible)
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
            "Confirm \(store.confirmableWithoutFlagsCount) receipts without flags?",
            isPresented: $confirmAll,
            titleVisibility: .visible
        ) {
            Button("Confirm all") { Task { await store.confirmAllFinishedWithoutFlags() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks every unreviewed receipt that has no review reasons as reviewed. Receipts with warnings stay in “Needs review”.")
        }
        .confirmationDialog(
            "Permanently delete this receipt?",
            isPresented: Binding(get: { pendingPermanentDelete != nil }, set: { if !$0 { pendingPermanentDelete = nil } }),
            titleVisibility: .visible,
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
        // Reasons are not in the list's summaries; any reload of the list may have changed them.
        .onReceive(store.$receipts) { _ in
            Task { reviewReasons = await store.reviewReasonsByReceipt() }
        }
    }

    @ViewBuilder private var snackbar: some View {
        if let snack = snacks.current, path.isEmpty {
            SnackbarView(snack: snack, undo: snacks.performUndo)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Receipts").font(Theme.display(20)).foregroundStyle(Theme.ink)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showFilters = true
            } label: {
                Image(systemName: store.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filters")
            .accessibilityIdentifier("filtersMenu")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: startScan) { Image(systemName: "doc.viewfinder") }
                .accessibilityLabel("Scan receipt")
                .accessibilityIdentifier("scanButton")
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
            }
            .accessibilityLabel("Choose photos")
            .accessibilityIdentifier("photosButton")
        }
    }

    private func startScan() {
        if DocumentScannerView.isSupported { showScanner = true } else { scannerUnavailable = true }
    }

    // MARK: Setup

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 44))
                .foregroundStyle(Theme.label)
            Text("Connect to your server")
                .font(Theme.display(22))
                .foregroundStyle(Theme.ink)
            Text("Receipts are read by your own backend. Enter its address and the receipts token in Settings.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(.center)
            Button("Open Settings", action: goToSettings)
                .buttonStyle(OutlineButtonStyle(fill: true))
                .padding(.top, 4)
                .accessibilityIdentifier("openSettingsButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var list: some View {
        List {
            if sync.phase != .off {
                SyncRow(store: store, sync: sync).plainRow(top: 0, bottom: 0)
            }
            if hasFilterTags { activeFilters.plainRow(top: 2, bottom: 6) }
            if !store.uploadQueue.isEmpty {
                UploadPanel(store: store, open: { path.append($0) }).plainRow(top: 4, bottom: 8)
            }
            if store.receipts.isEmpty {
                emptyState.plainRow(top: 40, bottom: 20)
            } else if store.filteredReceipts.isEmpty {
                noMatchState.plainRow(top: 40, bottom: 20)
            }
            section("Needs review", unreviewed, badge: unreviewed.count)
            section("Reviewed", reviewed, badge: nil)
            recentlyDeleted
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Store, item or amount")
        .refreshable { await refresh() }
        .accessibilityIdentifier("receiptList")
    }

    private func refresh() async {
        await sync.syncNow()
        await store.refreshList()
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ReceiptSummary], badge: Int?) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { receipt in
                    Button {
                        path.append(receipt.id)
                    } label: {
                        ReceiptRow(receipt: receipt, firstReason: reviewReasons[receipt.id]?.first)
                    }
                    .buttonStyle(.plain)
                    .plainRow(top: 4, bottom: 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { delete(receipt) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Theme.red)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if receipt.reviewedAt == nil && receipt.processing == nil {
                            Button { confirm(receipt) } label: {
                                Label("Looks good", systemImage: "checkmark")
                            }
                            .tint(Theme.green)
                        }
                    }
                }
            } header: {
                HStack {
                    SectionLabel(text: title)
                    Spacer()
                    if let badge, badge > 0 {
                        Text("\(badge) to review")
                            .font(Theme.body(12, .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Theme.red, in: Capsule())
                            .foregroundStyle(Theme.onRed)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Theme.desk)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func confirm(_ receipt: ReceiptSummary) {
        let id = receipt.id
        Task {
            await store.markReviewed(id: id)
            snacks.show("\(receipt.store ?? "Receipt") reviewed") { await store.markUnreviewed(id: id) }
        }
    }

    private func delete(_ receipt: ReceiptSummary) {
        let id = receipt.id
        Task {
            await store.deleteReceipt(id: id)
            snacks.show("Moved to Recently deleted") { await store.restoreReceipt(id: id) }
        }
    }

    @ViewBuilder private var recentlyDeleted: some View {
        if !store.deletedReceipts.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showDeleted.toggle() }
            } label: {
                HStack(spacing: 8) {
                    SectionLabel(text: "Recently deleted (\(store.deletedReceipts.count))")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .rotationEffect(.degrees(showDeleted ? 90 : 0))
                }
                .padding(.horizontal, 2)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .plainRow(top: 10, bottom: 0)
            if showDeleted {
                ForEach(store.deletedReceipts) { receipt in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(receipt.store ?? "Unknown")
                                .font(Theme.body(15, .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text("\(receipt.date ?? "") · \(fmtMoney(receipt.total))")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.inkSoft)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 4)
                        Button("Restore") { Task { await store.restoreReceipt(id: receipt.id) } }
                            .buttonStyle(OutlineButtonStyle())
                            .fixedSize()
                        Button("Delete") { pendingPermanentDelete = receipt }
                            .buttonStyle(OutlineButtonStyle(color: Theme.red))
                            .fixedSize()
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .background(Theme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.rule, lineWidth: 1))
                    .plainRow(top: 3, bottom: 3)
                }
            }
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(Theme.label)
            Text("No receipts yet. Scan one with the camera or choose photos.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: startScan) {
                    Label("Scan receipt", systemImage: "doc.viewfinder")
                }
                .buttonStyle(OutlineButtonStyle(fill: true))
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                    Label("Choose photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(Theme.label)
            Text("No receipts match.")
                .font(Theme.body(15))
                .foregroundStyle(Theme.label)
            Button("Clear filters") { store.clearReceiptFilters() }
                .buttonStyle(OutlineButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private var hasFilterTags: Bool { !store.searchText.isEmpty || store.dateRange != .all || store.storeFilter != nil }

    /// What is filtering the list right now; tap to remove.
    private var activeFilters: some View {
        FlowLayout(spacing: 6) {
            if !store.searchText.isEmpty { filterTag("“\(store.searchText)”") { store.searchText = "" } }
            if store.dateRange != .all { filterTag(store.dateRange.rawValue) { store.dateRange = .all } }
            if let storeFilter = store.storeFilter { filterTag(storeFilter) { store.storeFilter = nil } }
        }
    }

    private func filterTag(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
            }
            .font(Theme.body(13, .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Removes this filter")
    }
}

private extension View {
    func plainRow(top: CGFloat, bottom: CGFloat) -> some View {
        self.listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 14, bottom: bottom, trailing: 14))
    }
}

// MARK: Rows

private struct ReceiptRow: View {
    let receipt: ReceiptSummary
    let firstReason: String?

    private var isUnreviewed: Bool { receipt.reviewedAt == nil }
    private var hasKnownTotal: Bool { receipt.processing == nil || receipt.total != nil }

    /// A flagged, unreviewed receipt says why right here. One without a stored reason still shows the flag.
    private var inlineWarning: String? {
        guard isUnreviewed, receipt.needsReview else { return nil }
        return firstReason ?? "Needs review"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.store ?? (receipt.processing == nil ? "Unknown" : "New receipt"))
                    .font(Theme.body(16, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let processing = receipt.processing {
                    HStack(spacing: 5) {
                        if processing.isActive {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                        }
                        Text(processing.label).font(Theme.body(13)).lineLimit(1)
                    }
                    .foregroundStyle(processing.isActive ? Theme.inkSoft : Theme.red)
                } else {
                    HStack(spacing: 5) {
                        Text(receipt.date ?? "")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.inkSoft)
                        // Confirmed with its flag still set: the warning stays on the receipt.
                        if !isUnreviewed && receipt.needsReview {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.red)
                                .accessibilityLabel("Has warnings")
                        }
                    }
                }
                if let inlineWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text(inlineWarning).lineLimit(1)
                    }
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.red)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
            if hasKnownTotal {
                Text(fmtMoney(receipt.total))
                    .font(Theme.mono(15, .medium))
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Theme.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.red).frame(width: isUnreviewed ? 4 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.rule, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SyncRow: View {
    @ObservedObject var store: ReceiptStore
    @ObservedObject var sync: SyncCoordinator

    private var isHardFailure: Bool { sync.lastError != nil && sync.nextRetryAt == nil }

    private var dotColor: Color {
        if sync.lastError != nil { return isHardFailure ? Theme.red : Theme.series[1] }
        return sync.lastSyncAt == nil ? Theme.seriesOther : Theme.green
    }

    var body: some View {
        HStack(spacing: 6) {
            if sync.phase == .syncing {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(dotColor).frame(width: 7, height: 7)
            }
            Text(sync.statusText)
                .font(Theme.body(12.5))
                .foregroundStyle(isHardFailure ? Theme.red : Theme.label)
                .lineLimit(1)
            Spacer()
            IconButton(systemName: "arrow.triangle.2.circlepath", label: "Sync now", color: Theme.label, size: 14) { store.syncNow() }
                .disabled(sync.phase == .syncing)
                .padding(.trailing, -10)
        }
        .padding(.leading, 2)
    }
}

// MARK: Upload panel

private struct UploadPanel: View {
    @ObservedObject var store: ReceiptStore
    let open: (Int) -> Void

    private var finished: Int { store.uploadQueue.filter { $0.state.isFinished }.count }
    private var hasPending: Bool { store.uploadQueue.contains { !$0.state.isFinished } }
    private var hasFailed: Bool { store.uploadQueue.contains { isFailure($0.state) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Uploads - \(finished) of \(store.uploadQueue.count)")
                Spacer()
            }
            ProgressView(value: Double(finished), total: Double(max(store.uploadQueue.count, 1)))
                .progressViewStyle(.linear)
                .tint(Theme.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.uploadQueue) { job in row(job) }
                }
            }
            .frame(maxHeight: 232)
            HStack(spacing: 6) {
                if hasPending { action("Cancel all") { store.cancelAllUploads() } }
                if hasFailed { action("Retry failed") { store.retryFailedUploads() } }
                action("Clear finished") { store.clearFinishedUploads() }
            }
        }
        .paperCard(padding: 12)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(UploadActionStyle())
    }

    private func receiptId(_ job: UploadJob) -> Int? {
        switch job.state {
        case .done(let id), .uploaded(let id), .duplicate(let id): return id
        default: return nil
        }
    }

    private func row(_ job: UploadJob) -> some View {
        HStack(alignment: .center, spacing: 8) {
            thumbnail(job)
            statusIcon(job.state)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.fileName)
                    .font(Theme.body(13, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText(job.state))
                    .font(Theme.body(12))
                    .foregroundStyle(isFailure(job.state) ? Theme.red : Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !job.state.isFinished {
                IconButton(systemName: "xmark", label: "Cancel upload", size: 12) { store.cancelUpload(id: job.id) }
                    .padding(.vertical, -6)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = receiptId(job) { open(id) }
        }
    }

    @ViewBuilder private func thumbnail(_ job: UploadJob) -> some View {
        if let image = job.thumbnail {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Theme.rule).frame(width: 22, height: 22)
        }
    }

    @ViewBuilder private func statusIcon(_ state: UploadJob.State) -> some View {
        switch state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(Theme.inkSoft).font(.system(size: 13))
        case .scanning, .extracting, .categorizing, .saving, .uploading:
            ProgressView().controlSize(.mini)
        case .done, .uploaded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.greenText).font(.system(size: 14))
        case .duplicate:
            Image(systemName: "doc.on.doc").foregroundStyle(Theme.inkSoft).font(.system(size: 12))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.red).font(.system(size: 14))
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(Theme.inkSoft).font(.system(size: 14))
        }
    }

    private func isFailure(_ state: UploadJob.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func statusText(_ state: UploadJob.State) -> String {
        switch state {
        case .queued: return "Waiting"
        case .scanning: return "Scanning…"
        case .extracting: return "Reading receipt…"
        case .categorizing: return "Categorizing…"
        case .saving: return "Saving…"
        case .uploading: return "Uploading…"
        case .done(let id): return "Imported as receipt #\(id)"
        case .uploaded(let id): return "Uploaded (receipt #\(id)); the server is reading it"
        case .duplicate(let id): return "Already imported (receipt #\(id))"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

private struct UploadActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(13, .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 38)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rule, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: Filter panel

/// One panel with date and store chips, a live result count and the bulk confirm.
private struct FilterPanel: View {
    @ObservedObject var store: ReceiptStore
    let confirmAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Date")
                        FlowLayout(spacing: 6) {
                            ForEach(ReceiptStore.DateRange.allCases) { value in
                                Chip(text: value.rawValue, selected: store.dateRange == value) { store.dateRange = value }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Store")
                        FlowLayout(spacing: 6) {
                            Chip(text: "All stores", selected: store.storeFilter == nil) { store.storeFilter = nil }
                            ForEach(store.storesInUse, id: \.self) { value in
                                Chip(text: value, selected: store.storeFilter == value) { store.storeFilter = value }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Text(resultCount)
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.label)
                            .accessibilityIdentifier("filterResultCount")
                        Spacer()
                        if store.isFiltering {
                            Button("Clear filters") { store.clearReceiptFilters() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    }
                    .frame(minHeight: 44)
                    if store.confirmableWithoutFlagsCount > 0 {
                        Rectangle().fill(Theme.rule).frame(height: 1)
                        Button(action: confirmAll) {
                            Label("Confirm all without flags (\(store.confirmableWithoutFlagsCount))", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OutlineButtonStyle(color: Theme.greenText))
                    }
                }
                .padding(16)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Filters").font(Theme.display(18)).foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var resultCount: String {
        let count = store.filteredReceipts.count
        return count == 1 ? "1 receipt" : "\(count) receipts"
    }
}
