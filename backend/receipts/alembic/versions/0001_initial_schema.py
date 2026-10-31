"""initial schema: receipts, line items, dictionary, extraction queue, sync sequence

Revision ID: 0001
Revises:
Create Date: 2026-10-31 10:00:00.000000

Mirrors the Mac app's schema (receipts, line_items, item_dictionary) with UUID sync identities and
sync fields. `GET /api/v1/receipts/sync/pull` pages through changes by a monotonic server-side
sequence: every row of the synced tables carries `server_seq`, stamped by SQLite triggers from the
global `sync_seq` counter on INSERT and on every UPDATE that changes a watched column, so the
cursor is right whichever code path wrote the row (API, extraction worker, migration script).

CAUTION: SQLite batch migrations recreate a table and thereby drop its triggers. Any later
migration that batch-alters one of these tables must re-create them (see `_create_triggers`).
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

import core.db

revision: str = "0001"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# table -> columns whose change must bump server_seq. The dictionary's usage counters are left
# out: a sighting must not make the entry look changed on every phone.
SYNCED: dict[str, list[str] | None] = {
    "receipts": None,
    "line_items": None,
    "item_dictionary": [
        "canonical_name",
        "display_name_de",
        "translation_en",
        "category",
        "subcategory",
        "item_group",
        "aliases",
        "is_manual_override",
        "needs_review",
        "updated_at",
        "deleted_at",
    ],
}

_STAMP = """
  INSERT INTO sync_seq (seq) VALUES (NULL);
  UPDATE {t} SET server_seq = last_insert_rowid() WHERE rowid = NEW.rowid;
