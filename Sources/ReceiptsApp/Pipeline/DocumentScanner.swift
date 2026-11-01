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
    /// - `minConfidence`: an outline Vision itself is not sure about counts as "no document" (the iOS simulator's Vision
    ///   answers with a made-up full-frame rectangle of confidence 0; real devices report a real confidence).
    static func scan(imagePath: String, minConfidence: Float = 0) throws -> CIImage {
        let uprightImage = try load(imagePath: imagePath)
        let corners = try detectDocumentCorners(in: uprightImage, minConfidence: minConfidence)
        return warp(uprightImage, to: corners)
    }

    /// The image with its EXIF orientation baked in (no document search): for photos that are already straight
    /// (the phone's document camera) and as a fallback when no document is found.
    static func load(imagePath: String) throws -> CIImage {
        let url = URL(fileURLWithPath: imagePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError.cannotLoadImage
        }

        // Bake the EXIF orientation into the pixel buffer, same intent as
        // ImageOps.exif_transpose() in the Python version's load_image_upright().
        let orientation = imageOrientation(from: source)
        return CIImage(cgImage: cgImage).oriented(orientation)
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
    private static func detectDocumentCorners(in image: CIImage, minConfidence: Float) throws -> (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first as? VNRectangleObservation, result.confidence >= minConfidence else {
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

    /// Long edge of the picture sent to the vision model. 1024 px squeezed a tall receipt to about 241x1024 and the
    /// model misread it; at 1568 px (the size the Claude API itself works at) the same receipt read 18/18 exact.
    static let modelMaxDimension: CGFloat = 1568
    /// JPEG qualities tried in turn for the model picture, and the byte ceiling (the API rejects images over 5 MB).
    static let modelQualities: [CGFloat] = [0.95, 0.85, 0.7, 0.5]
    static let modelMaxBytes = 4_500_000

    /// The JPEG the vision model gets: long edge `modelMaxDimension`, best quality that stays under `modelMaxBytes`.
    /// Only what is sent is shrunk; the stored photo is untouched.
    static func modelJPEG(from image: CIImage, maxBytes: Int = modelMaxBytes) -> Data? {
        var last: Data?
        for quality in modelQualities {
            guard let data = jpegData(from: image, maxDimension: modelMaxDimension, quality: quality) else { return nil }
            if data.count <= maxBytes { return data }
            last = data
        }
        return last
    }

    /// Downscales to a max dimension (default `modelMaxDimension`) and JPEG-encodes it, 95% quality by default.
    static func jpegData(from image: CIImage, maxDimension: CGFloat = modelMaxDimension, quality: CGFloat = 0.95) -> Data? {
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
