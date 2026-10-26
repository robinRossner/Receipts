import SwiftUI

enum AppPage {
    case review
    case overview
}

/// Ports dashboard.html's top-level layout: a top nav with Review/Overview tabs, and the two
/// pages below it. No "Stop" button - that only existed to kill a separate server process,
/// which this single-process app doesn't have (⌘Q is the native equivalent).
struct ContentView: View {
    @EnvironmentObject var store: ReceiptStore
    @State private var page: AppPage = .review

    var body: some View {
        VStack(spacing: 0) {
            topNav
            Rectangle().fill(AppTheme.rule).frame(height: 1)
            if let error = store.lastError {
                errorBanner(error)
            }
            // Both pages stay mounted (never destroyed), same as dashboard.html's `hidden`
            // divs - so Overview's expand/collapse state survives switching tabs.
            ZStack {
                ReviewView()
                    .opacity(page == .review ? 1 : 0)
                    .allowsHitTesting(page == .review)
                OverviewView(isActive: page == .overview)
                    .opacity(page == .overview ? 1 : 0)
                    .allowsHitTesting(page == .overview)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.desk)
        .onChange(of: store.isImporterPresented) {
            if store.isImporterPresented { page = .review }
        }
        .onChange(of: store.highlightRequest) {
            if store.highlightRequest != nil { page = .review }
        }
    }

    private var topNav: some View {
        HStack(spacing: 14) {
            Text("Receipts")
                .font(AppTheme.display(20))
                .foregroundColor(AppTheme.ink)
            Spacer()
            if let warning = store.providerWarning {
                Text(warning)
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.penRed)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            HStack(spacing: 6) {
                tabButton("Review", .review)
                tabButton("Overview", .overview)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(AppTheme.paper)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("⚠ \(message)")
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
        .background(AppTheme.penRed)
    }

    private func tabButton(_ title: String, _ target: AppPage) -> some View {
        let isActive = page == target
        return Button {
            page = target
        } label: {
            Text(title)
                .font(AppTheme.body(13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(isActive ? AppTheme.ink : Color.clear)
                .foregroundColor(isActive ? .white : AppTheme.inkSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? AppTheme.ink : AppTheme.rule, lineWidth: 1)
                )
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
