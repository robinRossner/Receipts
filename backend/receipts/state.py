"""Tiny key/value state in receipts.db (last archive sync, archive device, last reminder)."""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy.orm import Session

from core.db import utcnow
from receipts.db.models import StateEntry

LAST_ARCHIVE_SYNC = "last_archive_sync_at"
ARCHIVE_DEVICE = "archive_device_id"
LAST_REMINDER = "last_reminder_at"


def get_value(db: Session, key: str) -> str | None:
    row = db.get(StateEntry, key)
    return row.value if row else None


def set_value(db: Session, key: str, value: str) -> None:
    row = db.get(StateEntry, key)
    if row is None:
        db.add(StateEntry(key=key, value=value, updated_at=utcnow()))
    else:
        row.value = value
        row.updated_at = utcnow()


def get_time(db: Session, key: str) -> datetime | None:
    value = get_value(db, key)
    if not value:
        return None
    parsed = datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def set_time(db: Session, key: str, when: datetime) -> None:
    set_value(db, key, when.astimezone(UTC).isoformat())
