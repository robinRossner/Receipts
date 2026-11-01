import XCTest
@testable import ReceiptsApp

/// Sign plausibility checks (a shifted price column keeps the sum right). The table is the same one
/// backend/tests/test_receipts_sign_checks.py runs: keep both in step.
final class ReceiptSignCheckTests: XCTestCase {
    static let positiveReturn = "deposit return has a positive amount"
    static let negativeProduct = "product has a negative amount"

    // (name, amount, expected sign warning)
    static let cases: [(String?, Double, String?)] = [
        ("Leergut", 2.99, ReceiptSignCheckTests.positiveReturn),
        ("LEERGUT", 0.5, ReceiptSignCheckTests.positiveReturn),
        ("Leergut Entl.", 3.0, ReceiptSignCheckTests.positiveReturn),
        ("Leergut Einw.", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("Leergutbon", 1.5, ReceiptSignCheckTests.positiveReturn),
        ("Leergutrückgabe", 1.0, ReceiptSignCheckTests.positiveReturn),
        ("Leergutrueckgabe", 1.0, ReceiptSignCheckTests.positiveReturn),
        ("Pfandrückgabe", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("PFANDRÜCKGABE", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("Pfandrueckgabe", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("Pfand zurück", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("Pfand Rückgabe", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("Rückgabe Pfand", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("Pfandbon", 1.5, ReceiptSignCheckTests.positiveReturn),
        ("Pfand-Bon", 1.5, ReceiptSignCheckTests.positiveReturn),
        ("Pfanderstattung", 0.25, ReceiptSignCheckTests.positiveReturn),
        ("Leergut", -3.0, nil),
        ("Leergut Entl.", -0.25, nil),
        ("Leergutbon", -1.5, nil),
        ("Pfandrückgabe", -0.25, nil),
        ("Pfand zurück", -0.25, nil),
        ("Pfandbon", -1.5, nil),
        ("Leergut", 0.0, nil),
        ("Pfand", 0.25, nil),
        ("Pfand 0,25", 0.25, nil),
        ("Einweg Pfand", 0.25, nil),
        ("Mehrweg Pfand", 0.15, nil),
        ("Pfand Einw.", 0.25, nil),
        ("Flaschenpfand", 0.08, nil),
        ("Pfand 1,50", 1.5, nil),
        ("EINWEGPFAND", 0.25, nil),
        ("Pfand", -0.25, nil),
        ("Einweg Pfand", -0.25, nil),
        ("Gouda jung", 3.0, nil),
        ("Bio Vollmilch 1L", 1.19, nil),
        ("Bonbons", 1.29, nil),
        ("Gouda jung", -3.0, ReceiptSignCheckTests.negativeProduct),
        ("Bio Vollmilch 1L", -1.19, ReceiptSignCheckTests.negativeProduct),
        ("Käse Gouda", -3.0, ReceiptSignCheckTests.negativeProduct),
        ("Reaktionstest", -1.0, ReceiptSignCheckTests.negativeProduct),
        ("Transaktionsgebühr", -1.0, ReceiptSignCheckTests.negativeProduct),
        ("Bonbons", -1.29, ReceiptSignCheckTests.negativeProduct),
        ("Rabattmarken-Heft", -1.0, nil),
        ("Abrabatt Käse", -1.0, nil),
        ("Untreue Tee", -1.0, ReceiptSignCheckTests.negativeProduct),
        ("Vorteilspack Chips", -1.0, ReceiptSignCheckTests.negativeProduct),
        ("Nachlasswolle", -1.0, nil),
        ("Kaffee", -0.01, ReceiptSignCheckTests.negativeProduct),
        ("Rabatt", -0.5, nil),
        ("RABATT 10%", -0.5, nil),
        ("Sofortrabatt", -1.0, nil),
        ("Mengenrabatt Äpfel", -0.4, nil),
        ("Treuerabatt", -1.0, nil),
        ("Rab. Käse", -0.3, nil),
        ("Coupon", -1.0, nil),
        ("Kundencoupon 2€", -2.0, nil),
        ("Gutschein", -5.0, nil),
        ("Gutschein 5 EUR", -5.0, nil),
        ("Gutschrift", -2.0, nil),
        ("Nachlass", -0.2, nil),
        ("Preisnachlass", -0.2, nil),
        ("Storno", -1.99, nil),
        ("STORNO Brot", -1.99, nil),
        ("Stornierung", -1.99, nil),
        ("Aktion", -0.5, nil),
        ("Aktionsrabatt", -0.5, nil),
        ("Aktionspreis Vorteil", -0.5, nil),
        ("Preisvorteil", -0.5, nil),
        ("Sofortvorteil", -0.5, nil),
        ("Bonus", -1.0, nil),
        ("Treuebonus", -1.0, nil),
        ("Treuepunkte", -1.0, nil),
        ("Payback", -1.0, nil),
        ("PAYBACK Punkte", -1.0, nil),
        ("Payback-Coupon", -1.0, nil),
        ("Rückgabe Joghurt", -1.0, nil),
        ("Retoure Hose", -9.99, nil),
        ("Korrektur", -0.5, nil),
        ("Ersparnis", -0.5, nil),
        (nil, 1.0, nil),
        (nil, -1.0, ReceiptSignCheckTests.negativeProduct),
    ]

    private func validated(_ items: [(String?, Double)], total: Double) -> ExtractedReceipt {
        var dicts: [[String: Any]] = []
        for (name, amount) in items {
            var d: [String: Any] = ["quantity": 1.0, "unit_price": amount, "total_price": amount]
            if let name { d["name"] = name }
            dicts.append(d)
        }
        return ReceiptExtractor.validateReceipt(ExtractedReceipt(dict: ["items": dicts, "total": total]))
    }

    func testSignCheck() {
        for (name, amount, expected) in Self.cases {
            let receipt = validated([(name, amount)], total: amount)
            let hits = receipt.reviewReasons.filter { $0.contains(Self.positiveReturn) || $0.contains(Self.negativeProduct) }
            if let expected {
                XCTAssertEqual(hits.count, 1, "\(name ?? "nil") \(amount)")
                XCTAssertTrue(hits.first?.contains(expected) ?? false, "\(name ?? "nil") \(amount)")
                XCTAssertTrue(receipt.needsReview)
                XCTAssertTrue(hits.first?.contains("(\(name ?? "nil"))") ?? false)
            } else {
                XCTAssertTrue(hits.isEmpty, "\(name ?? "nil") \(amount): \(hits)")
            }
        }
    }

    func testSignCheckDoesNotChangeValues() {
        let receipt = validated([("Gouda jung", -3.0)], total: -3.0)
        XCTAssertEqual(receipt.items[0].totalPrice, -3.0)
        XCTAssertEqual(receipt.items[0].unitPrice, -3.0)
    }

    func testShiftedPriceWithMatchingSumIsFlagged() {
        let receipt = validated([("Gouda jung", -3.0), ("Leergut", 5.0)], total: 2.0)
        XCTAssertEqual(receipt.computedSum, 2.0)
        XCTAssertTrue(receipt.needsReview)
        XCTAssertEqual(receipt.reviewReasons.count, 2)
    }
}
