import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import Foundation

enum ScanError: Error, LocalizedError {
    case cannotLoadImage
    case noDocumentFound

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage:
            return "Could not read this image file."
        case .noDocumentFound:
            return "Could not find a receipt in this photo. Try a clearer, flatter photo."
        }
    }
}

/// Finds and straightens the receipt in a photo. Replaces scan_and_parse_receipt.py's
/// scan_document() (DocAligner + OpenCV) with Vision's built-in document-segmentation model
/// and Core Image's perspective-correction filter - both native to macOS, no extra
/// dependencies. `ImageIO` also reads HEIC out of the box, unlike the Python side which
/// installed `pillow_heif` but never called `register_heif_opener()` (why the .heic files in
/// uploads_incoming got stuck).
enum DocumentScanner {
    static func scan(imagePath: String) throws -> CIImage {
        let url = URL(fileURLWithPath: imagePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError.cannotLoadImage
        }

        // Bake the EXIF orientation into the pixel buffer, same intent as
        // ImageOps.exif_transpose() in the Python version's load_image_upright().
        let orientation = imageOrientation(from: source)
        let uprightImage = CIImage(cgImage: cgImage).oriented(orientation)

        let corners = try detectDocumentCorners(in: uprightImage)
        return warp(uprightImage, to: corners)
    }

    private static func imageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else {
            return .up
        }
        return orientation
    }

    /// Vision's VNRectangleObservation already returns semantically-labeled corners
    /// (topLeft/topRight/etc.), so no manual corner-sorting is needed here - unlike
    /// order_points() in the Python version, which had to sort DocAligner's unordered points.
    private static func detectDocumentCorners(in image: CIImage) throws -> (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first as? VNRectangleObservation else {
            throw ScanError.noDocumentFound
        }

        let extent = image.extent
        func toPixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.origin.x + p.x * extent.width, y: extent.origin.y + p.y * extent.height)
        }
        return (toPixel(result.topLeft), toPixel(result.topRight), toPixel(result.bottomRight), toPixel(result.bottomLeft))
    }

    private static func warp(_ image: CIImage, to corners: (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint)) -> CIImage {
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = corners.topLeft
        filter.topRight = corners.topRight
        filter.bottomRight = corners.bottomRight
        filter.bottomLeft = corners.bottomLeft
        return filter.outputImage ?? image
    }

    private static let sharedContext = CIContext()

    /// Downscales to a max dimension and JPEG-encodes - mirrors call_ollama()'s resize-then-
    /// encode step in scan_and_parse_receipt.py (same 1024px cap, same 95% quality).
    static func jpegData(from image: CIImage, maxDimension: CGFloat = 1024, quality: CGFloat = 0.95) -> Data? {
        var working = image
        let extent = working.extent
        let largestSide = max(extent.width, extent.height)
        if largestSide > maxDimension {
            let scale = maxDimension / largestSide
            working = working.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let colorSpace = working.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return sharedContext.jpegRepresentation(
            of: working,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
