import SwiftUI
import AppKit
import ImageIO

/// Decodes archived receipt photos off the main thread and keeps them in memory. Images are
/// downsampled to `maxPixel` on the long edge so a 12 MP photo doesn't sit in memory at full size.
final class ReceiptImageCache: @unchecked Sendable {
    static let shared = ReceiptImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private let maxPixel = 4096

    init() { cache.countLimit = 12 }

    func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    /// nil when the file is missing or isn't a decodable image.
    func load(_ path: String) async -> NSImage? {
        if let hit = cached(path) { return hit }
        let maxPixel = maxPixel
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }
}

/// The archived source photo, shown beside the items: fit/100% toggle, pinch or +/- zoom,
/// click to open in Preview, and a placeholder when the file is missing.
struct ReceiptPhotoView: View {
    let path: String?

    private enum LoadState { case loading, loaded(NSImage), missing }
    @State private var state: LoadState = .loading
    /// Magnification relative to "fit in pane" (1 = fit).
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?

    private let maxZoom: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(AppTheme.rule).frame(height: 1)
            content
        }
        .background(AppTheme.desk)
        .task(id: path) {
            zoom = 1
            guard let path else { state = .missing; return }
            if let hit = ReceiptImageCache.shared.cached(path) { state = .loaded(hit); return }
            state = .loading
            if let image = await ReceiptImageCache.shared.load(path) {
                state = .loaded(image)
            } else {
                state = .missing
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("PHOTO")
                .font(AppTheme.body(11, weight: .medium))
                .foregroundColor(AppTheme.inkSoft)
            Spacer()
            Button { zoom = max(1, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button("Fit") { zoom = 1 }
                .help("Fit the whole receipt in the pane")
            Button("100%") { zoom = actualSizeZoom }
                .help("Show at actual pixel size")
            Button { zoom = min(maxZoom, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button { openInPreview() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open in Preview")
        }
        .buttonStyle(.borderless)
        .font(AppTheme.body(12))
        .foregroundColor(AppTheme.inkSoft)
        .disabled(!isLoaded)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.paper)
    }

    private var isLoaded: Bool { if case .loaded = state { return true }; return false }

    /// Zoom factor at which one image pixel is one screen point (needs the pane size; approximated
    /// from the last layout pass).
    @State private var paneSize: CGSize = .zero
    private var actualSizeZoom: CGFloat {
        guard case .loaded(let image) = state, paneSize.width > 0, paneSize.height > 0 else { return 1 }
        let fit = fitSize(for: image.size, in: paneSize)
        return min(maxZoom, max(1, image.size.width / max(fit.width, 1)))
    }

    private func fitSize(for image: CGSize, in pane: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return pane }
        let scale = min(pane.width / image.width, pane.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 28))
                Text("Image file not found")
                    .font(AppTheme.body(13, weight: .medium))
                if let path {
                    Text(path)
                        .font(AppTheme.mono(10))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundColor(AppTheme.inkSoft)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let image):
            GeometryReader { geo in
                let fit = fitSize(for: image.size, in: geo.size)
                let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        .onTapGesture { openInPreview() }
                        .help("Click to open in Preview")
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = zoomAtGestureStart ?? zoom
                            zoomAtGestureStart = start
                            zoom = min(maxZoom, max(1, start * value.magnification))
                        }
                        .onEnded { _ in zoomAtGestureStart = nil }
                )
                .onAppear { paneSize = geo.size }
                .onChange(of: geo.size) { paneSize = geo.size }
            }
        }
    }

    private func openInPreview() {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
