import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// The system document camera (find the page, straighten it, take several pages). Not available in the simulator.
struct DocumentScannerView: UIViewControllerRepresentable {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    /// The first page and how many pages were scanned.
    let onScan: (UIImage, Int) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { parent.onCancel(); return }
            parent.onScan(scan.imageOfPage(at: 0), scan.pageCount)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.onCancel() }
    }
}

/// Turns what the user picked or scanned into files and hands them to the shared upload queue
/// (`ReceiptStore.upload`: duplicate check, straighten, JPEG of at most 2500 px under 4.5 MB, stored in the outbox
/// before the first upload attempt, so nothing is lost offline and uploads resume after a relaunch).
@MainActor
enum ReceiptImporter {
    private static var stagingDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("receipt-imports", isDirectory: true)
    }

    /// A receipt is one photo (`photo_sha256`, one `source_image`), so a multi-page scan is not merged: the first page
    /// is the receipt and the user is told.
    static func importScan(_ image: UIImage, pages: Int, store: ReceiptStore, note: @escaping (String?) -> Void) {
        guard let data = image.jpegData(compressionQuality: 0.95) else { note("The scan could not be saved."); return }
        do {
            let url = try write(data, ext: "jpg")
            store.upload(fileURLs: [url], preStraightened: true)
            if pages > 1 { note("Only the first of \(pages) pages was added. A receipt is one photo; scan the other pages as separate receipts.") }
        } catch {
            note("The scan could not be saved: \(error.localizedDescription)")
        }
    }

    /// PhotosPicker items (JPEG, PNG, HEIC...) in their original format; the pipeline converts them.
    static func importPhotos(_ items: [PhotosPickerItem], store: ReceiptStore, note: @escaping (String?) -> Void) async {
        var urls: [URL] = []
        var failed = 0
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { failed += 1; continue }
                let ext = item.supportedContentTypes.compactMap(\.preferredFilenameExtension).first ?? "jpg"
                urls.append(try write(data, ext: ext))
            } catch {
                failed += 1
            }
        }
        if !urls.isEmpty { store.upload(fileURLs: urls) }
        if failed > 0 { note("\(failed) photo(s) could not be loaded.") }
    }

    private static func write(_ data: Data, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let url = stagingDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
