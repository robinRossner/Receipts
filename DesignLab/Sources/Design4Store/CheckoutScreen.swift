import LabCore
import Observation
import SwiftUI

// MARK: The Receipts tab: one long receipt coming out of a printer

struct CheckoutScreen: View {
    @Bindable var model: StoreModel
    private static let endAnchor = "paperEnd"

    private let printInset = ST.paperInset
    @State private var paperEdge = PaperEdge()

    var body: some View {
        VStack(spacing: 0) {
            printer
            ZStack(alignment: .top) {
                content
                slotShadow
                if model.filtersOpen { filterRack }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SP.page.ignoresSafeArea())
    }

    // MARK: Printer: title, tools, search, and the slot the paper leaves

    private var printer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text("Receipts")
                    .font(SF.sign(34))
                    .foregroundStyle(SP.tillText)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                ToolbarIcon(systemName: filterIcon, label: "Filter", active: model.filtersOpen || model.isFiltering) {
                    KeyboardWatcher.dismiss()
                    withAnimation(.snappy(duration: 0.2)) { model.filtersOpen.toggle() }
                }
                ToolbarIcon(systemName: "doc.viewfinder", label: "Scan receipt") { model.dialog = .scanUnavailable }
                ToolbarIcon(systemName: "photo.on.rectangle", label: "Choose photos") {}
            }
            if !model.setupNeeded { searchField }
        }
        .padding(.horizontal, ST.paperMargin)
        .padding(.bottom, 8)
        .background(SP.till.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { PrinterSlot().offset(y: 7) }
        .padding(.bottom, 7)
        .zIndex(1)
    }

    private var filterIcon: String {
        model.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SP.listInk2)
            TextField("", text: $model.search, prompt: Text("Store, item or amount").foregroundStyle(SP.listInk2))
                .font(SF.print(15))
                .foregroundStyle(SP.listInk)
                .tint(SP.listRed)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.search.isEmpty {
                Button { model.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SP.listInk2)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(SP.listPaper)
    }

    /// Where the paper leaves the slot.
    private var slotShadow: some View {
        LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 9)
            .padding(.horizontal, ST.paperMargin)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Printed furniture

    /// The head of the receipt: a small heading, then the sync status with its button.
    private var masthead: some View {
        VStack(spacing: 0) {
            Text("— KASSENBON —")
                .font(SF.print(12))
                .foregroundStyle(SP.listInk2)
                .padding(.top, 14)
                .accessibilityHidden(true)
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if model.syncing {
                        ProgressView().controlSize(.mini).tint(SP.listInk2)
                        Text(LabData.syncStatusSyncing)
                    } else {
                        Text(LabData.syncStatus)
                    }
                }
                .frame(maxWidth: .infinity)
                Button { model.runSync() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync now")
            }
            .font(SF.print(13))
            .foregroundStyle(SP.listInk)
            .padding(.trailing, 2)
        }
    }

    private func printedHeader(_ title: String, badge: String? = nil) -> some View {
        ZStack(alignment: .trailing) {
            Text(title)
                .font(SF.print(14, bold: true))
                .foregroundStyle(SP.listInk)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            if let badge {
                Text(badge)
                    .font(SF.shelf(12))
                    .foregroundStyle(SP.tagInk)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(SP.tag)
            }
        }
        .padding(.horizontal, printInset)
        .frame(minHeight: 36)
    }

    /// The count and sum of the printed lines above it, from the same list.
    private var summary: some View {
        let lines = model.needsReview + model.reviewedList
        let sum = lines.compactMap(\.total).reduce(0, +)
        return VStack(spacing: 6) {
            VStack(spacing: 2) {
                SP.listInk.frame(height: 1.5)
                SP.listInk.frame(height: 1.5)
            }
            HStack {
                Text("\(lines.count) receipts")
                Spacer()
                Text(LabFormat.money(sum))
            }
            .font(SF.print(15, bold: true))
            .foregroundStyle(SP.listInk)
        }
        .padding(.horizontal, printInset)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var paperEnd: some View {
        VStack(spacing: 6) {
            Barcode(seed: 4, color: SP.listInk)
                .frame(height: 40)
                .padding(.horizontal, 60)
            Text("VIELEN DANK")
                .font(SF.print(11))
                .foregroundStyle(SP.listInk)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 20 + ST.tear)
    }

    // MARK: Main content

    @ViewBuilder private var content: some View {
        if model.setupNeeded && model.hasNoReceipts {
            setupPaper
        } else if model.hasNoReceipts {
            shortPaper("No receipts yet. Scan one with the camera or choose photos.", clearFilters: false)
        } else if model.noMatch {
            shortPaper("No receipts match.", clearFilters: true)
        } else {
            receiptList
        }
    }

    private var setupPaper: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 26, weight: .regular))
                Text("Connect to your server")
                    .font(SF.print(16, bold: true))
                Text("Receipts are read by your own backend. Enter its address and the receipts token in Settings.")
                    .font(SF.print(14))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { model.tab = .settings }
                    .buttonStyle(FlatKeyStyle(face: SP.tag, ink: SP.tagInk, font: SF.shelf(15)))
                    .padding(.top, 6)
            }
            .foregroundStyle(SP.listInk)
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 24 + ST.tear)
            .frame(maxWidth: .infinity)
            .background(TornPaper().fill(SP.listPaper))
            .padding(.horizontal, ST.paperMargin)
            Spacer()
        }
    }

    /// A short length of paper with one printed message.
    private func shortPaper(_ message: String, clearFilters: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                masthead
                DottedRule(color: SP.listRule, dash: [3, 3], width: 1)
                    .padding(.horizontal, ST.paperInset)
                Text(message)
                    .font(SF.print(15))
                    .foregroundStyle(SP.listInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                if clearFilters {
                    Button("Clear filters") {
                        model.search = ""
                        model.dateFilter = LabData.dateRanges[0]
                        model.storeFilter = nil
                    }
                    .buttonStyle(FlatKeyStyle(face: SP.listKey, ink: SP.listInk))
                }
            }
            .padding(.bottom, 26 + ST.tear)
            .frame(maxWidth: .infinity)
            .background(TornPaper().fill(SP.listPaper))
            .padding(.horizontal, ST.paperMargin)
            Spacer()
        }
    }

    private var receiptList: some View {
        ScrollViewReader { proxy in
            List {
                masthead
                    .paperRow()

                if !model.uploads.isEmpty {
                    UploadsPrint(model: model)
                        .paperRow()
                }

                let review = model.needsReview
                if !review.isEmpty {
                    printedHeader("*** NEEDS REVIEW ***", badge: "\(review.count) to review")
                        .padding(.top, 8)
                        .paperRow(rule: true)
                    ForEach(review) { receipt in
                        PrintedLine(receipt: receipt) { model.open(receipt.id) }
                            .paperRow(marked: true, rule: true)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteAction(receipt) }
                    }
                }

                let filed = model.reviewedList
                if !filed.isEmpty {
                    printedHeader("--- REVIEWED ---")
                        .padding(.top, 16)
                        .paperRow(rule: true)
                    ForEach(filed) { receipt in
                        PrintedLine(receipt: receipt) { model.open(receipt.id) }
                            .paperRow(rule: true)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteAction(receipt) }
                    }
                }

                summary
                    .paperRow()

                if !model.deleted.isEmpty {
                    deletedHeader
                        .padding(.top, 10)
                        .paperRow(rule: true)
                    if model.deletedOpen {
                        ForEach(model.deleted) { receipt in
                            DeletedLine(model: model, receipt: receipt)
                                .paperRow(rule: true)
                        }
                    }
                }

                paperEnd
                    .paperRow(torn: true)
                    .id(Self.endAnchor)

                Color.clear
                    .frame(height: 22)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .listRowSpacing(0)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            // Bottom of the content, less the spacer row and the torn end: the sheet stops behind the end piece.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.contentOffset.y - 70 } action: { _, bottom in
                paperEdge.bottom = bottom
            }
            // One sheet behind the rows: no gap when pulling down or swiping a row, and it stops at the torn end.
            .background(alignment: .top) { PaperSheet(edge: paperEdge) }
            // The list is exactly as wide as the paper, so a swiped row never covers the margins.
            .padding(.horizontal, ST.paperMargin)
            .refreshable {
                model.runSync()
                try? await Task.sleep(for: .seconds(1.0))
            }
            .onAppear {
                // Opening with the section open shows it, not the top of the list.
                guard model.deletedOpen else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(Self.endAnchor, anchor: .bottom) }
            }
        }
    }

    private func deleteAction(_ receipt: LabReceipt) -> some View {
        Button(role: .destructive) { model.softDelete(receipt.id) } label: {
            Label("Delete", systemImage: "trash")
        }
        .tint(SP.keyRed)
    }

    private var deletedHeader: some View {
        Button {
            withAnimation(ST.unfold) { model.deletedOpen.toggle() }
        } label: {
            ZStack(alignment: .trailing) {
                Text("--- RECENTLY DELETED (\(model.deleted.count)) ---")
                    .font(SF.print(14, bold: true))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                Image(systemName: model.deletedOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(SP.listInk)
            .padding(.horizontal, printInset)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Filter panel

    private var filterRack: some View {
        ZStack(alignment: .top) {
            SP.scrim.opacity(0.35)
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.filtersOpen = false } }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                rackRow("Date", options: LabData.dateRanges.map { range in
                    (range, model.dateFilter == range, { model.dateFilter = range })
                })
                rackRow("Store", options: [("All stores", model.storeFilter == nil, { model.storeFilter = nil })]
                    + LabData.storesInUse.map { store in (store, model.storeFilter == store, { model.storeFilter = store }) })

                if model.isFiltering {
                    Button {
                        model.dateFilter = LabData.dateRanges[0]
                        model.storeFilter = nil
                    } label: { WideLabel(text: "Clear filters") }
                    .buttonStyle(FlatKeyStyle(font: SF.shelf(15)))
                }
                if model.unflaggedCount > 0 {
                    Button {
                        model.filtersOpen = false
                        model.dialog = .confirmAll(model.unflaggedCount)
                    } label: { WideLabel(text: "Confirm all without flags (\(model.unflaggedCount))") }
                    .buttonStyle(FlatKeyStyle(font: SF.shelf(15)))
                }
            }
            .padding(14)
            .background(SP.floor)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func rackRow(_ title: String, options: [(String, Bool, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SF.sign(18))
                .foregroundStyle(SP.aisleText)
                .padding(.bottom, 2)
            ShelfRail()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        ShelfTagButton(title: option.0, selected: option.1, action: option.2)
                    }
                }
            }
        }
    }
}

