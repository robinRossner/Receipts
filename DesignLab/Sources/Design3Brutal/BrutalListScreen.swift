import LabCore
import PhotosUI
import SwiftUI

struct BrutalListScreen: View {
    @Bindable var model: BrutalModel
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 0) {
            hero
            ZStack(alignment: .top) {
                content
                if model.filtersOpen {
                    BP.scrim.opacity(BT.scrim)
                        .contentShape(Rectangle())
                        .onTapGesture { model.filtersOpen = false }
                    BrutalFilterPanel(model: model)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.12), value: model.filtersOpen)
        }
        .background(BP.page)
    }

    private var hero: some View {
        HeroSlab {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    IconBlock(system: model.isFiltering || model.isSearching && model.noMatch
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                              label: "Filters", fill: model.isFiltering ? BP.pink : BP.card,
                              ink: model.isFiltering ? BP.onAccent : BP.text) {
                        KeyboardWatcher.dismiss()
                        model.filtersOpen.toggle()
                    }
                    TitleBlock(text: "Receipts", tab: .receipts)
                    Spacer(minLength: 0)
                    IconBlock(system: "doc.viewfinder", label: "Scan receipt") {
                        model.dialog = .scanUnavailable
                    }
                    PhotosPicker(selection: $photoSelection, maxSelectionCount: 20, matching: .images) {
                        IconBlockLabel(system: "photo.on.rectangle")
                    }
                    .buttonStyle(IconBlockStyle())
                    .accessibilityLabel("Choose photos")
                    .onChange(of: photoSelection) { photoSelection = [] }
                }
                if !model.setupNeeded || !model.hasNoReceipts {
                    searchField
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BP.text2)
                .padding(.leading, 10)
            TextField("", text: $model.search, prompt: Text("Store, item or amount").foregroundStyle(BP.text2))
                .font(BF.body(16, .medium))
                .foregroundStyle(BP.text)
                .tint(BP.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(BP.text)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(height: 44)
        .slab(BP.card, border: BT.borderThin)
    }

    @ViewBuilder
    private var content: some View {
        if model.setupNeeded && model.hasNoReceipts {
            setup
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        syncRow
                        if !model.uploads.isEmpty { BrutalUploadPanel(model: model) }
                        if model.hasNoReceipts {
                            message("No receipts yet. Scan one with the camera or choose photos.", icon: "doc.viewfinder", fill: BP.yellow)
                        } else if model.noMatch {
                            message("No receipts match.", icon: "magnifyingglass", fill: BP.pink)
                        } else {
                            sections
                        }
                        if !model.deleted.isEmpty && !model.noMatch { deletedSection }
                        Color.clear.frame(height: 4).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    model.runSync()
                    try? await Task.sleep(for: .seconds(1))
                }
                .task {
                    if model.deletedOpen {
                        try? await Task.sleep(for: .milliseconds(200))
                        proxy.scrollTo("deleted", anchor: .top)
                    }
                }
            }
        }
    }

    private var syncRow: some View {
        HStack(spacing: 8) {
            if model.syncing { BlockSpinner(size: 13) }
            Text(model.syncing ? LabData.syncStatusSyncing : LabData.syncStatus)
                .font(BF.mono(12, .regular))
                .foregroundStyle(BP.text2)
            Spacer()
            Button {
                model.runSync()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BP.text2)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sync now")
        }
    }

    @ViewBuilder
    private var sections: some View {
        let needs = model.needsReview
        if !needs.isEmpty {
            HStack(spacing: 10) {
                SectionLabel(text: "Needs review")
                Sticker(text: "\(needs.count) to review")
                Spacer()
            }
            ForEach(needs) { receipt in row(receipt) }
        }
        let done = model.reviewedList
        if !done.isEmpty {
            SectionLabel(text: "Reviewed")
                .padding(.top, 6)
            ForEach(done) { receipt in row(receipt) }
        }
    }

    private func row(_ receipt: LabReceipt) -> some View {
        BrutalSwipeRow(onDelete: { model.softDelete(receipt.id) }) {
            Button {
                KeyboardWatcher.dismiss()
                model.open(receipt.id)
            } label: {
                BrutalReceiptRow(receipt: receipt)
            }
            // Only what still needs you gets a shadow.
            .buttonStyle(PressInStyle(shadow: receipt.reviewedAt == nil ? BT.shadowCard : 0))
        }
    }

    private func message(_ text: String, icon: String, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(BP.onAccent)
                .frame(width: 50, height: 50)
                .background(fill)
                .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.border))
                .rotationEffect(.degrees(-BT.tiltSticker))
            Text(text)
                .font(BF.body(18, .semibold))
                .foregroundStyle(BP.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .slab(shadow: BT.shadowCard)
        .padding(.top, 6)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(BP.onAccent)
                .frame(width: 60, height: 60)
                .background(BP.blue)
                .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.border))
                .rotationEffect(.degrees(-BT.tiltSticker))
            Text("Connect to your server")
                .font(BF.display(22))
                .foregroundStyle(BP.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Receipts are read by your own backend. Enter its address and the receipts token in Settings.")
                .font(BF.body(16))
                .foregroundStyle(BP.text)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { model.tab = .settings }
                .buttonStyle(.slabPrimary)
        }
        .padding(16)
        .slab(shadow: BT.shadowCard)
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    // MARK: Recently deleted

    private var deletedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.deletedOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(model.deletedOpen ? "▾" : "▸")
                        .font(BF.mono(15))
                    Text("Recently deleted (\(model.deleted.count))")
                        .font(BF.label(14))
                        
                    Spacer()
                }
                .foregroundStyle(BP.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .overlay(Rectangle().strokeBorder(BP.line, style: StrokeStyle(lineWidth: BT.borderThin, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id("deleted")

            if model.deletedOpen {
                ForEach(model.deleted) { receipt in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(receipt.store ?? "Unknown")
                                .font(BF.body(16, .semibold))
                                .foregroundStyle(BP.text)
                            Text("\(receipt.date ?? "—") · \(LabFormat.money(receipt.total))")
                                .font(BF.mono(13, .regular))
                                .foregroundStyle(BP.text2)
                        }
                        HStack(spacing: 10) {
                            Button("Restore") { model.restore(receipt.id) }
                                .buttonStyle(SlabButtonStyle(fill: BP.card, ink: BP.text, border: BT.borderThin, shadow: 0, height: 44, font: BF.label(14)))
                            Button("Delete") { model.dialog = .permanentDelete(receipt.id) }
                                .buttonStyle(SlabButtonStyle(fill: BP.card, ink: BP.redText, border: BT.borderThin, shadow: 0, height: 44, font: BF.label(14)))
                        }
                    }
                    .padding(12)
                    .slab(BP.card, border: BT.borderThin)
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: Row

struct BrutalReceiptRow: View {
    let receipt: LabReceipt

    private var unreviewed: Bool { receipt.reviewedAt == nil }

    var body: some View {
        HStack(spacing: 0) {
            if unreviewed {
                BP.redFill.frame(width: 6)
                BP.line.frame(width: BT.borderThin)
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(receipt.store ?? (receipt.processing != nil ? "New receipt" : "Unknown"))
                        .font(BF.body(16, .semibold))
                        .foregroundStyle(BP.text)
                        .lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 4)
                if let total = receipt.total {
                    Text(LabFormat.money(total))
                        .font(BF.mono(16))
                        .foregroundStyle(BP.text)
                        .padding(.trailing, receipt.needsReview ? 10 : 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(minHeight: 58)
        .background(BP.card)
        .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.border))
        .overlay(alignment: .topTrailing) {
            if receipt.needsReview {
                Sticker(text: "⚠", font: BF.label(13))
                    .offset(x: 5, y: -7)
                    .accessibilityLabel("Needs review")
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let processing = receipt.processing {
            HStack(spacing: 6) {
                if processing.isActive { BlockSpinner(size: 11, color: BP.text2) }
                Text(processing.label)
                    .font(BF.body(13, .medium))
                    .foregroundStyle(processing.isActive ? BP.text2 : BP.redText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        } else {
            Text(receipt.date ?? "—")
                .font(BF.mono(13, .regular))
                .foregroundStyle(BP.text2)
        }
    }
}

/// Swipe left reveals a red `Delete` block; a long swipe deletes straight away.
struct BrutalSwipeRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    private let revealWidth: CGFloat = 104

    var body: some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button(action: onDelete) {
                    VStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Delete")
                            .font(BF.label(13))
                    }
                    .foregroundStyle(BP.onRed)
                    .frame(width: revealWidth - 8)
                    .frame(maxHeight: .infinity)
                    .background(BP.redFill)
                    .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            content()
                .offset(x: offset)
                .gesture(HorizontalPan(
                    onChange: { x in offset = min(0, settled + x) },
                    onEnd: { _ in
                        let target: CGFloat = offset < -revealWidth * 2.2 ? -500 : (offset < -revealWidth / 2 ? -revealWidth : 0)
                        withAnimation(.easeOut(duration: 0.14)) { offset = target }
                        settled = target
                        if target == -500 { onDelete() }
                    }
                ))
        }
    }
}

// MARK: Filter panel

struct BrutalFilterPanel: View {
    @Bindable var model: BrutalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Filters")
                Spacer()
                IconBlock(system: "xmark", label: "Close filters") { model.filtersOpen = false }
            }
            BrutalPicker(label: "Date", value: model.dateFilter, options: LabData.dateRanges) { model.dateFilter = $0 }
            BrutalPicker(label: "Store", value: model.storeFilter ?? "All stores", options: ["All stores"] + LabData.storesInUse) {
                model.storeFilter = $0 == "All stores" ? nil : $0
            }
            if model.isFiltering {
                Button("Clear filters") {
                    model.dateFilter = LabData.dateRanges[0]
                    model.storeFilter = nil
                }
                .buttonStyle(.slabPlain)
            }
            if model.unflaggedCount > 0 {
                HeavyRule().padding(.vertical, 2)
                Button("Confirm all without flags (\(model.unflaggedCount))") {
                    model.filtersOpen = false
                    model.dialog = .confirmAll(model.unflaggedCount)
                }
                .buttonStyle(.slabPrimary)
            }
        }
        .padding(14)
        .slab(BP.card, border: BT.borderDialog, shadow: BT.shadowDialog)
    }
}

// MARK: Upload panel

struct BrutalUploadPanel: View {
    let model: BrutalModel

    private var jobs: [LabUploadJob] { model.uploads }
    private var finished: Int { jobs.filter(\.state.isFinished).count }
    private var hasPending: Bool { jobs.contains { !$0.state.isFinished } }
    private var hasFailures: Bool { jobs.contains(where: \.state.isFailure) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Uploads - \(finished) of \(jobs.count)")
                .font(BF.label(14))
                .foregroundStyle(BP.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { BP.line.frame(height: BT.rule) }
            VStack(alignment: .leading, spacing: 10) {
                buttons
                progress
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(jobs) { job in
                            jobRow(job)
                            if job.id != jobs.last?.id { BP.line.frame(height: BT.ruleThin) }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            .padding(12)
        }
        .slab()
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if hasPending {
            Button("Cancel all") {
                for i in model.uploads.indices where !model.uploads[i].state.isFinished { model.uploads[i].state = .cancelled }
            }
            .buttonStyle(.slabSmall())
        }
        if hasFailures {
            Button("Retry failed") {
                for i in model.uploads.indices where model.uploads[i].state.isFailure { model.uploads[i].state = .queued }
            }
            .buttonStyle(.slabSmall())
        }
        if finished > 0 {
            Button("Clear finished") { model.uploads.removeAll(where: \.state.isFinished) }
                .buttonStyle(.slabSmall())
        }
    }

    /// One flush block per job, so progress reads as discrete pieces of work.
    private var progress: some View {
        HStack(spacing: 0) {
            ForEach(jobs) { job in
                (job.state.isFailure ? BP.redFill : (job.state.isFinished ? BP.green : BP.card))
                    .frame(height: 10)
                if job.id != jobs.last?.id { BP.line.frame(width: BT.borderThin, height: 10) }
            }
        }
        .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
        .accessibilityLabel("\(finished) of \(jobs.count) finished")
    }

    private func jobRow(_ job: LabUploadJob) -> some View {
        HStack(spacing: 8) {
            thumbnail
            statusIcon(job.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.fileName)
                    .font(BF.mono(12, .medium))
                    .foregroundStyle(BP.text)
                    .lineLimit(1)
                Text(job.state.text)
                    .font(BF.body(12))
                    .foregroundStyle(job.state.isFailure ? BP.redText : BP.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !job.state.isFinished {
                Button {
                    if let i = model.uploads.firstIndex(where: { $0.id == job.id }) { model.uploads[i].state = .cancelled }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(BP.text)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel \(job.fileName)")
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            switch job.state {
            case .uploaded(let id), .duplicate(let id): model.open(id)
            default: break
            }
        }
    }

    private var thumbnail: some View {
        Rectangle()
            .fill(Color(white: 0.2))
            .frame(width: 22, height: 22)
            .overlay(
                Rectangle()
                    .fill(Color(red: 0.97, green: 0.96, blue: 0.92))
                    .frame(width: 11, height: 16)
            )
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
    }

    @ViewBuilder
    private func statusIcon(_ state: LabUploadJob.State) -> some View {
        switch state {
        case .uploading, .scanning: BlockSpinner(size: 15)
        case .queued: icon("clock", BP.text2)
        case .uploaded: icon("checkmark", BP.text)
        case .duplicate: icon("doc.on.doc", BP.text2)
        case .failed: icon("exclamationmark.triangle.fill", BP.redText)
        case .cancelled: icon("slash.circle", BP.text2)
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16)
    }
}
