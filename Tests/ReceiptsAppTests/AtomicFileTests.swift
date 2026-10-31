import XCTest
@testable import ReceiptsApp

final class AtomicFileTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDownWithError() throws {
        // make sure read-only folders can be removed
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func names(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

    func testWritesTheCompleteFileAndLeavesNoTempFile() throws {
        let target = dir.appendingPathComponent("2026/03/a.jpg")   // intermediate folders are created
        let data = fakePhoto(3, size: 200_000)
        try AtomicFile.write(data, to: target)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertEqual(names(target.deletingLastPathComponent()), ["a.jpg"])
    }

    func testReplacesAnExistingFileInOneStep() throws {
        let target = dir.appendingPathComponent("a.jpg")
        try AtomicFile.write(Data("old".utf8), to: target)
        try AtomicFile.write(Data("new".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertEqual(names(dir), ["a.jpg"])
    }

    func testFailureLeavesTheOldFileAndNoTempFile() throws {
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let target = locked.appendingPathComponent("a.jpg")
        try AtomicFile.write(Data("old".utf8), to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        XCTAssertThrowsError(try AtomicFile.write(Data("new".utf8), to: target)) { error in
            XCTAssertTrue(error is AtomicFile.WriteError, "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
        XCTAssertEqual(names(locked), ["a.jpg"], "no temp file left behind")
    }

    func testTargetThatIsADirectoryFailsCleanly() throws {
        let target = dir.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AtomicFile.write(Data("x".utf8), to: target))
        XCTAssertEqual(names(dir), ["taken"])
    }

    func testDiskFullErrorIsRecognised() {
        XCTAssertTrue(AtomicFile.WriteError(operation: "write", path: "/x", errnoValue: ENOSPC).isDiskFull)
        XCTAssertFalse(AtomicFile.WriteError(operation: "write", path: "/x", errnoValue: EACCES).isDiskFull)
    }
}