// MARK: The strip

/// Where the paper's end piece sits in the list. Kept apart so scrolling only redraws the sheet.
@MainActor @Observable
private final class PaperEdge {
    var bottom: CGFloat = .infinity
}

/// The paper behind all rows. It stops inside the end piece, so the torn edge is the end of the paper.
private struct PaperSheet: View {
    let edge: PaperEdge

    var body: some View {
        SP.listPaper
            .frame(maxHeight: max(0, edge.bottom))
    }
}

private extension View {
    /// A list row printed on the strip. The paper is the row's background, so it stays put when a row is swiped.
    func paperRow(marked: Bool = false, rule: Bool = false, torn: Bool = false) -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(PaperStrip(marked: marked, rule: rule, torn: torn))
            .listRowSeparator(.hidden)
    }
}

private struct PaperStrip: View {
    let marked: Bool
    let rule: Bool
    let torn: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if torn {
                TornPaper().fill(SP.listPaper)
            } else {
                SP.listPaper
            }
            // The red ink of a thermal roll, on the paper's edge
            if marked { SP.listRed.frame(width: 4) }
        }
        .overlay(alignment: .bottom) {
            if rule {
                DottedRule(color: SP.listRule, dash: [3, 3], width: 1)
                    .padding(.horizontal, ST.paperInset)
            }
        }
    }
}

