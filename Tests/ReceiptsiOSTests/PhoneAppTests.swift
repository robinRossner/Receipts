import XCTest
@testable import ReceiptsApp

final class PhoneAppTests: XCTestCase {
    func testDeviceIDIsMadeUpOnceAndKept() {
        let suite = "receipts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DeviceID.current(defaults: defaults)
        XCTAssertTrue(first.hasPrefix("iphone-"))
        XCTAssertEqual(first.count, "iphone-".count + 8)
        XCTAssertEqual(DeviceID.current(defaults: defaults), first)
        XCTAssertNotEqual(first, "macbook-archive", "the phone must never pose as the archive device")
    }

    func testAppTransportSecurityHasNoBlanketExceptions() throws {
        let ats = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertNil(ats?["NSAllowsArbitraryLoads"])
        XCTAssertNil(ats?["NSAllowsLocalNetworking"])
        // Debug builds may allow plain HTTP to localhost only; Release has no exception at all (checked by the build script).
        if let domains = ats?["NSExceptionDomains"] as? [String: Any] { XCTAssertEqual(Array(domains.keys), ["localhost"]) }
    }

    func testThePhoneAppUsesTheMobileCapabilities() {
        XCTAssertFalse(SyncCapabilities.mobile.archivesPhotos)
        XCTAssertTrue(SyncCapabilities.mobile.cachesPhotos)
        XCTAssertLessThanOrEqual(SyncCapabilities.mobile.photoCacheBytes, 500 * 1_000_000)
    }

    func testTheShippedSettingsCannotPointAtPlainHTTPOutsideDebugLocalhost() {
        XCTAssertEqual(ServerURL.defaultPolicy, .debugLoopbackOnly)
        XCTAssertNil(ServerURL.apiBase(from: "http://example.com"))
        XCTAssertNil(ServerURL.apiBase(from: "http://192.168.0.5:8000"))
        XCTAssertNotNil(ServerURL.apiBase(from: "https://example.com"))
    }
}
