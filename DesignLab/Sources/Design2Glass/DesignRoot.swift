import LabCore
import SwiftUI

/// Design 2: an app Apple could have shipped on iOS 26. System components wherever they exist; glass only on the
/// navigation and control layer that floats above content.
public struct DesignRoot: View {
    @State private var model: GlassModel

    public init(initialScreen: LabScreen?) {
        _model = State(initialValue: GlassModel(screen: initialScreen ?? .list))
    }

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            GlassBanners(model: model)
            tabs(selection: $model.tab)
                .tabBarMinimizeBehavior(.onScrollDown)
        }
        .background(Color(.systemGroupedBackground))
        .labReportsScreen(model.screen)
    }

    @ViewBuilder
    private func tabs(selection: Binding<LabScreen.Tab>) -> some View {
        let view = TabView(selection: selection) {
            Tab("Receipts", systemImage: "list.bullet.rectangle.portrait", value: LabScreen.Tab.receipts) {
                ReceiptsTab(model: model)
            }
            Tab("Overview", systemImage: "chart.bar.xaxis", value: LabScreen.Tab.overview) {
                OverviewTab(model: model)
            }
            Tab("Settings", systemImage: "gearshape", value: LabScreen.Tab.settings) {
                SettingsTab(model: model)
            }
        }
        if #available(iOS 26.1, *) {
            view.tabViewBottomAccessory(isEnabled: model.tab == .receipts && model.connected && model.path.isEmpty) {
                GlassAccessory(model: model)
            }
        } else {
            view
        }
    }
}

/// The bottom accessory: global sync status, or upload progress while uploads are around.
private struct GlassAccessory: View {
    let model: GlassModel

    var body: some View {
        if model.uploads.isEmpty {
            HStack(spacing: 10) {
                if model.syncing {
                    ProgressView().controlSize(.small)
                }
                Text(model.syncing ? LabData.syncStatusSyncing : LabData.syncStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.runSync() }
                }
                .labelStyle(.iconOnly)
                .disabled(model.syncing)
            }
            .padding(.horizontal, 16)
        } else {
            Button {
                model.showUploads = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UploadsSheet.title(model.uploads))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        ProgressView(value: UploadsSheet.progress(model.uploads))
                    }
                    Image(systemName: "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Banners float above everything as glass panels, on every tab.
private struct GlassBanners: View {
    @Bindable var model: GlassModel

    var body: some View {
        if !model.banners.isEmpty || model.errorBanner != nil {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(model.banners, id: \.self) { text in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "externaldrive.badge.exclamationmark")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(text)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Sync now") {}
                                    .font(.footnote.weight(.semibold))
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    }
                    if let error = model.errorBanner {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                                .font(.footnote.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Dismiss", systemImage: "xmark") {
                                withAnimation { model.errorBanner = nil }
                            }
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.bold))
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .glassEffect(.regular.tint(.red), in: .rect(cornerRadius: 22))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

/// A small filled field for numbers inside form rows.
struct GlassNumberField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 76

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(width: width)
            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
    }
}

/// Amounts line up in columns.
extension Text {
    func amount() -> some View { monospacedDigit() }
}