/// A plain toolbar icon on the printer. Yellow, like a tag, while active.
private struct ToolbarIcon: View {
    let systemName: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(active ? SP.tagInk : SP.tillText)
                .frame(width: 44, height: 44)
                .background(active ? SP.tag : Color.clear, ignoresSafeAreaEdges: [])
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: One receipt as printed lines

private struct PrintedLine: View {
    let receipt: LabReceipt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(receipt.store ?? (receipt.processing != nil ? "New receipt" : "Unknown"))
                        .font(SF.print(15, bold: true))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if receipt.total != nil || receipt.processing == nil {
                        Text(LabFormat.money(receipt.total))
                            .font(SF.print(15, bold: true))
                            .layoutPriority(1)
                    }
                }
                HStack(spacing: 6) {
                    statusLine
                    Spacer(minLength: 0)
                    if receipt.needsReview {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(SP.listRed)
                            .accessibilityLabel("Has warnings")
                    }
                }
            }
            .foregroundStyle(SP.listInk)
            .padding(.horizontal, ST.paperInset)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var statusLine: some View {
        if let processing = receipt.processing {
            if processing.isActive { ProgressView().controlSize(.mini).tint(SP.listInk2) }
            Text(processing.label)
                .font(SF.print(13, bold: !processing.isActive))
                .foregroundStyle(processing.isActive ? SP.listInk2 : SP.listRed)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            Text(receipt.date ?? "")
                .font(SF.print(13))
                .foregroundStyle(SP.listInk2)
        }
    }
}

