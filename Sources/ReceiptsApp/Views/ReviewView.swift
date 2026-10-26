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
            if let error = store.uploadError {
                Text(error)
                    .font(AppTheme.body(13))
                    .foregroundColor(AppTheme.penRed)
            }
            ReceiptListView()
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.desk)
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
