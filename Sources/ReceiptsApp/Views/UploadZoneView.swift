import SwiftUI
import UniformTypeIdentifiers

/// Ports the .upload-zone from dashboard.html: drag-and-drop or click-to-choose receipt
/// photos. Supports multiple files at once (multi-select in the picker, or dropping several
/// files together) - they're processed sequentially, in the order given.
struct UploadZoneView: View {
    @EnvironmentObject var store: ReceiptStore
    @State private var isTargeted = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 4) {
            Text(store.uploadProgressLabel ?? "Drop receipt photos here, or click to choose files")
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
        .opacity(store.isProcessingUpload ? 0.55 : 1.0)
        .allowsHitTesting(!store.isProcessingUpload)
        .contentShape(Rectangle())
        .onTapGesture { showFileImporter = true }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.jpeg, .png, .heic, .heif, .image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                Task { await store.upload(fileURLs: urls) }
            }
        }
    }

    /// Resolves every dropped file's URL (each comes back through its own async callback) before
    /// kicking off one batch upload, so multi-file drops are processed in a single ordered pass
    /// rather than as a pile of overlapping uploads.
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
            Task { await store.upload(fileURLs: resolvedURLs) }
        }
        return true
    }
}
