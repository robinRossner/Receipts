"""`python -m receipts.migrate_mac_data`: dry run vs apply, stable UUIDs, idempotency, photos
marked archived and not uploaded. Synthetic fixture only (the Mac schema, a few made-up rows)."""

from __future__ import annotations

import hashlib
import sqlite3
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest
from sqlalchemy import func, select
from typer.testing import CliRunner

from receipts import migrate_mac_data as mig
from receipts.db.models import ItemDictionary, LineItem, Receipt
from receipts.settings import get_settings
from tests.receipts_helpers import AUTH, BASE, make_jpeg

MAC_SCHEMA = """
CREATE TABLE item_dictionary (
    id INTEGER PRIMARY KEY AUTOINCREMENT, canonical_name TEXT UNIQUE NOT NULL, display_name_de TEXT,
    translation_en TEXT, category TEXT, subcategory TEXT, item_group TEXT, aliases TEXT,
    is_manual_override INTEGER DEFAULT 0, needs_review INTEGER DEFAULT 0,
    times_seen INTEGER DEFAULT 1, created_at TEXT, last_seen_at TEXT);
CREATE TABLE receipts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, store TEXT, date TEXT, time TEXT, total REAL,
    computed_sum REAL, needs_review INTEGER DEFAULT 0, review_reasons TEXT, source_image TEXT,
    created_at TEXT, reviewed_at TEXT, image_hash TEXT, deleted_at TEXT);
CREATE TABLE line_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT, receipt_id INTEGER NOT NULL REFERENCES receipts(id),
    item_dictionary_id INTEGER NOT NULL REFERENCES item_dictionary(id), raw_text TEXT, name_de TEXT,
    quantity REAL, unit_price REAL, total_price REAL, price_normalized INTEGER DEFAULT 0);
"""


@pytest.fixture
def mac(tmp_path: Path):
    """A fake Mac data folder: receipts.db + receipts_archive/ with two photos."""
    root = tmp_path / "mac"
    archive = root / "receipts_archive"
    (archive / "2026" / "03").mkdir(parents=True)
    photo1, photo2 = make_jpeg(101), make_jpeg(102)
    (archive / "2026" / "03" / "2026-03-01_edeka_1.jpg").write_bytes(photo1)
    (archive / "2026" / "03" / "2026-03-05_rewe_2.jpg").write_bytes(photo2)
    outside = tmp_path / "elsewhere.jpg"
    outside.write_bytes(make_jpeg(103))
    db = sqlite3.connect(root / "receipts.db")
    db.executescript(MAC_SCHEMA)
    db.executemany(
        "INSERT INTO item_dictionary (canonical_name, display_name_de, translation_en, category,"
        " subcategory, item_group, aliases, is_manual_override, needs_review, times_seen,"
        " created_at, last_seen_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        [
            (
                "milch",
                "Milch",
                "milk",
                "Food",
                "Dairy & Eggs",
                "Milk",
                '["vollmilch"]',
                1,
                0,
                5,
                "2026-03-01T10:00:00Z",
                "2026-03-05T10:00:00Z",
            ),
            (
                "pfand",
                "Pfand",
                "deposit",
                "Other",
                "Deposits & Refunds",
                "Pfand",
                "[]",
                0,
                1,
                2,
                "2026-03-01T10:00:00Z",
                "2026-03-05T10:00:00Z",
            ),
        ],
    )
    db.executemany(
        "INSERT INTO receipts (store, date, time, total, computed_sum, needs_review,"
        " review_reasons, source_image, created_at, reviewed_at, image_hash, deleted_at)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        [
            (
                "Edeka",
                "2026-03-01",
                "09:12",
                1.44,
                1.44,
                0,
                "[]",
                "receipts_archive/2026/03/2026-03-01_edeka_1.jpg",
                "2026-03-01T10:00:00Z",
                "2026-03-02T08:00:00Z",
                hashlib.sha256(photo1).hexdigest(),
                None,
            ),
            (
                "Rewe",
                "2026-03-05",
                None,
                3.0,
                2.5,
                1,
                '["Item prices sum to 2.5"]',
                "receipts_archive/2026/03/2026-03-05_rewe_2.jpg",
                "2026-03-05T10:00:00Z",
                None,
                None,
                None,
            ),
            (
                "Lidl",
                "2026-03-06",
                "18:00",
                5.0,
                5.0,
                0,
                "[]",
                "receipts_archive/2026/03/missing.jpg",
                "2026-03-06T10:00:00Z",
                None,
                None,
                None,
            ),
            (
                "Aldi",
                "2026-03-07",
                None,
                1.0,
                1.0,
                0,
                "[]",
                str(outside),
                "2026-03-07T10:00:00Z",
                None,
                None,
                "2026-03-08T10:00:00Z",
            ),
        ],
    )
    db.executemany(
        "INSERT INTO line_items (receipt_id, item_dictionary_id, raw_text, name_de, quantity,"
        " unit_price, total_price, price_normalized) VALUES (?,?,?,?,?,?,?,?)",
        [
            (1, 1, "MILCH 1,19", "Milch", 1, 1.19, 1.19, 0),
            (1, 2, "PFAND 0,25", "Pfand", 1, 0.25, 0.25, 1),
            (2, 1, "MILCH", "Milch", 2, 1.25, 2.5, 0),
            (3, 99, "ORPHAN", "Orphan", 1, 1.0, 1.0, 0),  # dictionary entry does not exist
        ],
    )
    db.commit()
    db.close()
    return SimpleNamespace(db=root / "receipts.db", archive=archive, photo1=photo1, outside=outside)


