import LabCore
import PhotosUI
import SwiftUI

struct ReceiptListScreen: View {
    @Bindable var store: PolishStore
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack(path: $store.receiptsPath) {
            Group {
                if !store.connected && !store.hasReceipts {
                    setupPrompt
                } else {
                    list
                }
            }
            .background(P.desk)
            .navigationTitle("Receipts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(P.paper, for: .navigationBar)
            .toolbar { toolbar }
            .navigationDestination(for: Int.self) { id in
                ReceiptDetailScreen(store: store, receiptId: id, path: $store.receiptsPath)
            }
            .safeAreaInset(edge: .bottom) { snackbar }
        }
        .sheet(isPresented: $store.showFilters) {
            FilterPanel(store: store)
                .presentationDetents([.fraction(0.72), .large])
                .presentationBackground(P.desk)
                .presentationDragIndicator(.visible)
        }
        .alert("Document camera not available", isPresented: $store.scanUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device cannot scan documents. Use “Choose photos” instead.")
        }
        .alert("Scan", isPresented: Binding(get: { store.scanNote != nil }, set: { if !$0 { store.scanNote = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.scanNote ?? "")
        }
        .confirmationDialog("Confirm \(store.unflaggedCount) receipts without flags?", isPresented: $store.confirmAll, titleVisibility: .visible) {
            Button("Confirm all") { store.confirmAllWithoutFlags() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks every unreviewed receipt that has no review reasons as reviewed. Receipts with warnings stay in “Needs review”.")
        }
        .confirmationDialog(
            "Permanently delete this receipt?",
            isPresented: Binding(get: { store.pendingPermanentDelete != nil }, set: { if !$0 { store.pendingPermanentDelete = nil } }),
            titleVisibility: .visible,
            presenting: store.pendingPermanentDelete
        ) { receipt in
            Button("Delete permanently", role: .destructive) { store.deleted.removeAll { $0.id == receipt.id } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the receipt, its items and the photo copy on this phone. It cannot be undone.")
        }
        .onChange(of: pickerItems) { pickerItems = [] }
    }

    @ViewBuilder private var snackbar: some View {
        if let snack = store.snack, store.receiptsPath.isEmpty {
            SnackbarView(snack: snack) { store.snack = nil }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("Receipts").font(P.display(20)).foregroundStyle(P.ink)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                store.showFilters = true
            } label: {
                Image(systemName: store.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filters")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                store.scanUnavailable = true
            } label: {
                Image(systemName: "doc.viewfinder")
            }
            .accessibilityLabel("Scan receipt")
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo.on.rectangle")
            }
            .accessibilityLabel("Choose photos")
        }
    }

    // MARK: Setup

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 44))
                .foregroundStyle(P.label)
            Text("Connect to your server")
                .font(P.display(22))
                .foregroundStyle(P.ink)
            Text("Receipts are read by your own backend. Enter its address and the receipts token in Settings.")
                .font(P.body(15))
                .foregroundStyle(P.label)
                .multilineTextAlignment(.center)
            Button("Open Settings") { store.tab = .settings }
                .buttonStyle(OutlineButtonStyle(fill: true))
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                SyncRow(store: store)
                    .plainRow(top: 0, bottom: 0)
                if store.isFiltering { activeFilters.plainRow(top: 2, bottom: 6) }
                if !store.uploads.isEmpty { UploadPanel(store: store).plainRow(top: 4, bottom: 8) }
                if !store.hasReceipts {
                    emptyState.plainRow(top: 40, bottom: 20)
                } else if store.filtered.isEmpty {
                    noMatchState.plainRow(top: 40, bottom: 20)
                }
                section("Needs review", store.needsReview, badge: store.needsReview.count)
                section("Reviewed", store.reviewed, badge: nil)
                recentlyDeleted
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Store, item or amount")
            .refreshable { await store.syncNow() }
            .task {
                guard store.scrollToDeleted else { return }
                store.scrollToDeleted = false
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo("deleted-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LabReceipt], badge: Int?) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { receipt in
                    Button {
                        store.receiptsPath.append(receipt.id)
                    } label: {
                        ReceiptRow(receipt: receipt)
                    }
                    .buttonStyle(.plain)
                    .plainRow(top: 4, bottom: 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { store.delete(receipt) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(P.red)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if receipt.reviewedAt == nil && receipt.processing == nil {
                            Button { store.confirmFromList(receipt) } label: {
                                Label("Looks good", systemImage: "checkmark")
                            }
                            .tint(P.green)
                        }
                    }
                }
            } header: {
                HStack {
                    SectionLabel(text: title)
                    Spacer()
                    if let badge, badge > 0 {
                        Text("\(badge) to review")
                            .font(P.body(12, .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(P.red, in: Capsule())
                            .foregroundStyle(P.onRed)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(P.desk)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    @ViewBuilder private var recentlyDeleted: some View {
        if !store.deleted.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { store.showDeleted.toggle() }
            } label: {
                HStack(spacing: 8) {
                    SectionLabel(text: "Recently deleted (\(store.deleted.count))")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(P.label)
                        .rotationEffect(.degrees(store.showDeleted ? 90 : 0))
                }
                .padding(.horizontal, 2)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .plainRow(top: 10, bottom: 0)
            if store.showDeleted {
                ForEach(store.deleted) { receipt in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(receipt.store ?? "Unknown")
                                .font(P.body(15, .semibold))
                                .foregroundStyle(P.ink)
                                .lineLimit(1)
                            Text("\(receipt.date ?? "") · \(LabFormat.money(receipt.total))")
                                .font(P.mono(12))
                                .foregroundStyle(P.inkSoft)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 4)
                        Button("Restore") { withAnimation { store.restore(receipt) } }
                            .buttonStyle(OutlineButtonStyle())
                            .fixedSize()
                        Button("Delete") { store.pendingPermanentDelete = receipt }
                            .buttonStyle(OutlineButtonStyle(color: P.red))
                            .fixedSize()
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .background(P.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: P.corner))
                    .overlay(RoundedRectangle(cornerRadius: P.corner).strokeBorder(P.rule, lineWidth: 1))
                    .plainRow(top: 3, bottom: 3)
                }
            }
            Color.clear.frame(height: 1).id("deleted-bottom").plainRow(top: 0, bottom: 0)
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(P.label)
            Text("No receipts yet. Scan one with the camera or choose photos.")
                .font(P.body(15))
                .foregroundStyle(P.label)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    store.scanUnavailable = true
                } label: {
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
                .foregroundStyle(P.label)
            Text("No receipts match.")
                .font(P.body(15))
                .foregroundStyle(P.label)
            Button("Clear filters") { store.clearFilters() }
                .buttonStyle(OutlineButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    /// What is filtering the list right now; tap to remove.
    private var activeFilters: some View {
        FlowLayout(spacing: 6) {
            if !store.searchText.isEmpty { filterTag("“\(store.searchText)”") { store.searchText = "" } }
            if store.dateFilter != "All time" { filterTag(store.dateFilter) { store.dateFilter = "All time" } }
            if let storeFilter = store.storeFilter { filterTag(storeFilter) { store.storeFilter = nil } }
        }
    }

    private func filterTag(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .font(P.body(13, .medium))
            .foregroundStyle(P.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(P.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(P.rule, lineWidth: 1))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    let receipt: LabReceipt

    private var isUnreviewed: Bool { receipt.reviewedAt == nil }
    private var hasKnownTotal: Bool { receipt.processing == nil || receipt.total != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.store ?? (receipt.processing == nil ? "Unknown" : "New receipt"))
                    .font(P.body(16, .semibold))
                    .foregroundStyle(P.ink)
                    .lineLimit(1)
                if let processing = receipt.processing {
                    HStack(spacing: 5) {
                        if processing.isActive {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                        }
                        Text(processing.label).font(P.body(13)).lineLimit(1)
                    }
                    .foregroundStyle(processing.isActive ? P.inkSoft : P.red)
                } else {
                    Text(receipt.date ?? "")
                        .font(P.mono(12))
                        .foregroundStyle(P.inkSoft)
                }
                if isUnreviewed, let reason = receipt.reviewReasons.first {
                    Label {
                        Text(reason).lineLimit(1)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    }
                    .labelStyle(TightLabel())
                    .font(P.body(12.5))
                    .foregroundStyle(P.red)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
            if hasKnownTotal {
                Text(LabFormat.money(receipt.total))
                    .font(P.mono(15, .medium))
                    .foregroundStyle(P.ink)
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(P.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(P.red).frame(width: isUnreviewed ? 4 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: P.corner))
        .overlay(RoundedRectangle(cornerRadius: P.corner).strokeBorder(P.rule, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

private struct SyncRow: View {
    let store: PolishStore

    private var text: String {
        switch store.syncPhase {
        case .synced: return LabData.syncStatus
        case .syncedNow: return "Synced just now"
        case .syncing: return LabData.syncStatusSyncing
        case .failedRetrying: return LabData.syncStatusFailed
        case .failed: return "Sync failed"
        case .notYet: return "Not synced yet"
        }
    }

    private var color: Color {
        switch store.syncPhase {
        case .failed: return P.red
        default: return P.label
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if store.syncPhase == .syncing {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(store.syncPhase == .failed ? P.red : store.syncPhase == .failedRetrying ? P.series[1] : P.green)
                    .frame(width: 7, height: 7)
            }
            Text(text).font(P.body(12.5)).foregroundStyle(color)
            Spacer()
            IconButton(systemName: "arrow.triangle.2.circlepath", label: "Sync now", color: P.label, size: 14) {
                Task { await store.syncNow() }
            }
            .disabled(store.syncPhase == .syncing)
            .padding(.trailing, -10)
        }
        .padding(.leading, 2)
    }
}

// MARK: Snackbar

struct SnackbarView: View {
    let snack: PolishStore.Snack
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(snack.text)
                .font(P.body(14))
                .foregroundStyle(P.onInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                snack.undo()
                dismiss()
            } label: {
                Text("Undo")
                    .font(P.body(14, .semibold))
                    .foregroundStyle(P.onInk)
                    .underline()
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(P.ink, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

// MARK: Upload panel

private struct UploadPanel: View {
    let store: PolishStore

    private var finished: Int { store.uploads.filter { $0.state.isFinished }.count }
    private var hasPending: Bool { store.uploads.contains { !$0.state.isFinished } }
    private var hasFailed: Bool { store.uploads.contains { $0.state.isFailure } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Uploads - \(finished) of \(store.uploads.count)")
                Spacer()
            }
            ProgressView(value: Double(finished), total: Double(max(store.uploads.count, 1)))
                .progressViewStyle(.linear)
                .tint(P.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.uploads) { job in row(job) }
                }
            }
            .frame(maxHeight: 232)
            HStack(spacing: 6) {
                if hasPending { action("Cancel all", store.cancelAllUploads) }
                if hasFailed { action("Retry failed", store.retryFailedUploads) }
                action("Clear finished", store.clearFinishedUploads)
            }
        }
        .paperCard(padding: 12)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(UploadActionStyle())
    }

    private func receiptId(_ job: LabUploadJob) -> Int? {
        switch job.state {
        case .uploaded(let id), .duplicate(let id): return id
        default: return nil
        }
    }

    private func row(_ job: LabUploadJob) -> some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.2))
                .frame(width: 22, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.97, green: 0.96, blue: 0.92)).frame(width: 11, height: 16)
                }
            statusIcon(job.state)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.fileName)
                    .font(P.body(13, .medium))
                    .foregroundStyle(P.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.state.text)
                    .font(P.body(12))
                    .foregroundStyle(job.state.isFailure ? P.red : P.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !job.state.isFinished {
                IconButton(systemName: "xmark", label: "Cancel upload", size: 12) { store.cancelUpload(job.id) }
                    .padding(.vertical, -6)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = receiptId(job), store.receipt(id) != nil { store.receiptsPath.append(id) }
        }
    }

    @ViewBuilder private func statusIcon(_ state: LabUploadJob.State) -> some View {
        switch state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(P.inkSoft).font(.system(size: 13))
        case .scanning, .uploading:
            ProgressView().controlSize(.mini)
        case .uploaded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(P.greenText).font(.system(size: 14))
        case .duplicate:
            Image(systemName: "doc.on.doc").foregroundStyle(P.inkSoft).font(.system(size: 12))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(P.red).font(.system(size: 14))
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(P.inkSoft).font(.system(size: 14))
        }
    }
}

private struct UploadActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(P.body(13, .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(P.ink)
            .frame(maxWidth: .infinity, minHeight: 38)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(P.rule, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: Filter panel

private struct FilterPanel: View {
    @Bindable var store: PolishStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Date")
                        FlowLayout(spacing: 6) {
                            ForEach(LabData.dateRanges, id: \.self) { value in
                                Chip(text: value, selected: store.dateFilter == value) { store.dateFilter = value }
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
                            .font(P.mono(13))
                            .foregroundStyle(P.label)
                        Spacer()
                        if store.isFiltering {
                            Button("Clear filters") { store.clearFilters() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    }
                    .frame(minHeight: 44)
                    if store.unflaggedCount > 0 {
                        Rectangle().fill(P.rule).frame(height: 1)
                        Button {
                            dismiss()
                            Task {
                                try? await Task.sleep(for: .milliseconds(450))
                                store.confirmAll = true
                            }
                        } label: {
                            Label("Confirm all without flags (\(store.unflaggedCount))", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OutlineButtonStyle(color: P.greenText))
                    }
                }
                .padding(16)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Filters").font(P.display(18)).foregroundStyle(P.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var resultCount: String {
        let count = store.filtered.count
        return count == 1 ? "1 receipt" : "\(count) receipts"
    }
}
