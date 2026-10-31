import CoreImage
import Foundation

/// Turns a picked photo into what the server takes: straightened with the existing `DocumentScanner`, JPEG, at most
/// about 2500 px on the long edge and under 5 MB (the Messages API rejects bigger images; the server stores them but
/// the extraction then fails).
enum PhotoPreparer {
    static let maxDimension: CGFloat = 2500
    /// Under the API's 5 MB (5 * 1024 * 1024) with room for the base64-free overhead of the request.
    static let maxBytes = 4_500_000
    /// Tried in turn at the full size, then the size shrinks by `shrink` and the qualities start again.
    static let qualities: [CGFloat] = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4]
    static let shrink: CGFloat = 0.8
    static let minDimension: CGFloat = 800

    enum PrepareError: Error, LocalizedError {
        case cannotEncode
        case tooLarge
        var errorDescription: String? {
            switch self {
            case .cannotEncode: return "Could not convert the photo to JPEG."
            case .tooLarge: return "The photo is too large even after compressing it."
            }
        }
    }

    /// Scan (find the receipt, perspective-correct) and encode.
    static func prepare(imagePath: String) throws -> Data {
        try encode(try DocumentScanner.scan(imagePath: imagePath))
    }

    /// JPEG of at most `maxBytes` and `maxDimension`: lower the quality first, then the size.
    static func encode(_ image: CIImage, maxBytes: Int = maxBytes) throws -> Data {
        var dimension = maxDimension
        while dimension >= minDimension {
            for quality in qualities {
                guard let data = DocumentScanner.jpegData(from: image, maxDimension: dimension, quality: quality) else {
                    throw PrepareError.cannotEncode
                }
                if data.count <= maxBytes { return data }
            }
            dimension *= shrink
        }
        throw PrepareError.tooLarge
    }

    static func mediaType(of data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}
