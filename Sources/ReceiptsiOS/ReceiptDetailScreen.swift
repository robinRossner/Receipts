import SwiftUI

/// One receipt: the shared review card (`ReceiptDetailView`: photo and items, editable header, warnings, confirm) in a
/// navigation screen. "Looks good" confirms and moves on to the next receipt to review, in place, like on the Mac.
struct ReceiptDetailScreen: View {
    let id: Int
    @EnvironmentObject var store: ReceiptStore
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let detail = store.selectedReceipt {
                ReceiptDetailView(detail: detail)
                    .id(detail.id)
                    .navigationTitle(detail.store ?? "Receipt")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.desk)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(AppTheme.paper, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)   // room for the items and the confirm bar
        .task {
            await store.loadReceiptDetail(id: id)
            loaded = true
        }
        .onChange(of: store.selectedReceipt?.id) {
            // Deleted (or gone after a sync): back to the list.
            if loaded, store.selectedReceipt == nil { dismiss() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
    }
}
