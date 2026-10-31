"""Database helpers: the UTC column type, the wire timestamp format and the SQLite engine factory
(WAL, foreign keys). Migration 0001 refers to `core.db.UTCDateTime`, so this module keeps its path.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import DateTime, Engine, TypeDecorator, create_engine, event


class UTCDateTime(TypeDecorator[datetime]):
    """Stores aware datetimes as naive UTC (SQLite has no tz); returns aware UTC datetimes."""

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError("UTCDateTime requires an aware datetime")
        return value.astimezone(UTC).replace(tzinfo=None)

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None
        return value.replace(tzinfo=UTC)


def utcnow() -> datetime:
    return datetime.now(UTC)


def iso_z(value: datetime | None) -> str | None:
    """Wire format of every timestamp the sync APIs emit: UTC, millisecond precision, `Z`."""
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _sqlite_pragmas(dbapi_conn, _record) -> None:  # pragma: no cover - trivial
    cur = dbapi_conn.cursor()
    cur.execute("PRAGMA journal_mode=WAL")
    cur.execute("PRAGMA foreign_keys=ON")
    cur.execute("PRAGMA busy_timeout=5000")
    cur.execute("PRAGMA synchronous=NORMAL")
    cur.close()


def make_engine(url: str) -> Engine:
    """SQLAlchemy engine; for a SQLite file the directory is created and WAL + FKs are enabled."""
    if url.startswith("sqlite:///") and ":memory:" not in url:
        Path(url.removeprefix("sqlite:///")).parent.mkdir(parents=True, exist_ok=True)
    engine = create_engine(url, future=True)
    if engine.dialect.name == "sqlite":
        event.listen(engine, "connect", _sqlite_pragmas)
    return engine