private struct DeletedLine: View {
    @Bindable var model: StoreModel
    let receipt: LabReceipt

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.store ?? "Unknown")
                    .font(SF.print(15, bold: true))
                    .lineLimit(1)
                Text("\(receipt.date ?? "—") · \(LabFormat.money(receipt.total))")
                    .font(SF.print(12))
                    .foregroundStyle(SP.listInk2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(SP.listInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore") { withAnimation(ST.unfold) { model.restore(receipt.id) } }
                .buttonStyle(FlatKeyStyle(face: SP.listKey, ink: SP.listInk))
                .fixedSize()
            Button("Delete") { model.dialog = .permanentDelete(receipt.id) }
                .buttonStyle(FlatKeyStyle(face: SP.listKey, ink: SP.listRed))
                .fixedSize()
        }
        .padding(.horizontal, ST.paperInset)
        .padding(.vertical, 8)
    }
}

// MARK: Uploads, printed at the top of the paper

private struct UploadsPrint: View {
    @Bindable var model: StoreModel

    /// Whole rows only: five fit before it scrolls, so no row is cut in half.
    private let rowHeight: CGFloat = 46
    private let visibleRows = 5

    private var finished: Int { model.uploads.filter(\.state.isFinished).count }
    private var hasPending: Bool { model.uploads.contains { !$0.state.isFinished } }
    private var hasFailures: Bool { model.uploads.contains(where: \.state.isFailure) }

    var body: some View {
        VStack(spacing: 6) {
            Text("UPLOADS - \(finished) of \(model.uploads.count)")
                .font(SF.print(14, bold: true))
                .foregroundStyle(SP.listInk)
                .padding(.top, 8)
            progressBar
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.uploads) { job in jobRow(job) }
                }
            }
            .frame(height: rowHeight * CGFloat(min(model.uploads.count, visibleRows)))
            HStack(spacing: 6) {
                if hasPending {
                    Button("Cancel all") { model.uploads.removeAll { !$0.state.isFinished } }
                        .buttonStyle(FlatKeyStyle(face: SP.listKey, ink: SP.listInk, font: SF.shelf(13)))
                }
                if hasFailures {
                    Button("Retry failed") {
                        for i in model.uploads.indices where model.uploads[i].state.isFailure { model.uploads[i].state = .queued }
                    }
                    .buttonStyle(FlatKeyStyle(face: SP.listKey, ink: SP.listInk, font: SF.shelf(13)))
                }
                if finished > 0 {
                    Button("Clear finished") { model.uploads.removeAll(where: \.state.isFinished) }
                        .buttonStyle(FlatKeyStyle(face: SP.listKey, ink: SP.listInk, font: SF.shelf(13)))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, ST.paperInset)
        .padding(.bottom, 6)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                SP.listRule.opacity(0.35)
                SP.listInk.frame(width: geo.size.width * CGFloat(finished) / CGFloat(max(1, model.uploads.count)))
            }
        }
        .frame(height: 3)
    }

    private func jobRow(_ job: LabUploadJob) -> some View {
        HStack(spacing: 8) {
            SP.listKey
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(SP.listInk2))
            statusIcon(job.state)
            VStack(alignment: .leading, spacing: 0) {
                Text(job.fileName).font(SF.print(13, bold: true)).foregroundStyle(SP.listInk).lineLimit(1)
                Text(job.state.text)
                    .font(SF.print(11))
                    .foregroundStyle(job.state.isFailure ? SP.listRed : SP.listInk2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !job.state.isFinished {
                Button { model.uploads.removeAll { $0.id == job.id } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SP.listInk2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }
        }
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) { DottedRule(color: SP.listRule, dash: [3, 3], width: 1) }
    }

    @ViewBuilder private func statusIcon(_ state: LabUploadJob.State) -> some View {
        switch state {
        case .queued: icon("clock", SP.listInk2)
        case .scanning, .uploading: ProgressView().controlSize(.mini).tint(SP.listInk2).frame(width: 16)
        case .uploaded: icon("checkmark.circle", SP.listInk)
        case .duplicate: icon("doc.on.doc", SP.listInk2)
        case .failed: icon("exclamationmark.triangle.fill", SP.listRed)
        case .cancelled: icon("xmark.circle", SP.listInk2)
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .medium)).foregroundStyle(color).frame(width: 16)
    }
}
