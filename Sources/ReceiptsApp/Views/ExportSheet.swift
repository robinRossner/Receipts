import SwiftUI

/// File > Export… : what to export, for which range, and the CSV flavour.
struct ExportSheet: View {
    @EnvironmentObject var store: ReceiptStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ReceiptStore.ExportKind = .lineItemsCSV
    @State private var useOverviewRange = true
    @State private var format: DataExporter.Format = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(AppTheme.display(20))
            Picker("Content", selection: $kind) {
                ForEach(ReceiptStore.ExportKind.allCases) { Text($0.rawValue).tag($0) }
            }
            if kind != .everythingJSON {
                Picker("Range", selection: $useOverviewRange) {
                    Text("Overview range: \(store.overviewRange.label)").tag(true)
                    Text("All time").tag(false)
                }
                Picker("Format", selection: $format) {
                    ForEach(DataExporter.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("UTF-8 with BOM, so Excel shows umlauts correctly.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("All receipts with their items, plus the item dictionary. Deleted receipts are left out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Export…") {
                    dismiss()
                    Task { await store.export(kind: kind, useOverviewRange: useOverviewRange, format: format) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
