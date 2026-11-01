import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#endif

/// Decodes archived receipt photos off the main thread and keeps them in memory. Images are
/// downsampled to `maxPixel` on the long edge so a 12 MP photo doesn't sit in memory at full size.
final class ReceiptImageCache: @unchecked Sendable {
    static let shared = ReceiptImageCache()
    private let cache = NSCache<NSString, PlatformImage>()
    private let maxPixel = 4096

    init() { cache.countLimit = 12 }

    /// Forgets decoded images (e.g. after the file cache was cleared).
    func removeAll() { cache.removeAllObjects() }

    func cached(_ path: String) -> PlatformImage? { cache.object(forKey: path as NSString) }

    /// nil when the file is missing or isn't a decodable image.
    func load(_ path: String) async -> PlatformImage? {
        if let hit = cached(path) { return hit }
        let maxPixel = maxPixel
        let image: PlatformImage? = await Task.detached(priority: .userInitiated) {
            ImageDecoding.thumbnail(at: URL(fileURLWithPath: path), maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }
}

/// The archived source photo, shown beside the items: fit/100% toggle, pinch or +/- zoom,
/// click to open in Preview, and a placeholder when the file is missing.
struct ReceiptPhotoView: View {
    let path: String?
    /// Why there is no photo to show (still on the server, missing here, none); replaces the generic "not found".
    var note: String?

    private enum LoadState { case loading, loaded(PlatformImage), missing }
    @State private var state: LoadState = .loading
    /// Magnification relative to "fit in pane" (1 = fit).
    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?

    private let maxZoom: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            #if os(iOS)
            Rectangle().fill(Theme.rule).frame(height: 1)
            #else
            Rectangle().fill(AppTheme.rule).frame(height: 1)
            #endif
            content
        }
        #if os(iOS)
        .background(Theme.desk)
        #else
        .background(AppTheme.desk)
        #endif
        .task(id: "\(path ?? "")|\(note ?? "")") {
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

    #if os(iOS)
    private var toolbar: some View {
        HStack(spacing: 2) {
            SectionLabel(text: "Photo")
            Spacer()
            IconButton(systemName: "minus.magnifyingglass", label: "Zoom out", color: Theme.ink, size: 16) { setZoom(zoom / 1.5) }
            barText("Fit", active: zoom == 1) { setZoom(1) }
            barText("100%", active: isLoaded && zoom == actualSizeZoom && zoom != 1) { setZoom(actualSizeZoom) }
            IconButton(systemName: "plus.magnifyingglass", label: "Zoom in", color: Theme.ink, size: 16) { setZoom(zoom * 1.5) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .background(Theme.paper)
        .disabled(!isLoaded)
        .opacity(isLoaded ? 1 : 0.4)
    }

    private func barText(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(13, active ? .semibold : .regular))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 32)
                .background(active ? Theme.rule.opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) { zoom = min(maxZoom, max(1, value)) }
    }
    #else
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
            #if os(macOS)
            Button { openInPreview() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open in Preview")
            #endif
        }
        .buttonStyle(.borderless)
        .font(AppTheme.body(12))
        .foregroundColor(AppTheme.inkSoft)
        .disabled(!isLoaded)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.paper)
    }
    #endif

    private var isLoaded: Bool { if case .loaded = state { return true }; return false }

    /// Zoom factor at which one image pixel is one screen point (needs the pane size; approximated
    /// from the last layout pass).
    @State private var paneSize: CGSize = .zero
    private var actualSizeZoom: CGFloat {
        guard case .loaded(let image) = state, paneSize.width > 0, paneSize.height > 0 else { return 1 }
        let fit = fitSize(for: image.pixelSize, in: paneSize)
        return min(maxZoom, max(1, image.pixelSize.width / max(fit.width, 1)))
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
            #if os(iOS)
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 44))
                Text(note ?? "Image file not found")
                    .font(Theme.body(15))
                    .multilineTextAlignment(.center)
                if note == nil, let path {
                    Text(path)
                        .font(Theme.mono(10))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(Theme.label)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 28))
                Text(note ?? "Image file not found")
                    .font(AppTheme.body(13, weight: .medium))
                    .multilineTextAlignment(.center)
                if note == nil, let path {
                    Text(path)
                        .font(AppTheme.mono(10))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundColor(AppTheme.inkSoft)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        case .loaded(let image):
            GeometryReader { geo in
                let fit = fitSize(for: image.pixelSize, in: geo.size)
                let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
                ScrollView([.horizontal, .vertical]) {
                    Image(platformImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        #if os(macOS)
                        .onTapGesture { openInPreview() }
                        .help("Click to open in Preview")
                        #endif
                }
                #if os(iOS)
                .background(Color(white: 0.2))
                #endif
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

    #if os(macOS)
    private func openInPreview() {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}
