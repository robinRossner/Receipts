"""SQLAlchemy models of `receipts.db` (mirrors the Mac app's schema, plus sync fields).

Conventions
- Sync identity is a client-generatable UUID string (`id`); the Mac app's integer rowid survives as
  `legacy_id` (migration only, never used by the API).
- Receipts, line items and dictionary entries carry `updated_at` (last-write-wins clock of
  *client* writes), `deleted_at` (tombstone, rows are never hard-deleted) and `server_seq`
  (global change counter stamped by triggers, migration 0001, which drives pull).
- Server-side work (extraction, archive) changes columns but never `updated_at`, so a user's edit
  with an older clock than an extraction still wins over it, and an extraction never beats an edit.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    JSON,
    Boolean,
    Float,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    String,
    Text,
    text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from core.db import UTCDateTime, utcnow

NAMING = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

PHOTO_LOCATIONS = ("server", "archived", "none")
EXTRACTION_STATUSES = ("none", "queued", "processing", "done", "failed")


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING)
    type_annotation_map = {  # noqa: RUF012 - SQLAlchemy reads this class attribute
        dict[str, Any]: JSON,
        list[Any]: JSON,
        datetime: UTCDateTime,
    }


def new_uuid() -> str:
    return str(uuid.uuid4())


class ItemDictionary(Base):
    """One canonical product (Mac `item_dictionary`). Shared by all receipts."""

    __tablename__ = "item_dictionary"
    __table_args__ = (
        # canonical names are unique among live entries (a merged-away tombstone frees its name)
        Index(
            "uq_item_dictionary_canonical_live",
            "canonical_name",
            unique=True,
            sqlite_where=text("deleted_at IS NULL"),
        ),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    legacy_id: Mapped[int | None] = mapped_column(Integer, unique=True)
    canonical_name: Mapped[str] = mapped_column(String(255))
    display_name_de: Mapped[str | None] = mapped_column(String(255))
    translation_en: Mapped[str | None] = mapped_column(String(255))
    category: Mapped[str | None] = mapped_column(String(80))
    subcategory: Mapped[str | None] = mapped_column(String(80))
    item_group: Mapped[str | None] = mapped_column(String(80))
    aliases: Mapped[list[Any]] = mapped_column(JSON, default=list)
    is_manual_override: Mapped[bool] = mapped_column(Boolean, default=False)
    needs_review: Mapped[bool] = mapped_column(Boolean, default=False)
    times_seen: Mapped[int] = mapped_column(Integer, default=1)  # server-owned
    created_at: Mapped[datetime] = mapped_column(default=utcnow)
    last_seen_at: Mapped[datetime | None] = mapped_column()  # server-owned
    updated_at: Mapped[datetime] = mapped_column(default=utcnow)
    deleted_at: Mapped[datetime | None] = mapped_column()
    server_seq: Mapped[int | None] = mapped_column(Integer, index=True)


class Receipt(Base):
    __tablename__ = "receipts"
    __table_args__ = (
        Index("ix_receipts_date", "date"),
        Index("ix_receipts_photo_sha256", "photo_sha256"),
        Index("ix_receipts_photo_location", "photo_location"),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    legacy_id: Mapped[int | None] = mapped_column(Integer, unique=True)

    # --- content (client-writable through sync push; filled by extraction until a user edits)
    store: Mapped[str | None] = mapped_column(String(160))
    date: Mapped[str | None] = mapped_column(String(10))  # "YYYY-MM-DD", as in the Mac app
    time: Mapped[str | None] = mapped_column(String(5))  # "HH:MM"
    total: Mapped[float | None] = mapped_column(Float)
    computed_sum: Mapped[float | None] = mapped_column(Float)
    needs_review: Mapped[bool] = mapped_column(Boolean, default=False)
    review_reasons: Mapped[list[Any]] = mapped_column(JSON, default=list)
    reviewed_at: Mapped[datetime | None] = mapped_column()  # set = confirmed by the user
    created_at: Mapped[datetime] = mapped_column(default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(default=utcnow)  # LWW clock of client writes
    deleted_at: Mapped[datetime | None] = mapped_column()
    # Set when a client push changed this receipt or its items: extraction results never replace
    # a user's edit (receipts/extraction/pipeline.py).
    user_edited_at: Mapped[datetime | None] = mapped_column()

    # --- photo (server-owned)
    photo_location: Mapped[str] = mapped_column(String(10), default="none")  # server|archived|none
    photo_path: Mapped[str | None] = mapped_column(String(255))  # relative to the photos dir
    photo_sha256: Mapped[str | None] = mapped_column(String(64))
    photo_bytes: Mapped[int | None] = mapped_column(Integer)
    photo_media_type: Mapped[str | None] = mapped_column(String(32))
    uploaded_at: Mapped[datetime | None] = mapped_column()
    archived_at: Mapped[datetime | None] = mapped_column()
    archived_by: Mapped[str | None] = mapped_column(String(100))

    # --- extraction (server-owned, mirrors the queue row so clients see it through pull)
    extraction_status: Mapped[str] = mapped_column(String(12), default="none")
    extraction_attempts: Mapped[int] = mapped_column(Integer, default=0)
    extraction_error: Mapped[str | None] = mapped_column(Text)
    extraction_provider: Mapped[str | None] = mapped_column(String(80))
    extraction_completed_at: Mapped[datetime | None] = mapped_column()
    extraction_result: Mapped[dict[str, Any] | None] = mapped_column(JSON)  # raw, for reference

    server_seq: Mapped[int | None] = mapped_column(Integer, index=True)


class LineItem(Base):
    __tablename__ = "line_items"
    __table_args__ = (Index("ix_line_items_receipt", "receipt_id"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_uuid)
    legacy_id: Mapped[int | None] = mapped_column(Integer, unique=True)
    receipt_id: Mapped[str] = mapped_column(ForeignKey("receipts.id"))
    item_dictionary_id: Mapped[str] = mapped_column(ForeignKey("item_dictionary.id"), index=True)
    position: Mapped[int] = mapped_column(Integer, default=0)
    raw_text: Mapped[str | None] = mapped_column(Text)
    name_de: Mapped[str | None] = mapped_column(String(255))
    quantity: Mapped[float] = mapped_column(Float, default=1.0)
    unit_price: Mapped[float] = mapped_column(Float, default=0.0)
    total_price: Mapped[float] = mapped_column(Float, default=0.0)
    price_normalized: Mapped[bool] = mapped_column(Boolean, default=False)
    updated_at: Mapped[datetime] = mapped_column(default=utcnow)
    deleted_at: Mapped[datetime | None] = mapped_column()
    server_seq: Mapped[int | None] = mapped_column(Integer, index=True)


class ExtractionJob(Base):
    """The persisted extraction queue: one row per receipt (re-queued by retry)."""

    __tablename__ = "extraction_jobs"
    __table_args__ = (Index("ix_extraction_jobs_status", "status", "not_before"),)
    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    receipt_id: Mapped[str] = mapped_column(ForeignKey("receipts.id"), unique=True)
    status: Mapped[str] = mapped_column(
        String(12), default="queued"
    )  # queued|processing|done|failed
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    last_error: Mapped[str | None] = mapped_column(Text)
    queued_at: Mapped[datetime] = mapped_column(default=utcnow)
    not_before: Mapped[datetime | None] = mapped_column()  # backoff after a failed attempt
    started_at: Mapped[datetime | None] = mapped_column()
    finished_at: Mapped[datetime | None] = mapped_column()


class SyncSeq(Base):
    """Global change counter; rows are only ever inserted by the sync triggers."""

    __tablename__ = "sync_seq"
    __table_args__ = {"sqlite_autoincrement": True}  # noqa: RUF012 - never reuse a seq
    seq: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)


class StateEntry(Base):
    """Tiny key/value store: last archive sync, archive device id, last reminder."""

    __tablename__ = "state"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(default=utcnow)
