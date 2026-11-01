import SwiftUI

enum PhoneTab: Hashable { case receipts, overview, settings }

/// Tabs: Receipts (list, review, capture), Overview (spending charts), Settings (server, sync, photos).
struct RootView: View {
    @EnvironmentObject var store: ReceiptStore
    @StateObject private var snacks = SnackCenter()
    @State private var tab: PhoneTab = .receipts

    var body: some View {
        // The banners sit above the tabs (not in a safe-area inset, which would hide the navigation bars behind them).
        VStack(spacing: 0) {
            BannerStack(store: store, sync: store.sync)
            tabs
        }
        .background(Theme.desk)
        .environmentObject(snacks)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            ReceiptListScreen(goToSettings: { tab = .settings })
                .tabItem { Label("Receipts", systemImage: "list.bullet.rectangle.portrait") }
                .badge(store.receipts.filter { $0.reviewedAt == nil }.count)
                .tag(PhoneTab.receipts)
            OverviewScreen(isActive: tab == .overview)
                .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }
                .tag(PhoneTab.overview)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(PhoneTab.settings)
        }
        .tint(Theme.ink)
    }
}

/// The server's archive and disk flags, and the last failed store operation. Above the tabs, on every tab.
private struct BannerStack: View {
    @ObservedObject var store: ReceiptStore
    @ObservedObject var sync: SyncCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sync.banners, id: \.self) { text in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 16))
                        .accessibilityHidden(true)
                    Text(text)
                        .font(Theme.body(12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Sync now") { store.syncNow() }
                        .buttonStyle(OutlineButtonStyle(color: Theme.red))
                        .disabled(sync.phase == .syncing)
                        .fixedSize()
                }
                .foregroundStyle(Theme.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.redBg.ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.red.opacity(0.3)).frame(height: 1) }
            }
            if let error = store.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text(error)
                        .font(Theme.body(13, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        store.lastError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .foregroundStyle(.white)
                .padding(.leading, 14)
                .padding(.trailing, 2)
                .background(Theme.errorBar.ignoresSafeArea(edges: .top))
            }
        }
    }
}
