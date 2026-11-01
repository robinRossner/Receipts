import SwiftUI

/// Ports dashboard.html's top-level layout: a top nav with Review/Overview tabs, and the two
/// pages below it. No "Stop" button - that only existed to kill a separate server process,
/// which this single-process app doesn't have (⌘Q is the native equivalent).
struct ContentView: View {
    @EnvironmentObject var store: ReceiptStore
    @EnvironmentObject var snacks: SnackCenter

    private var toReview: Int { store.receipts.filter { $0.reviewedAt == nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            topNav
            Rectangle().fill(AppTheme.rule).frame(height: 1)
            SyncBannersView(sync: store.sync)
            if let error = store.lastError {
                errorBanner(error)
            }
            // Both pages stay mounted (never destroyed), same as dashboard.html's `hidden`
            // divs - so Overview's expand/collapse state survives switching tabs.
            ZStack {
                ReviewView()
                    .opacity(store.page == .review ? 1 : 0)
                    .allowsHitTesting(store.page == .review)
                OverviewView(isActive: store.page == .overview)
                    .opacity(store.page == .overview ? 1 : 0)
                    .allowsHitTesting(store.page == .overview)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let snack = snacks.current {
                    UndoBar(snack: snack, undo: snacks.performUndo)
                        .padding(.bottom, 76)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(AppTheme.desk)
        .sheet(isPresented: $store.exportSheetPresented) { ExportSheet() }
        .onChange(of: store.isImporterPresented) {
            if store.isImporterPresented { store.page = .review }
        }
        .onChange(of: store.highlightRequest) {
            if store.highlightRequest != nil { store.page = .review }
        }
    }

    private var topNav: some View {
        HStack(spacing: 14) {
            Text("Receipts")
                .font(AppTheme.display(20))
                .foregroundColor(AppTheme.ink)
            Spacer()
            // With no receipts yet, ReviewView shows the warning as a full empty state instead.
            if let warning = store.providerWarning, (!store.receipts.isEmpty || store.page == .overview) {
                Text(warning)
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.penRed)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .help(warning)
            }
            SyncStatusView(sync: store.sync)
            HStack(spacing: 6) {
                tabButton("Review", .review, badge: toReview)
                tabButton("Overview", .overview, badge: 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(AppTheme.paper)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(.top, 1)
            Text(message)
                .font(AppTheme.body(12))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(AppTheme.errorBar)
    }

    private func tabButton(_ title: String, _ target: AppPage, badge: Int) -> some View {
        let isActive = store.page == target
        return Button {
            store.page = target
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(AppTheme.body(13, weight: .medium))
                if badge > 0 {
                    Text("\(badge)")
                        .font(AppTheme.mono(11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(AppTheme.penRed)
                        .foregroundColor(AppTheme.onRed)
                        .clipShape(Capsule())
                        .accessibilityLabel("\(badge) to review")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(isActive ? AppTheme.ink : Color.clear)
            .foregroundColor(isActive ? AppTheme.onInk : AppTheme.inkSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? AppTheme.ink : AppTheme.rule, lineWidth: 1)
            )
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The transient "something happened, Undo" bar.
private struct UndoBar: View {
    let snack: SnackCenter.Snack
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(snack.text)
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.onInk)
                .lineLimit(1)
            Button(action: undo) {
                Text("Undo")
                    .font(AppTheme.body(13, weight: .semibold))
                    .underline()
                    .foregroundColor(AppTheme.onInk)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(AppTheme.ink)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

/// The soft background a row gets under the pointer.
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? AppTheme.ink.opacity(0.05) : Color.clear)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

extension ReceiptStore {
    /// `Looks good` and ⌘↩: confirm, move on to the next receipt, offer Undo (which comes back to this one).
    func confirmWithUndo(id: Int, name: String?, snacks: SnackCenter) async {
        await confirmReceipt(id: id)
        snacks.show("\(name ?? "Receipt") reviewed") { [weak self] in
            await self?.markUnreviewed(id: id)
            await self?.loadReceiptDetail(id: id)
        }
    }

    /// Moves a receipt to "Recently deleted" and offers Undo.
    func deleteWithUndo(id: Int, snacks: SnackCenter) async {
        await deleteReceipt(id: id)
        snacks.show("Moved to Recently deleted") { [weak self] in await self?.restoreReceipt(id: id) }
    }
}