def url() -> str:
    return get_settings().receipts_database_url


def counts(db) -> tuple[int, int, int]:
    return tuple(
        db.scalar(select(func.count()).select_from(m)) for m in (ItemDictionary, Receipt, LineItem)
    )


# --------------------------------------------------------------------------- dry run


def test_dry_run_reports_and_writes_nothing_without_a_database(mac):
    report = mig.run_migration(mac.db, mac.archive, url(), apply=False)
    assert (report.dictionary_new, report.receipts_new, report.line_items_new) == (2, 4, 3)
    assert report.apply is False and "DRY RUN" in report.lines()[0]
    assert not Path(url().removeprefix("sqlite:///")).exists()  # not even the database file


def test_dry_run_against_a_migrated_database_changes_nothing(mac, rfactory, rdb):
    mig.run_migration(mac.db, mac.archive, url(), apply=True)
    before = counts(rdb)
    report = mig.run_migration(mac.db, mac.archive, url(), apply=False)
    assert (report.receipts_new, report.receipts_existing) == (0, 4)
    assert counts(rdb) == before


def test_dry_run_is_the_default_of_the_cli(mac, rfactory, rdb):
    result = CliRunner().invoke(mig.cli, ["--db", str(mac.db), "--archive", str(mac.archive)])
    assert result.exit_code == 0, result.output
    assert "DRY RUN" in result.output and "4 new" in result.output
    assert counts(rdb) == (0, 0, 0)
    applied = CliRunner().invoke(
        mig.cli, ["--db", str(mac.db), "--archive", str(mac.archive), "--apply"]
    )
    assert applied.exit_code == 0 and "APPLIED" in applied.output
    rdb.expire_all()
    assert counts(rdb) == (2, 4, 3)


# --------------------------------------------------------------------------- apply


def test_apply_imports_everything_with_stable_uuids(mac, rfactory, rdb):
    report = mig.run_migration(mac.db, mac.archive, url(), apply=True)
    assert counts(rdb) == (2, 4, 3)
    assert [s for s in report.skipped] == [
        "line item #4: its receipt or dictionary entry is missing"
    ]

    r1 = rdb.get(Receipt, mig.uid("receipt", 1))
    assert r1.legacy_id == 1 and (r1.store, r1.date, r1.time, r1.total) == (
        "Edeka",
        "2026-03-01",
        "09:12",
        1.44,
    )
    assert r1.reviewed_at is not None and r1.needs_review is False
    assert (r1.extraction_status, r1.extraction_provider) == ("done", "mac-app")
    r2 = rdb.get(Receipt, mig.uid("receipt", 2))
    assert r2.needs_review is True and r2.review_reasons == ["Item prices sum to 2.5"]
    assert r2.reviewed_at is None

    items = rdb.scalars(
        select(LineItem).where(LineItem.receipt_id == r1.id).order_by(LineItem.position)
    ).all()
    assert [(i.name_de, i.position, i.price_normalized) for i in items] == [
        ("Milch", 0, False),
        ("Pfand", 1, True),
    ]
    assert items[0].item_dictionary_id == mig.uid("dictionary", 1)
    milch = rdb.get(ItemDictionary, mig.uid("dictionary", 1))
    assert (milch.aliases, milch.is_manual_override, milch.times_seen) == (["vollmilch"], True, 5)
    assert rdb.get(ItemDictionary, mig.uid("dictionary", 2)).needs_review is True

    # the ids are a pure function of the Mac ids (so a second Mac export lands on the same rows)
    namespace = uuid.UUID("0b8f3c52-6d1e-4c7a-9a4e-2f5d8e1b7c63")
    assert r1.id == str(uuid.uuid5(namespace, "mac:receipt:1"))
    assert len({mig.uid("receipt", 1), mig.uid("line_item", 1), mig.uid("dictionary", 1)}) == 3


