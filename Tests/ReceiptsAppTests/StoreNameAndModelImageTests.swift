import CoreImage
import ImageIO
import XCTest
@testable import ReceiptsApp

/// Store names as the model prints them, and the picture the model gets. The name table is the same one
/// backend/tests/test_receipts_store_names.py runs: keep both in step.
final class StoreNameTests: XCTestCase {
    static let cases: [(String?, String)] = [
        // the printed name reaches the chain whatever the branch prefix or suffix
        ("EDEKA Musterstadt", "Edeka"),
        ("Edeka", "Edeka"),
        ("EDEKA Center Nord", "Edeka"),
        ("Edeka-Markt Müller", "Edeka"),
        ("Getränke EDEKA Musterstadt", "Edeka"),
        ("REWE Markt GmbH", "Rewe"),
        ("REWE", "Rewe"),
        ("Rewe City", "Rewe"),
        ("Penny-Markt", "Penny"),
        ("PENNY-Markt GmbH", "Penny"),
        ("Penny", "Penny"),
        ("Lidl Dienstleistung GmbH & Co. KG", "Lidl"),
        ("Kaufland Filiale 1234", "Kaufland"),
        ("Rossmann Drogeriemarkt", "Rossmann"),
        ("ROSSMANN", "Rossmann"),
        ("dm", "dm"),
        ("DM", "dm"),
        ("dm-drogerie markt", "dm"),
        ("dm-drogerie markt GmbH + Co. KG", "dm"),
        ("DM Drogerie Markt Filiale 12", "dm"),
        ("ALDI SÜD", "Aldi Süd"),
        ("Aldi Sud", "Aldi Süd"),
        ("ALDI SUED", "Aldi Süd"),
        ("Aldi Süd Dienstleistungs-GmbH", "Aldi Süd"),
        ("ALDI Nord", "Aldi Nord"),
        ("ALDI-NORD", "Aldi Nord"),
        ("  Edeka\t", "Edeka"),
        ("Kaufland-Tankstelle X", "Kaufland"),
        // no chain: kept as printed (trimmed)
        ("Bäckerei Schmidt", "Bäckerei Schmidt"),
        ("ALDI", "ALDI"),
        ("Cafe Penny Lane", "Cafe Penny Lane"),
        ("Edekabank", "Edekabank"),
        ("Rewerk GmbH", "Rewerk GmbH"),
        ("Lidlington", "Lidlington"),
        ("Rossmannshof", "Rossmannshof"),
        ("Dmitri's Kiosk", "Dmitri's Kiosk"),
        ("Bäckerei DM Müller", "Bäckerei DM Müller"),
        ("Pennywise", "Pennywise"),
        ("Aldi Nordsee Imbiss", "Aldi Nordsee Imbiss"),
        // empty
        (nil, "Unknown"),
        ("", "Unknown"),
        ("   ", "Unknown"),
    ]

    func testCanonicalizeStore() {
        for (raw, expected) in Self.cases {
            XCTAssertEqual(ReceiptPipeline.canonicalizeStore(raw), expected, "input: \(raw ?? "nil")")
        }
    }

    func testSuggestionListIsTheCanonicalSet() {
        XCTAssertEqual(ReceiptPipeline.canonicalStoreNames,
                       ["Aldi Nord", "Aldi Süd", "Edeka", "Kaufland", "Lidl", "Penny", "Rewe", "Rossmann", "dm"])
    }
}

final class ModelImageTests: XCTestCase {
    private func noisyImage(width: Int, height: Int) -> CIImage {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = UInt8.random(in: 0...255, using: &generator); bytes[i + 1] = UInt8.random(in: 0...255, using: &generator)
            bytes[i + 2] = UInt8.random(in: 0...255, using: &generator); bytes[i + 3] = 255
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func pixelSize(_ data: Data) throws -> (Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int), try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int))
    }

    func testTallReceiptIsSentWithA1568LongEdge() throws {
        XCTAssertEqual(DocumentScanner.modelMaxDimension, 1568)
        let data = try XCTUnwrap(DocumentScanner.modelJPEG(from: noisyImage(width: 800, height: 3200)))
        let (w, h) = try pixelSize(data)
        XCTAssertEqual(h, 1568)
        XCTAssertEqual(w, 392, accuracy: 1)  // 241 px wide at the old 1024 cap, now 392
    }

    func testSmallPictureIsNotEnlarged() throws {
        let data = try XCTUnwrap(DocumentScanner.modelJPEG(from: noisyImage(width: 500, height: 900)))
        let (w, h) = try pixelSize(data)
        XCTAssertEqual(w, 500)
        XCTAssertEqual(h, 900)
    }

    func testWorstCaseNoiseStaysUnderTheApiLimit() throws {
        let data = try XCTUnwrap(DocumentScanner.modelJPEG(from: noisyImage(width: 1568, height: 1568)))
        XCTAssertLessThan(data.count, 5 * 1024 * 1024)
        XCTAssertLessThanOrEqual(data.count, DocumentScanner.modelMaxBytes)
    }

    func testQualityStepsDownWhenOverTheByteCeiling() throws {
        let image = noisyImage(width: 1000, height: 1000)
        let best = try XCTUnwrap(DocumentScanner.jpegData(from: image, maxDimension: 1568, quality: 0.95))
        let capped = try XCTUnwrap(DocumentScanner.modelJPEG(from: image, maxBytes: best.count / 2))
        XCTAssertLessThan(capped.count, best.count)
    }
}
