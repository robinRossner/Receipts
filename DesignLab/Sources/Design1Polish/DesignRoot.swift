import LabCore
import SwiftUI

/// Design 1: the current app, polished. Same paper look, same structure, same flows.
public struct DesignRoot: View {
    @State private var store: PolishStore

    public init(initialScreen: LabScreen?) {
        _store = State(initialValue: PolishStore(screen: initialScreen ?? .list))
    }

    public var body: some View {
        VStack(spacing: 0) {
            BannerStack(store: store)
            TabView(selection: $store.tab) {
                Tab("Receipts", systemImage: "list.bullet.rectangle.portrait", value: LabScreen.Tab.receipts) {
                    ReceiptListScreen(store: store)
                }
                .badge(store.reviewCount)
                Tab("Overview", systemImage: "chart.bar.xaxis", value: LabScreen.Tab.overview) {
                    OverviewScreen(store: store)
                }
                Tab("Settings", systemImage: "gearshape", value: LabScreen.Tab.settings) {
                    SettingsScreen(store: store)
                }
            }
        }
        .background(P.desk)
        .tint(P.ink)
        .labReportsScreen(store.currentScreen)
    }
}

/// Banners sit above the tabs on every tab.
private struct BannerStack: View {
    let store: PolishStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.banners, id: \.self) { text in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 16))
                    Text(text)
                        .font(P.body(12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Sync now") {
                        Task {
                            await store.syncNow()
                            store.banners.removeAll { $0 == text }
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(color: P.red))
                    .fixedSize()
                }
                .foregroundStyle(P.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(P.redBg)
                .overlay(alignment: .bottom) { Rectangle().fill(P.red.opacity(0.3)).frame(height: 1) }
            }
            if let error = store.errorBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text(error)
                        .font(P.body(13, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        store.errorBanner = nil
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
                .background(P.errorBar.ignoresSafeArea(edges: .top))
            }
        }
    }
}
