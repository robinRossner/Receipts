import SwiftUI

enum PhoneTab: Hashable { case receipts, overview, settings }

/// Tabs: Receipts (list, review, capture), Overview (spending charts), Settings (server, sync, photos).
struct RootView: View {
    @EnvironmentObject var store: ReceiptStore
    @State private var tab: PhoneTab = .receipts

    var body: some View {
        // The banners sit above the tabs (not in a safe-area inset, which would hide the navigation bars behind them).
        VStack(spacing: 0) {
            banners
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            ReceiptListScreen(goToSettings: { tab = .settings })
                .tabItem { Label("Receipts", systemImage: "list.bullet.rectangle.portrait") }
                .tag(PhoneTab.receipts)
            NavigationStack {
                OverviewView(isActive: tab == .overview)
                    .navigationTitle("Overview")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(AppTheme.paper, for: .navigationBar)
            }
            .tabItem { Label("Overview", systemImage: "chart.bar.xaxis") }
            .tag(PhoneTab.overview)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(PhoneTab.settings)
        }
        .tint(AppTheme.ink)
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            SyncBannersView(sync: store.sync)
            if let error = store.lastError {
                HStack(alignment: .top, spacing: 10) {
                    Text("⚠ \(error)")
                        .font(AppTheme.body(12))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.lastError = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(hex: 0xB33A3A).ignoresSafeArea(edges: .top))
            }
        }
    }
}
