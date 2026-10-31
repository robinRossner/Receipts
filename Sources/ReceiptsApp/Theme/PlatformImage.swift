import ImageIO
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// Wraps a decoded image (orientation already applied by ImageIO) for display on either platform.
    static func make(cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        UIImage(cgImage: cgImage)
        #endif
    }

    /// Pixel size in points (macOS: the NSImage size, iOS: the UIImage size).
    var pixelSize: CGSize { size }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

enum ImageDecoding {
    /// Decodes a file downsampled to `maxPixel` on the long edge, honouring EXIF orientation. nil when it is not an image.
    static func thumbnail(at url: URL, maxPixel: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PlatformImage.make(cgImage: cg)
    }
}
