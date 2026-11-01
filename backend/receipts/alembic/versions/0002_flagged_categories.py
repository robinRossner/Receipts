"""flagged categories: dictionary flag + suggestions, taxonomy additions

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-31 18:00:00.000000

Adds to `item_dictionary` the columns `category_flagged` (NOT NULL, default false),
`suggested_category` and `suggested_parent`, and creates `taxonomy_additions` (append-only extra
category paths, unique on the case-insensitive triple; no change-sequence triggers: pull sends the
whole table). Existing rows keep working: flag false, suggestions null.

The change-sequence UPDATE trigger of the dictionary (0001) lists the columns whose change bumps
`server_seq`; it is dropped and re-created here with the three new columns, so a change of only the
flag or a suggestion still reaches every client through pull. Plain ALTER TABLE is used (never a
batch alter, which recreates the table and silently drops its triggers).
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

import core.db

revision: str = "0002"
down_revision: str | Sequence[str] | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_OLD_WATCHED = [
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
]
_NEW_COLUMNS = ["category_flagged", "suggested_category", "suggested_parent"]

_STAMP = """
  INSERT INTO sync_seq (seq) VALUES (NULL);
  UPDATE item_dictionary SET server_seq = last_insert_rowid() WHERE rowid = NEW.rowid;
"""


def _recreate_update_trigger(watched: list[str]) -> None:
    changed = " OR ".join(f"NEW.{c} IS NOT OLD.{c}" for c in watched)
    op.execute("DROP TRIGGER IF EXISTS trg_item_dictionary_seq_upd")
    op.execute(
        "CREATE TRIGGER trg_item_dictionary_seq_upd AFTER UPDATE ON item_dictionary\n"
        f"WHEN NEW.server_seq IS OLD.server_seq AND ({changed})\n"
        f"BEGIN{_STAMP}END"
    )


def upgrade() -> None:
    insp = sa.inspect(op.get_bind())
    have = {c["name"] for c in insp.get_columns("item_dictionary")}
    if "category_flagged" not in have:
        op.add_column(
            "item_dictionary",
            sa.Column(
                "category_flagged", sa.Boolean(), nullable=False, server_default=sa.text("0")
            ),
        )
    if "suggested_category" not in have:
        op.add_column(
            "item_dictionary", sa.Column("suggested_category", sa.String(length=80), nullable=True)
        )
    if "suggested_parent" not in have:
        op.add_column(
            "item_dictionary", sa.Column("suggested_parent", sa.String(length=80), nullable=True)
        )
    _recreate_update_trigger([*_OLD_WATCHED, *_NEW_COLUMNS])

    if "taxonomy_additions" not in insp.get_table_names():
        op.create_table(
            "taxonomy_additions",
            sa.Column("id", sa.String(length=36), nullable=False),
            sa.Column("category", sa.String(length=80), nullable=False),
            sa.Column("subcategory", sa.String(length=80), nullable=False),
            sa.Column("item_group", sa.String(length=80), nullable=False),
            sa.Column("created_at", core.db.UTCDateTime(), nullable=False),
            sa.Column("device_id", sa.String(length=100), nullable=True),
            sa.PrimaryKeyConstraint("id", name=op.f("pk_taxonomy_additions")),
        )
        op.create_index(
            "uq_taxonomy_additions_path",
            "taxonomy_additions",
            [sa.text("lower(category)"), sa.text("lower(subcategory)"), sa.text("lower(item_group)")],
            unique=True,
        )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS taxonomy_additions")
    # the trigger mentions the new columns, so it has to go before they can be dropped
    op.execute("DROP TRIGGER IF EXISTS trg_item_dictionary_seq_upd")
    for column in _NEW_COLUMNS:
        op.execute(f"ALTER TABLE item_dictionary DROP COLUMN {column}")
    _recreate_update_trigger(_OLD_WATCHED)