def test_photos_held_by_the_mac_are_marked_archived_and_not_uploaded(
    mac, rfactory, rdb, photos_dir
):
    report = mig.run_migration(mac.db, mac.archive, url(), apply=True)
    r1 = rdb.get(Receipt, mig.uid("receipt", 1))
    assert r1.photo_location == "archived" and r1.archived_by == "mac-migration"
    assert r1.photo_sha256 == hashlib.sha256(mac.photo1).hexdigest()
    assert (r1.photo_bytes, r1.photo_media_type, r1.photo_path) == (
        len(mac.photo1),
        "image/jpeg",
        None,
    )
    assert report.photos_archived == 2
    assert not photos_dir.exists() or not list(photos_dir.rglob("*.*"))  # nothing was copied
    # a receipt whose file is not in --archive has no photo (and is reported), as does one that
    # points outside it: the script reads only the two paths it was given
    missing = rdb.get(Receipt, mig.uid("receipt", 3))
    outside = rdb.get(Receipt, mig.uid("receipt", 4))
    assert missing.photo_location == outside.photo_location == "none"
    assert len(report.photos_missing) == 2
    assert outside.deleted_at is not None  # soft-deleted on the Mac: a tombstone here


def test_migrated_receipts_sync_and_cannot_get_their_photo_back(mac, rclient):
    mig.run_migration(mac.db, mac.archive, url(), apply=True)
    page = rclient.get(f"{BASE}/sync/pull").json()
    assert (
        len(page["receipts"]) == 4 and len(page["dictionary"]) == 2 and len(page["line_items"]) == 3
    )
    first = next(r for r in page["receipts"] if r["legacy_id"] == 1)
    assert first["photo_location"] == "archived" and first["extraction_status"] == "done"
    assert rclient.get(f"{BASE}/archive/pending").json()["count"] == 0
    again = rclient.put(
        f"{BASE}/{first['id']}/photo", content=mac.photo1, headers={"Content-Type": "image/jpeg"}
    )
    assert again.status_code == 200 and again.json()["receipt"]["photo_location"] == "archived"
    assert rclient.get(f"{BASE}/{first['id']}/photo", headers=AUTH).status_code == 410


# --------------------------------------------------------------------------- idempotent


def test_apply_twice_adds_nothing(mac, rfactory, rdb):
    first = mig.run_migration(mac.db, mac.archive, url(), apply=True)
    second = mig.run_migration(mac.db, mac.archive, url(), apply=True)
    assert (first.receipts_new, second.receipts_new) == (4, 0)
    assert (second.receipts_existing, second.line_items_existing, second.dictionary_existing) == (
        4,
        3,
        2,
    )
    assert second.photos_archived == 0
    rdb.expire_all()
    assert counts(rdb) == (2, 4, 3)


def test_a_rerun_never_overwrites_later_edits(mac, rfactory, rdb, rclient):
    mig.run_migration(mac.db, mac.archive, url(), apply=True)
    rid = mig.uid("receipt", 1)
    pushed = rclient.post(
        f"{BASE}/sync/push",
        json={
            "device_id": "phone",
            "receipts": [
                {
                    "id": rid,
                    "store": "Edited On Phone",
                    "date": "2026-03-01",
                    "updated_at": "2099-01-01T00:00:00Z",
                }
            ],
        },
    )
    assert pushed.json()["results"][0]["status"] == "applied"
    mig.run_migration(mac.db, mac.archive, url(), apply=True)
    rdb.expire_all()
    assert rdb.get(Receipt, rid).store == "Edited On Phone"


def test_missing_inputs_are_errors_not_silent(mac, tmp_path):
    with pytest.raises(FileNotFoundError):
        mig.run_migration(tmp_path / "nope.db", None, url(), apply=False)
    with pytest.raises(FileNotFoundError):
        mig.run_migration(mac.db, tmp_path / "no-archive", url(), apply=False)


def test_the_mac_database_is_opened_read_only(mac):
    before = mac.db.read_bytes()
    mig.run_migration(mac.db, mac.archive, url(), apply=False)
    assert mac.db.read_bytes() == before
