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
            if !store.uploadResults.isEmpty {
                uploadResultsList
            }
            ReceiptListView()
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.desk)
    }

    /// Per-file outcome of the last upload batch.
    private var uploadResultsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LAST UPLOAD")
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundColor(AppTheme.inkSoft)
                Spacer()
                Button("Clear") { store.uploadResults = [] }
                    .buttonStyle(.plain)
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.inkSoft)
                    .disabled(store.isProcessingUpload)
            }
            ForEach(store.uploadResults) { result in
                switch result.outcome {
                case .success(let id):
                    Text("✓ \(result.fileName): imported as receipt #\(id)")
                        .foregroundColor(AppTheme.ink)
                case .duplicate(let id):
                    Text("= \(result.fileName): Already imported (receipt #\(id))")
                        .foregroundColor(AppTheme.inkSoft)
                case .failure(let message):
                    Text("✗ \(result.fileName): \(message)")
                        .foregroundColor(AppTheme.penRed)
                }
            }
            .font(AppTheme.body(12))
        }
    }

    private var mainArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if let detail = store.selectedReceipt {
                        ReceiptDetailView(detail: detail)
                            .padding(.vertical, 48)
                    } else {
                        Text("Upload a receipt to get started, or pick one from the list to review it.")
                            .font(AppTheme.body(15))
                            .foregroundColor(AppTheme.inkSoft)
                            .multilineTextAlignment(.center)
                            .padding(.top, 120)
                            .frame(maxWidth: 400)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.highlightRequest) {
                guard let req = store.highlightRequest, req.receiptId == store.selectedReceipt?.id else { return }
                withAnimation {
                    proxy.scrollTo(req.itemDictionaryId, anchor: .center)
                }
            }
        }
        .background(AppTheme.desk)
    }
}
