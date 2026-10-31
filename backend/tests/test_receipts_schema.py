"""The Alembic setup of receipts.db (head 0001) and the change-sequence triggers."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy import select

from receipts.db.models import ItemDictionary, Receipt
from tests.receipts_helpers import alembic_config, migrate_receipts


def _tables(path: Path) -> set[str]:
    with sqlite3.connect(path) as db:
        return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def test_single_head_is_0001():
    # revision ids and the chain must match the live database (head 0001)
    assert ScriptDirectory.from_config(alembic_config("sqlite://")).get_heads() == ["0001"]


def test_fresh_database_migrates_to_head(tmp_path):
    receipts_db = tmp_path / "receipts.db"
    migrate_receipts(f"sqlite:///{receipts_db}")
    assert {"receipts", "line_items", "item_dictionary", "extraction_jobs", "sync_seq"} <= _tables(
        receipts_db
    )
    with sqlite3.connect(receipts_db) as db:
        assert db.execute("SELECT version_num FROM alembic_version").fetchone() == ("0001",)


def test_receipts_migration_is_reversible(tmp_path):
    url = f"sqlite:///{tmp_path / 'receipts.db'}"
    migrate_receipts(url)
    cfg = alembic_config(url)
    command.downgrade(cfg, "base")
    assert _tables(tmp_path / "receipts.db") <= {"alembic_version", "sqlite_sequence"}
    command.upgrade(cfg, "head")
    assert "receipts" in _tables(tmp_path / "receipts.db")


def test_change_sequence_triggers(rdb):
    """Every write bumps server_seq (whichever code path wrote); usage counters do not."""
    entry = ItemDictionary(canonical_name="milch")
    receipt = Receipt(id="3b241101-e2bb-4255-8caf-4136c566a962")
    rdb.add_all([entry, receipt])
    rdb.commit()
    rdb.refresh(entry)  # the triggers stamped server_seq behind the ORM's back
    rdb.refresh(receipt)
    seq_entry, seq_receipt = entry.server_seq, receipt.server_seq
    assert seq_entry and seq_receipt and seq_entry != seq_receipt

    entry.times_seen += 1  # a sighting is not a change phones need to hear about
    rdb.commit()
    rdb.refresh(entry)
    assert entry.server_seq == seq_entry
    entry.category = "Food"
    receipt.extraction_error = "touched"
    rdb.commit()
    rdb.refresh(entry)
    rdb.refresh(receipt)
    assert entry.server_seq > seq_entry and receipt.server_seq > seq_receipt
    assert rdb.scalar(select(Receipt.server_seq)) == receipt.server_seq


def test_canonical_names_are_unique_among_live_entries_only(rdb):
    from datetime import UTC, datetime

    import pytest
    from sqlalchemy.exc import IntegrityError

    rdb.add(ItemDictionary(canonical_name="milch"))
    rdb.commit()
    rdb.add(ItemDictionary(canonical_name="milch"))
    with pytest.raises(IntegrityError):
        rdb.commit()
    rdb.rollback()
    rdb.scalar(select(ItemDictionary)).deleted_at = datetime.now(UTC)
    rdb.commit()
    rdb.add(ItemDictionary(canonical_name="milch"))
    rdb.commit()
