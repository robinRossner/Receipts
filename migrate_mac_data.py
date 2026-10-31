"""One-off import of the Mac app's data: `uv run python -m apps.receipts.migrate_mac_data`.

    --db PATH        the Mac app's receipts.db (opened read-only)
    --archive DIR    its receipts_archive/ folder (only used to find and hash the photos)
    --apply          write to receipts.db; without it nothing is written (dry run, the default)

Reads only the two paths it is given. Idempotent: every row gets a stable UUID derived from the
Mac row id (uuid5), rows that already exist on the server are left alone (so later edits made
through sync are never overwritten) and running it twice adds nothing. Photos the Mac holds are NOT
uploaded: those receipts are marked `photo_location = archived` (the laptop is the archive; the
file's sha256 is recorded); a receipt whose file is not found under --archive is imported without a
photo (`none`) and reported. Receipts come in as extraction `done` with their review status as is
(`reviewed_at`); soft-deleted receipts come in as tombstones.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated, Any

import typer
from alembic import command
from alembic.config import Config
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from apps.receipts import photos
from apps.receipts.db.models import ItemDictionary, LineItem, Receipt
from apps.receipts.db.session import make_engine
from apps.receipts.settings import RECEIPTS_DIR, get_settings
from core.db import utcnow

NAMESPACE = uuid.UUID("0b8f3c52-6d1e-4c7a-9a4e-2f5d8e1b7c63")
ARCHIVED_BY = "mac-migration"
ARCHIVE_DIR_NAME = "receipts_archive"


def uid(kind: str, legacy_id: int) -> str:
    """The stable UUID of a Mac row: the same input always gives the same id."""
    return str(uuid.uuid5(NAMESPACE, f"mac:{kind}:{legacy_id}"))


def parse_time(value: str | None, default: datetime) -> datetime:
    if not value:
        return default
    try:
        parsed = datetime.fromisoformat(value.strip().replace(" ", "T"))
    except ValueError:
        return default
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def _json_list(value: str | None) -> list[Any]:
    try:
        data = json.loads(value or "[]")
    except ValueError:
        return []
    return data if isinstance(data, list) else []


@dataclass
class Report:
    apply: bool
    dictionary_new: int = 0
    dictionary_existing: int = 0
    receipts_new: int = 0
    receipts_existing: int = 0
    line_items_new: int = 0
    line_items_existing: int = 0
    photos_archived: int = 0  # receipts marked archived (file found and hashed)
    photos_missing: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)

    def lines(self) -> list[str]:
        mode = "APPLIED" if self.apply else "DRY RUN (nothing written; pass --apply)"

        def row(label: str, new: int, there: int) -> str:
            return f"  {label:<20}{new} new, {there} already there"

        out = [
            f"Mac data migration: {mode}",
            row("dictionary entries:", self.dictionary_new, self.dictionary_existing),
            row("receipts:", self.receipts_new, self.receipts_existing),
            row("line items:", self.line_items_new, self.line_items_existing),
            f"  photos marked archived (not uploaded): {self.photos_archived}",
        ]
        if self.photos_missing:
            out.append(
                f"  receipts without a photo file under --archive: {len(self.photos_missing)}"
            )
            out += [f"    - {p}" for p in self.photos_missing[:20]]
        if self.skipped:
            out.append(f"  skipped rows: {len(self.skipped)}")
            out += [f"    - {s}" for s in self.skipped[:20]]
        return out


def _resolve_photo(archive_dir: Path | None, stored: str | None) -> Path | None:
    """The photo file below the archive dir for a Mac `source_image`, or None. Never leaves it."""
    if archive_dir is None or not stored:
        return None
    rel = stored
    marker = f"{ARCHIVE_DIR_NAME}/"
    if marker in rel:  # relative ("receipts_archive/2026/07/x.jpg") or absolute path of the archive
        rel = rel.split(marker, 1)[1]
    elif rel.startswith("/"):
        return None  # a staging path outside the archive: not ours to read
    root = archive_dir.resolve()
    path = (root / rel).resolve()
    return path if root in path.parents and path.is_file() else None


def _photo_facts(path: Path) -> tuple[str, int, str | None] | None:
    """(sha256, size, media type) of the photo file; media type None if it is not JPEG / PNG."""
    data = path.read_bytes()
    try:
        media = photos.inspect_image(data).media_type
    except photos.InvalidImage:
        media = None
    return hashlib.sha256(data).hexdigest(), len(data), media


def migrate(
    mac_db: sqlite3.Connection, archive_dir: Path | None, db: Session, report: Report
) -> None:
    """Add the Mac rows to `db` (flushes, never commits)."""
    mac_db.row_factory = sqlite3.Row
    now = utcnow()

    existing_d = set(db.scalars(select(ItemDictionary.id)))
    for row in mac_db.execute("SELECT * FROM item_dictionary ORDER BY id"):
        id_ = uid("dictionary", row["id"])
        if id_ in existing_d:
            report.dictionary_existing += 1
            continue
        created = parse_time(row["created_at"], now)
        seen = parse_time(row["last_seen_at"], created)
        db.add(
            ItemDictionary(
                id=id_,
                legacy_id=row["id"],
                canonical_name=row["canonical_name"],
                display_name_de=row["display_name_de"],
                translation_en=row["translation_en"],
                category=row["category"],
                subcategory=row["subcategory"],
                item_group=row["item_group"],
                aliases=[a for a in _json_list(row["aliases"]) if isinstance(a, str)],
                is_manual_override=bool(row["is_manual_override"]),
                needs_review=bool(row["needs_review"]),
                times_seen=row["times_seen"] or 1,
                created_at=created,
                last_seen_at=seen,
                updated_at=max(created, seen),
            )
        )
        report.dictionary_new += 1
    db.flush()

    existing_r = set(db.scalars(select(Receipt.id)))
    mac_receipts: dict[int, str] = {}
    for row in mac_db.execute("SELECT * FROM receipts ORDER BY id"):
        id_ = uid("receipt", row["id"])
        mac_receipts[row["id"]] = id_
        if id_ in existing_r:
            report.receipts_existing += 1
            continue
        created = parse_time(row["created_at"], now)
        reviewed = parse_time(row["reviewed_at"], created) if row["reviewed_at"] else None
        deleted = parse_time(row["deleted_at"], created) if row["deleted_at"] else None
        location, sha, size, media, path = "none", None, None, None, None
        photo = _resolve_photo(archive_dir, row["source_image"])
        if photo is not None:
            sha, size, media = _photo_facts(photo)
            location, path = "archived", None
            report.photos_archived += 1
        elif row["source_image"]:
            report.photos_missing.append(f"receipt #{row['id']}: {row['source_image']}")
        db.add(
            Receipt(
                id=id_,
                legacy_id=row["id"],
                store=row["store"],
                date=row["date"],
                time=row["time"],
                total=row["total"],
                computed_sum=row["computed_sum"],
                needs_review=bool(row["needs_review"]),
                review_reasons=[r for r in _json_list(row["review_reasons"]) if isinstance(r, str)],
                reviewed_at=reviewed,
                created_at=created,
                updated_at=max(t for t in (created, reviewed, deleted) if t),
                deleted_at=deleted,
                user_edited_at=now,  # the Mac data is authoritative: no extraction may replace it
                photo_location=location,
                photo_path=path,
                photo_sha256=sha,
                photo_bytes=size,
                photo_media_type=media,
                uploaded_at=None,
                archived_at=now if location == "archived" else None,
                archived_by=ARCHIVED_BY if location == "archived" else None,
                extraction_status="done",
                extraction_provider="mac-app",
                extraction_completed_at=created,
            )
        )
        report.receipts_new += 1
    db.flush()

    existing_l = set(db.scalars(select(LineItem.id)))
    live_d = {row["id"] for row in mac_db.execute("SELECT id FROM item_dictionary")}
    positions: dict[int, int] = {}
    for row in mac_db.execute("SELECT * FROM line_items ORDER BY id"):
        id_ = uid("line_item", row["id"])
        if id_ in existing_l:
            report.line_items_existing += 1
            continue
        if row["receipt_id"] not in mac_receipts or row["item_dictionary_id"] not in live_d:
            report.skipped.append(
                f"line item #{row['id']}: its receipt or dictionary entry is missing"
            )
            continue
        receipt_uuid = mac_receipts[row["receipt_id"]]
        position = positions.get(row["receipt_id"], 0)
        positions[row["receipt_id"]] = position + 1
        receipt = db.get(Receipt, receipt_uuid)
        db.add(
            LineItem(
                id=id_,
                legacy_id=row["id"],
                receipt_id=receipt_uuid,
                item_dictionary_id=uid("dictionary", row["item_dictionary_id"]),
                position=position,
                raw_text=row["raw_text"],
                name_de=row["name_de"],
                quantity=row["quantity"] if row["quantity"] is not None else 1.0,
                unit_price=row["unit_price"] or 0.0,
                total_price=row["total_price"] or 0.0,
                price_normalized=bool(row["price_normalized"]),
                updated_at=receipt.created_at if receipt else now,
            )
        )
        report.line_items_new += 1
    db.flush()


def run_migration(
    mac_db_path: Path, archive_dir: Path | None, database_url: str, *, apply: bool
) -> Report:
    """Migrate (apply=True) or only report what would change (a dry run writes nothing: the work
    is done in a transaction that is rolled back, or skipped when the database does not exist)."""
    if not mac_db_path.is_file():
        raise FileNotFoundError(f"Mac database not found: {mac_db_path}")
    if archive_dir is not None and not archive_dir.is_dir():
        raise FileNotFoundError(f"archive folder not found: {archive_dir}")
    report = Report(apply=apply)
    mac = sqlite3.connect(f"file:{mac_db_path}?mode=ro", uri=True)
    try:
        if apply:
            cfg = Config(str(RECEIPTS_DIR / "alembic.ini"))
            cfg.set_main_option("script_location", str(RECEIPTS_DIR / "alembic"))
            cfg.attributes["url"] = database_url
            command.upgrade(cfg, "head")
        elif not _db_exists(database_url):
            # nothing to compare with: everything would be new (a throwaway database does the sums)
            return _dry_run_on_empty_database(mac, archive_dir, report)
        engine = make_engine(database_url)
        try:
            factory = sessionmaker(bind=engine, expire_on_commit=False)
            with factory() as db:
                migrate(mac, archive_dir, db, report)
                if apply:
                    db.commit()
                else:
                    db.rollback()
        finally:
            engine.dispose()
    finally:
        mac.close()
    return report


def _db_exists(url: str) -> bool:
    return url.startswith("sqlite:///") and Path(url.removeprefix("sqlite:///")).is_file()


def _dry_run_on_empty_database(
    mac: sqlite3.Connection, archive_dir: Path | None, report: Report
) -> Report:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="receipts-dryrun-") as tmp:
        url = f"sqlite:///{tmp}/dry.db"
        cfg = Config(str(RECEIPTS_DIR / "alembic.ini"))
        cfg.set_main_option("script_location", str(RECEIPTS_DIR / "alembic"))
        cfg.attributes["url"] = url
        command.upgrade(cfg, "head")
        engine = make_engine(url)
        try:
            with sessionmaker(bind=engine, expire_on_commit=False)() as db:
                migrate(mac, archive_dir, db, report)
                db.rollback()
        finally:
            engine.dispose()
    return report


cli = typer.Typer(add_completion=False, help="Import the Mac app's receipts database")


@cli.command()
def main(
    db: Annotated[Path, typer.Option("--db", help="the Mac app's receipts.db")],
    archive: Annotated[
        Path | None, typer.Option("--archive", help="the Mac app's receipts_archive/ folder")
    ] = None,
    apply: Annotated[
        bool, typer.Option("--apply/--dry-run", help="write to receipts.db (default: dry run)")
    ] = False,
) -> None:
    report = run_migration(db, archive, get_settings().receipts_database_url, apply=apply)
    for line in report.lines():
        typer.echo(line)


if __name__ == "__main__":
    cli()
