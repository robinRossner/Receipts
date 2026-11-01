import LabCore
import PhotosUI
import SwiftUI

struct ReceiptsTab: View {
    @Bindable var model: GlassModel
    @Namespace private var transition
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if model.isSetup {
                    setupView
                } else {
                    mainContent
                        .searchable(text: $model.search, prompt: "Store, item or amount")
                        .toolbar { toolbar }
                }
            }
            .navigationTitle("Receipts")
            .navigationDestination(for: Int.self) { _ in
                ReceiptDetailView(model: model)
            }
        }
        .sheet(isPresented: $model.showFilters, onDismiss: {
            if model.pendingConfirmAll {
                model.pendingConfirmAll = false
                model.dialogConfirmAll = true
            }
        }) {
            FilterSheet(model: model)
                .presentationDetents([.medium, .large])
                .navigationTransition(.zoom(sourceID: "filter", in: transition))
        }
        .sheet(isPresented: $model.showUploads) {
            UploadsSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .alert("Document camera not available", isPresented: $model.alertScanUnavailable) {
            Button("OK") {}
        } message: {
            Text("This device cannot scan documents. Use “Choose photos” instead.")
        }
        .alert("Scan", isPresented: $model.alertScanNote) {
            Button("OK") {}
        } message: {
            Text("Only the first of 3 pages was added. A receipt is one photo; scan the other pages as separate receipts.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.isFiltering {
                filterButton.buttonStyle(.glassProminent)
            } else {
                filterButton
            }
        }
        .matchedTransitionSource(id: "filter", in: transition)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Scan receipt", systemImage: "doc.viewfinder") { model.alertScanUnavailable = true }
            PhotosPicker(selection: $photoSelection, maxSelectionCount: 20, matching: .images) {
                Label("Choose photos", systemImage: "photo.on.rectangle")
            }
        }
    }

    private var filterButton: some View {
        Button("Filter", systemImage: "line.3.horizontal.decrease") { model.showFilters = true }
            .confirmationDialog(
                "Confirm \(model.confirmableCount) receipts without flags?",
                isPresented: $model.dialogConfirmAll,
                titleVisibility: .visible
            ) {
                Button("Confirm all") { withAnimation { model.confirmAll() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Marks every unreviewed receipt that has no review reasons as reviewed. Receipts with warnings stay in “Needs review”.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var mainContent: some View {
        if model.receipts.isEmpty && model.deleted.isEmpty {
            ContentUnavailableView {
                Label("No receipts yet", systemImage: "doc.text")
            } description: {
                Text("Scan one with the camera or choose photos.")
            } actions: {
                Button("Scan receipt") { model.alertScanUnavailable = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.filtered.isEmpty {
            ContentUnavailableView {
                Label("No receipts match.", systemImage: "magnifyingglass")
            }
        } else {
            receiptList
        }
    }

    private var receiptList: some View {
        let filtered = model.filtered
        let unreviewed = filtered.filter { $0.reviewedAt == nil }
        let reviewed = filtered.filter { $0.reviewedAt != nil }
        return ScrollViewReader { proxy in
            List {
                if !unreviewed.isEmpty {
                    Section {
                        ForEach(unreviewed, id: \.sectionKey) { row($0) }
                    } header: {
                        HStack {
                            Text("Needs review")
                            Spacer()
                            Text("\(unreviewed.count) to review").foregroundStyle(.orange)
                        }
                        .textCase(nil)
                    }
                }
                if !reviewed.isEmpty {
                    Section {
                        ForEach(reviewed, id: \.sectionKey) { row($0) }
                    } header: {
                        Text("Reviewed").textCase(nil)
                    }
                }
                if !model.deleted.isEmpty {
                    Section {
                        DisclosureGroup("Recently deleted (\(model.deleted.count))", isExpanded: $model.deletedOpen) {
                            ForEach(model.deleted) { DeletedRow(model: model, receipt: $0) }
                        }
                    }
                    .id("deleted")
                }
            }
            .refreshable { await model.runSync() }
            .task {
                if model.scrollToDeleted {
                    model.scrollToDeleted = false
                    try? await Task.sleep(for: .seconds(0.2))
                    proxy.scrollTo("deleted", anchor: .top)
                }
            }
        }
    }

    private func row(_ receipt: LabReceipt) -> some View {
        NavigationLink(value: receipt.id) {
            ReceiptRow(receipt: receipt)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation { model.moveToDeleted(receipt) }
            }
        }
    }

    private var setupView: some View {
        ContentUnavailableView {
            Label("Connect to your server", systemImage: "icloud.and.arrow.up")
        } description: {
            Text("Receipts are read by your own backend. Enter its address and the receipts token in Settings.")
        } actions: {
            Button("Open Settings") { model.tab = .settings }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: Rows

private extension LabReceipt {
    /// Differs per section, so a receipt confirmed while the list is hidden behind a detail gets a fresh cell. With a
    /// plain id the cell is moved and keeps its old look.
    var sectionKey: String { "\(reviewedAt == nil ? "open" : "done")-\(id)" }
}

private struct ReceiptRow: View {
    let receipt: LabReceipt

    var body: some View {
        HStack(spacing: 10) {
            if receipt.reviewedAt == nil {
                leading.frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.store ?? (receipt.processing != nil ? "New receipt" : "Unknown"))
                    .font(.body.weight(receipt.reviewedAt == nil ? .semibold : .regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(subtitleIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if receipt.needsReview {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Has warnings")
            }
            if receipt.total != nil {
                Text(LabFormat.money(receipt.total)).amount()
            }
        }
    }

    /// Mail's unread dot, spinner while the server works, red mark when it failed.
    @ViewBuilder
    private var leading: some View {
        if let processing = receipt.processing {
            if processing.isActive {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } else {
            Circle().fill(.tint).frame(width: 9, height: 9)
        }
    }

    private var subtitle: String { receipt.processing?.label ?? receipt.date ?? "" }
    private var subtitleIsError: Bool { receipt.processing?.isActive == false }
}

private struct DeletedRow: View {
    let model: GlassModel
    let receipt: LabReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.store ?? "Unknown")
                Text("\(receipt.date ?? "") · \(LabFormat.money(receipt.total))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Button("Restore") { withAnimation { model.restore(receipt) } }
                Button("Delete") { model.permanentDelete = receipt }
                    .tint(.red)
                    .confirmationDialog(
                        "Permanently delete this receipt?",
                        isPresented: Binding(
                            get: { model.permanentDelete?.id == receipt.id },
                            set: { if !$0 { model.permanentDelete = nil } }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button("Delete permanently", role: .destructive) {
                            withAnimation { model.deleted.removeAll { $0.id == receipt.id } }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes the receipt, its items and the photo copy on this phone. It cannot be undone.")
                    }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Filter sheet

/// Same choices as production's filter `Menu`. A sheet, because SwiftUI cannot open a `Menu` from code.
private struct FilterSheet: View {
    @Bindable var model: GlassModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Date", selection: $model.dateFilter) {
                        ForEach(LabData.dateRanges, id: \.self) { Text($0) }
                    }
                    Picker("Store", selection: $model.storeFilter) {
                        Text("All stores").tag("All stores")
                        ForEach(LabData.storesInUse, id: \.self) { Text($0).tag($0) }
                    }
                    if model.isFiltering {
                        Button("Clear filters") {
                            withAnimation {
                                model.dateFilter = "All time"
                                model.storeFilter = "All stores"
                            }
                        }
                    }
                }
                if model.confirmableCount > 0 {
                    Section {
                        Button("Confirm all without flags (\(model.confirmableCount))") {
                            model.pendingConfirmAll = true
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

// MARK: Uploads sheet

struct UploadsSheet: View {
    @Bindable var model: GlassModel
    @Environment(\.dismiss) private var dismiss

    static func title(_ jobs: [LabUploadJob]) -> String {
        "Uploads - \(jobs.filter(\.state.isFinished).count) of \(jobs.count)"
    }

    static func progress(_ jobs: [LabUploadJob]) -> Double {
        jobs.isEmpty ? 0 : Double(jobs.filter(\.state.isFinished).count) / Double(jobs.count)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView(value: Self.progress(model.uploads))
                        HStack(spacing: 8) {
                            if model.uploads.contains(where: { !$0.state.isFinished }) {
                                Button("Cancel all") { cancelAll() }
                            }
                            if model.uploads.contains(where: \.state.isFailure) {
                                Button("Retry failed") { retryFailed() }
                            }
                            if model.uploads.contains(where: \.state.isFinished) {
                                Button("Clear finished") { clearFinished() }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    ForEach(model.uploads) { job in
                        row(job)
                    }
                }
            }
            .navigationTitle(Self.title(model.uploads))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func row(_ job: LabUploadJob) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.fill.tertiary, in: .rect(cornerRadius: 5))
            statusIcon(job.state)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(job.state.text)
                    .font(.caption)
                    .foregroundStyle(job.state.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !job.state.isFinished {
                Button("Cancel", systemImage: "xmark") { set(job.id, .cancelled) }
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .tint(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(job) }
    }

    @ViewBuilder
    private func statusIcon(_ state: LabUploadJob.State) -> some View {
        switch state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .scanning, .uploading: ProgressView().controlSize(.mini)
        case .uploaded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .duplicate: Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func open(_ job: LabUploadJob) {
        switch job.state {
        case .uploaded(let id), .duplicate(let id): model.open(id)
        default: break
        }
    }

    private func set(_ id: Int, _ state: LabUploadJob.State) {
        guard let index = model.uploads.firstIndex(where: { $0.id == id }) else { return }
        withAnimation { model.uploads[index].state = state }
    }

    private func cancelAll() {
        for job in model.uploads where !job.state.isFinished { set(job.id, .cancelled) }
    }

    private func retryFailed() {
        for job in model.uploads where job.state.isFailure { set(job.id, .queued) }
    }

    private func clearFinished() {
        withAnimation {
            model.uploads.removeAll { $0.state.isFinished }
            if model.uploads.isEmpty { dismiss() }
        }
    }
}
