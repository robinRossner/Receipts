"""Store name canonicalisation. The table is the one the Swift StoreNameTests run for the Mac/iOS
app (Tests/ReceiptsAppTests/StoreNameAndModelImageTests.swift): keep both in step."""

from __future__ import annotations

import pytest

from receipts.extraction.pipeline import CANONICAL_STORE_NAMES, canonicalize_store

CASES = [
    # the printed name reaches the chain whatever the branch prefix or suffix
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
    # no chain: kept as printed (trimmed)
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
    # empty
    (None, "Unknown"),
    ("", "Unknown"),
    ("   ", "Unknown"),
]


@pytest.mark.parametrize(("raw", "expected"), CASES)
def test_canonicalize_store(raw, expected):
    assert canonicalize_store(raw) == expected


def test_canonical_names():
    assert CANONICAL_STORE_NAMES == [
        "Aldi Nord",
        "Aldi Süd",
        "Edeka",
        "Kaufland",
        "Lidl",
        "Penny",
        "Rewe",
        "Rossmann",
        "dm",
    ]
