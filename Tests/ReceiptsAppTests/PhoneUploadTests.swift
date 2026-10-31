import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ReceiptsApp

/// The phone's way of adding a receipt: always the cloud path (no AI on the device), prepared photo stored in the
/// outbox before the first upload attempt, so an offline or not yet configured phone loses nothing.
@MainActor
final class PhoneUploadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A JPEG with some structure (so it compresses like a photo and is not tiny).
    private func writeJPEG(width: Int, height: Int, name: String = "photo.jpg") throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed: UInt32 = 12345
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                seed = seed &* 1664525 &+ 1013904223
                ctx.setFillColor(CGColor(red: CGFloat(seed >> 24 & 255) / 255, green: CGFloat(seed >> 16 & 255) / 255, blue: CGFloat(seed >> 8 & 255) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func pixelSize(of url: URL) -> (Int, Int) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
    }

    func testPhoneStoresAPreparedPhotoInTheOutboxEvenWithoutAServer() async throws {
        let base = dir.appendingPathComponent("data", isDirectory: true)
        let env = AppEnvironment.make(baseDir: base)
        let db = try Database(path: env.dbPath, dataDir: base)
        let store = ReceiptStore(env: env, db: db, taxonomy: Taxonomy.load(), capabilities: .mobile, deviceId: "iphone-test", reminders: NoReminders())
        let photo = try writeJPEG(width: 4000, height: 3000)

        store.upload(fileURLs: [photo], preStraightened: true)
        let end = Date().addingTimeInterval(20)
        while !(store.uploadQueue.first?.state.isFinished ?? false), Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }

        guard case .failed(let message)? = store.uploadQueue.first?.state else { return XCTFail("\(String(describing: store.uploadQueue.first?.state))") }
        XCTAssertTrue(message.contains("not set up"), message)
        let pending = try await store.sync.store.pendingUploads()
        XCTAssertEqual(pending.count, 1, "the receipt waits for its upload; the next sync sends it")
        let file = try XCTUnwrap(env.syncPaths.resolve(pending.first?.photoPath))
        let size = try XCTUnwrap(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThanOrEqual(size, PhotoPreparer.maxBytes)
        let (w, h) = pixelSize(of: file)
        XCTAssertLessThanOrEqual(max(w, h), 2500)
        XCTAssertEqual(max(w, h), 2500, "downscaled from 4000 px")
        XCTAssertEqual(PhotoPreparer.mediaType(of: try Data(contentsOf: file)), "image/jpeg")
        await store.refreshList()
        XCTAssertEqual(store.receipts.first?.processing, .waitingForUpload(nil), "\(String(describing: store.receipts.first))")
    }

    func testTheSamePhotoTwiceIsADuplicateOnThePhone() async throws {
        let base = dir.appendingPathComponent("data2", isDirectory: true)
        let env = AppEnvironment.make(baseDir: base)
        let db = try Database(path: env.dbPath, dataDir: base)
        let store = ReceiptStore(env: env, db: db, taxonomy: Taxonomy.load(), capabilities: .mobile, deviceId: "iphone-test", reminders: NoReminders())
        let photo = try writeJPEG(width: 1200, height: 900)
        store.upload(fileURLs: [photo], preStraightened: true)
        var end = Date().addingTimeInterval(20)
        while !(store.uploadQueue.first?.state.isFinished ?? false), Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        store.upload(fileURLs: [photo], preStraightened: true)
        end = Date().addingTimeInterval(20)
        while !(store.uploadQueue.count == 2 && store.uploadQueue[1].state.isFinished), Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        guard case .duplicate? = store.uploadQueue.last?.state else { return XCTFail("\(String(describing: store.uploadQueue.last?.state))") }
        let pending = try await store.sync.store.pendingUploads()
        XCTAssertEqual(pending.count, 1)
    }
}
