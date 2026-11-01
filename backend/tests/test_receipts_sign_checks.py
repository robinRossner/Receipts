"""Sign plausibility checks (a shifted price column keeps the sum right). The table is the one the
Swift ReceiptSignCheckTests run for the Mac/iOS app
(Tests/ReceiptsAppTests/ReceiptSignCheckTests.swift): keep both in step."""

from __future__ import annotations

import pytest

from receipts.extraction.validate import ExtractedItem, ExtractedReceipt, validate_receipt

POSITIVE_RETURN = "deposit return has a positive amount"
NEGATIVE_PRODUCT = "product has a negative amount"

# (name, amount, expected sign warning: None, POSITIVE_RETURN or NEGATIVE_PRODUCT)
CASES = [
    # deposit return with a positive amount: flagged
    ("Leergut", 2.99, POSITIVE_RETURN),
    ("LEERGUT", 0.5, POSITIVE_RETURN),
    ("Leergut Entl.", 3.0, POSITIVE_RETURN),
    ("Leergut Einw.", 0.25, POSITIVE_RETURN),
    ("Leergutbon", 1.5, POSITIVE_RETURN),
    ("Leergutrückgabe", 1.0, POSITIVE_RETURN),
    ("Leergutrueckgabe", 1.0, POSITIVE_RETURN),
    ("Pfandrückgabe", 0.25, POSITIVE_RETURN),
    ("PFANDRÜCKGABE", 0.25, POSITIVE_RETURN),
    ("Pfandrueckgabe", 0.25, POSITIVE_RETURN),
    ("Pfand zurück", 0.25, POSITIVE_RETURN),
    ("Pfand Rückgabe", 0.25, POSITIVE_RETURN),
    ("Rückgabe Pfand", 0.25, POSITIVE_RETURN),
    ("Pfandbon", 1.5, POSITIVE_RETURN),
    ("Pfand-Bon", 1.5, POSITIVE_RETURN),
    ("Pfanderstattung", 0.25, POSITIVE_RETURN),
    # deposit return, correct sign or zero: fine
    ("Leergut", -3.0, None),
    ("Leergut Entl.", -0.25, None),
    ("Leergutbon", -1.5, None),
    ("Pfandrückgabe", -0.25, None),
    ("Pfand zurück", -0.25, None),
    ("Pfandbon", -1.5, None),
    ("Leergut", 0.0, None),
    # deposit charges are positive on purpose
    ("Pfand", 0.25, None),
    ("Pfand 0,25", 0.25, None),
    ("Einweg Pfand", 0.25, None),
    ("Mehrweg Pfand", 0.15, None),
    ("Pfand Einw.", 0.25, None),
    ("Flaschenpfand", 0.08, None),
    ("Pfand 1,50", 1.5, None),
    ("EINWEGPFAND", 0.25, None),
    # a negative deposit line is a return whatever it is called
    ("Pfand", -0.25, None),
    ("Einweg Pfand", -0.25, None),
    # ordinary products with a positive amount
    ("Gouda jung", 3.0, None),
    ("Bio Vollmilch 1L", 1.19, None),
    ("Bonbons", 1.29, None),
    # product with a negative amount: flagged
    ("Gouda jung", -3.0, NEGATIVE_PRODUCT),
    ("Bio Vollmilch 1L", -1.19, NEGATIVE_PRODUCT),
    ("Käse Gouda", -3.0, NEGATIVE_PRODUCT),
    ("Reaktionstest", -1.0, NEGATIVE_PRODUCT),
    ("Transaktionsgebühr", -1.0, NEGATIVE_PRODUCT),
    ("Bonbons", -1.29, NEGATIVE_PRODUCT),
    ("Rabattmarken-Heft", -1.0, None),
    ("Abrabatt Käse", -1.0, None),
    ("Untreue Tee", -1.0, NEGATIVE_PRODUCT),
    ("Vorteilspack Chips", -1.0, NEGATIVE_PRODUCT),
    ("Nachlasswolle", -1.0, None),
    ("Kaffee", -0.01, NEGATIVE_PRODUCT),
    # legitimate negatives
    ("Rabatt", -0.5, None),
    ("RABATT 10%", -0.5, None),
    ("Sofortrabatt", -1.0, None),
    ("Mengenrabatt Äpfel", -0.4, None),
    ("Treuerabatt", -1.0, None),
    ("Rab. Käse", -0.3, None),
    ("Coupon", -1.0, None),
    ("Kundencoupon 2€", -2.0, None),
    ("Gutschein", -5.0, None),
    ("Gutschein 5 EUR", -5.0, None),
    ("Gutschrift", -2.0, None),
    ("Nachlass", -0.2, None),
    ("Preisnachlass", -0.2, None),
    ("Storno", -1.99, None),
    ("STORNO Brot", -1.99, None),
    ("Stornierung", -1.99, None),
    ("Aktion", -0.5, None),
    ("Aktionsrabatt", -0.5, None),
    ("Aktionspreis Vorteil", -0.5, None),
    ("Preisvorteil", -0.5, None),
    ("Sofortvorteil", -0.5, None),
    ("Bonus", -1.0, None),
    ("Treuebonus", -1.0, None),
    ("Treuepunkte", -1.0, None),
    ("Payback", -1.0, None),
    ("PAYBACK Punkte", -1.0, None),
    ("Payback-Coupon", -1.0, None),
    ("Rückgabe Joghurt", -1.0, None),
    ("Retoure Hose", -9.99, None),
    ("Korrektur", -0.5, None),
    ("Ersparnis", -0.5, None),
    # no name to judge by: only the amount's sign speaks, and a negative one is flagged
    (None, 1.0, None),
    (None, -1.0, NEGATIVE_PRODUCT),
]


def _check(name, amount):
    item = ExtractedItem(name=name, quantity=1.0, unit_price=amount, total_price=amount)
    receipt = ExtractedReceipt(items=[item], total=amount)
    return validate_receipt(receipt)


@pytest.mark.parametrize(("name", "amount", "expected"), CASES)
def test_sign_check(name, amount, expected):
    receipt = _check(name, amount)
    hits = [r for r in receipt.review_reasons if POSITIVE_RETURN in r or NEGATIVE_PRODUCT in r]
    if expected is None:
        assert hits == []
    else:
        assert len(hits) == 1 and expected in hits[0]
        assert receipt.needs_review
        assert f"({name or 'nil'})" in hits[0]


def test_sign_check_does_not_change_values():
    receipt = _check("Gouda jung", -3.0)
    assert receipt.items[0].total_price == -3.0
    assert receipt.items[0].unit_price == -3.0


def test_shifted_price_with_matching_sum_is_flagged():
    # Leergut -3.00 landed on the cheese and the cheese price on the Leergut: sum still right.
    items = [
        ExtractedItem(name="Gouda jung", quantity=1.0, unit_price=-3.0, total_price=-3.0),
        ExtractedItem(name="Leergut", quantity=1.0, unit_price=5.0, total_price=5.0),
    ]
    receipt = validate_receipt(ExtractedReceipt(items=items, total=2.0))
    assert receipt.computed_sum == 2.0
    assert receipt.needs_review
    assert len(receipt.review_reasons) == 2
