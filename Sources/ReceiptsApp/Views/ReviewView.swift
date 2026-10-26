import SwiftUI

/// Ports #reviewPage from dashboard.html: a sidebar (upload zone + receipt list) and a main
/// area showing the selected receipt's detail card.
struct ReviewView: View {
    @EnvironmentObject var store: ReceiptStore

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            mainArea
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            UploadZoneView()
            if !store.uploadQueue.isEmpty {
                UploadQueueView()
            }
            ReceiptListView()
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.desk)
    }

    private var mainArea: some View {
        Group {
            if let detail = store.selectedReceipt {
                ReceiptDetailView(detail: detail)
                    .id(detail.id)
            } else if store.receipts.isEmpty, let warning = store.providerWarning {
                providerEmptyState(warning)
            } else {
                Text("Upload a receipt to get started, or pick one from the list to review it.")
                    .font(AppTheme.body(15))
                    .foregroundColor(AppTheme.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.desk)
    }

    /// Shown instead of the bare red warning when the AI backend isn't usable and there is nothing to look at yet.
    private func providerEmptyState(_ warning: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 40))
                .foregroundColor(AppTheme.inkSoft)
            Text("The AI backend isn't ready")
                .font(AppTheme.display(20))
                .foregroundColor(AppTheme.ink)
            Text(warning)
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.inkSoft)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                SettingsLink {
                    Text("Open Settings")
                        .font(AppTheme.body(13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(AppTheme.ink)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                Button {
                    Task { await store.checkProviderReadiness() }
                } label: {
                    HStack(spacing: 6) {
                        if store.isCheckingProvider { ProgressView().controlSize(.small) }
                        Text(store.isCheckingProvider ? "Checking…" : "Retry")
                    }
                    .font(AppTheme.body(13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
                    .foregroundColor(AppTheme.ink)
                }
                .buttonStyle(.plain)
                .disabled(store.isCheckingProvider)
            }
            Text("You can still add photos; they are processed once the backend works.")
                .font(AppTheme.body(11))
                .foregroundColor(AppTheme.inkSoft)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