"""


def _create_triggers(table: str, watched: list[str] | None) -> None:
    changed = " OR ".join(f"NEW.{c} IS NOT OLD.{c}" for c in watched) if watched else "1"
    op.execute(
        f"CREATE TRIGGER trg_{table}_seq_ins AFTER INSERT ON {table}\n"
        f"BEGIN{_STAMP.format(t=table)}END"
    )
    op.execute(
        f"CREATE TRIGGER trg_{table}_seq_upd AFTER UPDATE ON {table}\n"
        f"WHEN NEW.server_seq IS OLD.server_seq AND ({changed})\n"
        f"BEGIN{_STAMP.format(t=table)}END"
    )


def upgrade() -> None:
    op.create_table(
        "sync_seq",
        sa.Column("seq", sa.Integer(), autoincrement=True, nullable=False),
        sa.PrimaryKeyConstraint("seq", name=op.f("pk_sync_seq")),
        sqlite_autoincrement=True,
    )
    op.create_table(
        "state",
        sa.Column("key", sa.String(length=64), nullable=False),
        sa.Column("value", sa.Text(), nullable=False),
        sa.Column("updated_at", core.db.UTCDateTime(), nullable=False),
        sa.PrimaryKeyConstraint("key", name=op.f("pk_state")),
    )
    op.create_table(
        "item_dictionary",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("legacy_id", sa.Integer(), nullable=True),
        sa.Column("canonical_name", sa.String(length=255), nullable=False),
        sa.Column("display_name_de", sa.String(length=255), nullable=True),
        sa.Column("translation_en", sa.String(length=255), nullable=True),
        sa.Column("category", sa.String(length=80), nullable=True),
        sa.Column("subcategory", sa.String(length=80), nullable=True),
        sa.Column("item_group", sa.String(length=80), nullable=True),
        sa.Column("aliases", sa.JSON(), nullable=False),
        sa.Column("is_manual_override", sa.Boolean(), nullable=False),
        sa.Column("needs_review", sa.Boolean(), nullable=False),
        sa.Column("times_seen", sa.Integer(), nullable=False),
        sa.Column("created_at", core.db.UTCDateTime(), nullable=False),
        sa.Column("last_seen_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("updated_at", core.db.UTCDateTime(), nullable=False),
        sa.Column("deleted_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("server_seq", sa.Integer(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_item_dictionary")),
        sa.UniqueConstraint("legacy_id", name=op.f("uq_item_dictionary_legacy_id")),
    )
    op.create_index(
        "uq_item_dictionary_canonical_live",
        "item_dictionary",
        ["canonical_name"],
        unique=True,
        sqlite_where=sa.text("deleted_at IS NULL"),
    )
    op.create_index(
        op.f("ix_item_dictionary_server_seq"), "item_dictionary", ["server_seq"], unique=False
    )
    op.create_table(
        "receipts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("legacy_id", sa.Integer(), nullable=True),
        sa.Column("store", sa.String(length=160), nullable=True),
        sa.Column("date", sa.String(length=10), nullable=True),
        sa.Column("time", sa.String(length=5), nullable=True),
        sa.Column("total", sa.Float(), nullable=True),
        sa.Column("computed_sum", sa.Float(), nullable=True),
        sa.Column("needs_review", sa.Boolean(), nullable=False),
        sa.Column("review_reasons", sa.JSON(), nullable=False),
        sa.Column("reviewed_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("created_at", core.db.UTCDateTime(), nullable=False),
        sa.Column("updated_at", core.db.UTCDateTime(), nullable=False),
        sa.Column("deleted_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("user_edited_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("photo_location", sa.String(length=10), nullable=False),
        sa.Column("photo_path", sa.String(length=255), nullable=True),
        sa.Column("photo_sha256", sa.String(length=64), nullable=True),
        sa.Column("photo_bytes", sa.Integer(), nullable=True),
        sa.Column("photo_media_type", sa.String(length=32), nullable=True),
        sa.Column("uploaded_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("archived_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("archived_by", sa.String(length=100), nullable=True),
        sa.Column("extraction_status", sa.String(length=12), nullable=False),
        sa.Column("extraction_attempts", sa.Integer(), nullable=False),
        sa.Column("extraction_error", sa.Text(), nullable=True),
        sa.Column("extraction_provider", sa.String(length=80), nullable=True),
        sa.Column("extraction_completed_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("extraction_result", sa.JSON(), nullable=True),
        sa.Column("server_seq", sa.Integer(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_receipts")),
        sa.UniqueConstraint("legacy_id", name=op.f("uq_receipts_legacy_id")),
    )
    op.create_index("ix_receipts_date", "receipts", ["date"], unique=False)
    op.create_index("ix_receipts_photo_sha256", "receipts", ["photo_sha256"], unique=False)
    op.create_index("ix_receipts_photo_location", "receipts", ["photo_location"], unique=False)
    op.create_index(op.f("ix_receipts_server_seq"), "receipts", ["server_seq"], unique=False)
    op.create_table(
        "line_items",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("legacy_id", sa.Integer(), nullable=True),
        sa.Column("receipt_id", sa.String(length=36), nullable=False),
        sa.Column("item_dictionary_id", sa.String(length=36), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("raw_text", sa.Text(), nullable=True),
        sa.Column("name_de", sa.String(length=255), nullable=True),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("unit_price", sa.Float(), nullable=False),
        sa.Column("total_price", sa.Float(), nullable=False),
        sa.Column("price_normalized", sa.Boolean(), nullable=False),
        sa.Column("updated_at", core.db.UTCDateTime(), nullable=False),
        sa.Column("deleted_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("server_seq", sa.Integer(), nullable=True),
        sa.ForeignKeyConstraint(
            ["item_dictionary_id"],
            ["item_dictionary.id"],
            name=op.f("fk_line_items_item_dictionary_id_item_dictionary"),
        ),
        sa.ForeignKeyConstraint(
            ["receipt_id"], ["receipts.id"], name=op.f("fk_line_items_receipt_id_receipts")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_line_items")),
        sa.UniqueConstraint("legacy_id", name=op.f("uq_line_items_legacy_id")),
    )
    op.create_index("ix_line_items_receipt", "line_items", ["receipt_id"], unique=False)
    op.create_index(
        op.f("ix_line_items_item_dictionary_id"), "line_items", ["item_dictionary_id"], unique=False
    )
    op.create_index(op.f("ix_line_items_server_seq"), "line_items", ["server_seq"], unique=False)
    op.create_table(
        "extraction_jobs",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("receipt_id", sa.String(length=36), nullable=False),
        sa.Column("status", sa.String(length=12), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("queued_at", core.db.UTCDateTime(), nullable=False),
        sa.Column("not_before", core.db.UTCDateTime(), nullable=True),
        sa.Column("started_at", core.db.UTCDateTime(), nullable=True),
        sa.Column("finished_at", core.db.UTCDateTime(), nullable=True),
        sa.ForeignKeyConstraint(
            ["receipt_id"], ["receipts.id"], name=op.f("fk_extraction_jobs_receipt_id_receipts")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_extraction_jobs")),
        sa.UniqueConstraint("receipt_id", name=op.f("uq_extraction_jobs_receipt_id")),
    )
    op.create_index(
        "ix_extraction_jobs_status", "extraction_jobs", ["status", "not_before"], unique=False
    )
    for table, watched in SYNCED.items():
        _create_triggers(table, watched)


def downgrade() -> None:
    for table in SYNCED:
        op.execute(f"DROP TRIGGER IF EXISTS trg_{table}_seq_ins")
        op.execute(f"DROP TRIGGER IF EXISTS trg_{table}_seq_upd")
    op.drop_table("extraction_jobs")
    op.drop_table("line_items")
    op.drop_table("receipts")
    op.drop_table("item_dictionary")
    op.drop_table("state")
    op.drop_table("sync_seq")
