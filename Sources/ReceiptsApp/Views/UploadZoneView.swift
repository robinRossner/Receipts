import SwiftUI
import UniformTypeIdentifiers

/// Ports the .upload-zone from dashboard.html: drag-and-drop or click-to-choose receipt
/// photos. Accepts several files and folders at once; everything goes into the store's upload
/// queue (shown by UploadQueueView), which can keep growing while a batch runs.
struct UploadZoneView: View {
    @EnvironmentObject var store: ReceiptStore
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 4) {
            Text("Drop receipt photos or folders here, or click to choose files")
                .font(AppTheme.body(14, weight: .medium))
                .foregroundColor(AppTheme.ink)
                .multilineTextAlignment(.center)
            Text("JPG, PNG, or HEIC - one or several at once")
                .font(AppTheme.body(12))
                .foregroundColor(AppTheme.inkSoft)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(isTargeted ? Color(hex: 0xFBF8F1) : AppTheme.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isTargeted ? AppTheme.penRed : AppTheme.rule, style: StrokeStyle(lineWidth: 2, dash: [5]))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.isImporterPresented = true }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Resolves every dropped file's URL (each comes back through its own async callback) before
    /// enqueueing them together, so a multi-file drop keeps its order in the queue.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let syncQueue = DispatchQueue(label: "com.receiptsapp.upload-drop-sync")
        var urls = [URL?](repeating: nil, count: fileProviders.count)
        let group = DispatchGroup()

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolved: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                syncQueue.sync { urls[index] = resolved }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let resolvedURLs = urls.compactMap { $0 }
            guard !resolvedURLs.isEmpty else { return }
            store.upload(fileURLs: resolvedURLs)
        }
        return true
    }
}
