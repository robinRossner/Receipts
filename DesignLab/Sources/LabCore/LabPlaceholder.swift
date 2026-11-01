import SwiftUI

/// What each design shows until its agent replaces the stub: a labelled page that follows the routing contract, so the
/// switcher and `-screen` can be checked before any design exists.
public struct LabPlaceholder: View {
    let title: String
    @State private var screen: LabScreen
    @State private var showSheet = false

    public init(title: String, initialScreen: LabScreen?) {
        self.title = title
        _screen = State(initialValue: initialScreen ?? .list)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Placeholder") {
                    LabeledContent("Design", value: title)
                    LabeledContent("Screen", value: screen.rawValue)
                    LabeledContent("Receipts", value: "\(LabData.receipts.count)")
                }
                if let receipt = screen.fixtureReceipt {
                    Section(receipt.store ?? "New receipt") {
                        ReceiptPhotoPlaceholder(receipt: receipt)
                            .frame(height: 420)
                            .listRowInsets(EdgeInsets())
                    }
                }
                Section("Overlay check") {
                    Button("Open a sheet") { showSheet = true }
                }
                Section("Open a screen") {
                    ForEach(LabScreen.allCases) { candidate in
                        Button(candidate.rawValue) { screen = candidate }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showSheet) {
            Text("Sheet: the switcher stays above this.").presentationDetents([.medium])
        }
        .labReportsScreen(screen)
    }
}
