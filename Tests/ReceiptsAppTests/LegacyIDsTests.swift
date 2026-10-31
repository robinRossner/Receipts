import XCTest
@testable import ReceiptsApp

/// The UUIDs of existing Mac rows must equal what backend/apps/receipts/migrate_mac_data.py `uid()` makes of
/// them; otherwise the first sync duplicates every receipt. The expected values below were produced by that
/// Python function (`uv run python -c "from apps.receipts.migrate_mac_data import uid; ..."`).
final class LegacyIDsTests: XCTestCase {
    func testNamespaceMatchesMigrationScript() {
        XCTAssertEqual(LegacyIDs.namespace.uuidString.lowercased(), "0b8f3c52-6d1e-4c7a-9a4e-2f5d8e1b7c63")
    }

    func testUUIDsEqualPythonMigration() {
        let expected: [(LegacyIDs.Kind, Int, String)] = [
            (.dictionary, 1, "faa833c6-b6af-5a33-85f8-58b8eeeb25e8"),
            (.dictionary, 2, "daf7da63-f4cc-5607-a6a9-f97ecdebfcaf"),
            (.dictionary, 17, "7ec30a56-bd2f-559d-9137-7e297d0d4b3f"),
            (.dictionary, 4096, "7eb6cdec-6902-5f27-a323-b0b9d6224ce1"),
            (.dictionary, 123456, "468737aa-09ad-5d37-b354-54462baf71f7"),
            (.receipt, 1, "f79084c1-899d-5a3c-b750-a23294f970b0"),
            (.receipt, 2, "35095198-28af-59ca-b4e5-c159277b01bb"),
            (.receipt, 17, "2bd43331-cbf9-552b-969a-2309a561fac7"),
            (.receipt, 4096, "14e69773-0b31-5b86-b9a1-d6e7f4f72ef7"),
            (.receipt, 123456, "cc3699a4-1d5a-5e2d-a925-39a91992229e"),
            (.lineItem, 1, "dc9fa7b1-8e34-53c8-94ae-dc2499b95289"),
            (.lineItem, 2, "61851607-e5fa-549f-a940-d78e6d2b15f2"),
            (.lineItem, 17, "d40e2326-0948-5897-b966-40e68270d201"),
            (.lineItem, 4096, "572c352c-5544-5c00-92ae-c19e1194f488"),
            (.lineItem, 123456, "d2d8f554-05b2-5a21-8aa9-8cb53c6a3e3b"),
        ]
        for (kind, id, uuid) in expected {
            XCTAssertEqual(LegacyIDs.uuid(kind, id), uuid, "\(kind) \(id)")
        }
    }

    func testIdsOfDifferentKindsDiffer() {
        XCTAssertNotEqual(LegacyIDs.uuid(.receipt, 1), LegacyIDs.uuid(.lineItem, 1))
        XCTAssertNotEqual(LegacyIDs.uuid(.receipt, 1), LegacyIDs.uuid(.dictionary, 1))
    }
}
