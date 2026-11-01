import SwiftUI

/// "Items without a category" on the iPhone: pushed from Overview, with a receipt one tap away.
struct FlaggedItemsScreen: View {
    let openReceipt: (_ receiptId: Int, _ itemDictionaryId: Int) -> Void

    var body: some View {
        FlaggedItemsView(openReceipt: openReceipt)
            .navigationTitle("Without a category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Without a category").font(Theme.display(18)).foregroundStyle(Theme.ink)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
    }
}
