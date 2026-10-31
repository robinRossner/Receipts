import Foundation
import ImageIO

/// One file in the batch upload queue (ReceiptStore.uploadQueue).
struct UploadJob: Identifiable {
    enum State: Equatable {
        case queued
        case scanning
        case extracting
        case categorizing
        case saving
        /// Cloud sync: the prepared photo is being sent to the server.
        case uploading
        case done(receiptId: Int)
        /// Cloud sync: the server has the photo and reads the receipt (it arrives with the next sync).
        case uploaded(receiptId: Int)
        case duplicate(receiptId: Int)
        case failed(String)
        case cancelled

        /// Nothing more will happen to this job unless it is retried.
        var isFinished: Bool {
            switch self {
            case .done, .uploaded, .duplicate, .failed, .cancelled: return true
            default: return false
            }
        }

        var isRunning: Bool {
            switch self {
            case .scanning, .extracting, .categorizing, .saving, .uploading: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let fileURL: URL
    var fileName: String { fileURL.lastPathComponent }
    var thumbnail: PlatformImage?
    var state: State = .queued
    /// Set once the photo is prepared and stored for upload: a retry then repeats only the upload.
    var cloudReceiptUUID: String?
    /// The page was already straightened (the phone's document camera): skip the document search.
    var preStraightened = false
}

enum UploadInput {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    /// Splits picked/dropped URLs into files to process and files to reject. Folders are
    /// expanded one level (non-recursive, hidden files skipped). PDFs are rejected: DocumentScanner
    /// only handles raster images.
    static func expand(_ urls: [URL]) -> (supported: [URL], unsupported: [URL]) {
        var supported: [URL] = []
        var unsupported: [URL] = []
        func classify(_ url: URL) {
            imageExtensions.contains(url.pathExtension.lowercased()) ? supported.append(url) : unsupported.append(url)
        }
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )) ?? []
                // Non-image files inside folders are ignored silently; only explicit picks are reported.
                supported += children
                    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                classify(url)
            }
        }
        return (supported, unsupported)
    }

    /// Small preview for a queue row; nil if the file can't be decoded.
    static func thumbnail(for url: URL, maxPixels: Int = 64) -> PlatformImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return ImageDecoding.thumbnail(at: url, maxPixel: maxPixels)
    }
}
