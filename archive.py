"""Photo retention: the laptop is the long-term archive, the server only holds photos until the
laptop has confirmed a verified copy.

Rules (firm):
- A photo is deleted from the server ONLY by `confirm_archive`, which needs the sha256 of the copy
  the laptop saved to match the stored one, and a finished extraction (done, or failed with
  `accept_failed` = the user gave up on it). Nothing here, and nothing scheduled, ever deletes by
  age; nothing deletes files that no database row points at (they may belong to a restored DB).
- A mismatch is an error and keeps the file. Confirming twice is a harmless no-op.
- After the archive the receipt keeps syncing with `photo_location = "archived"`.

The laptop identifies itself with a `device_id` in `confirm_archive` and `record_sync`; the server
remembers when it last did (`last_archive_sync_at`) for the status endpoint and the reminders.
"""

from __future__ import annotations

import logging
import shutil
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from apps.receipts import photos, state
from apps.receipts.db.models import ExtractionJob, Receipt
from apps.receipts.errors import api_error
from apps.receipts.settings import ReceiptsSettings
from core.db import iso_z, utcnow

log = logging.getLogger(__name__)


def pending_filter() -> Any:
    """Receipts whose photo is held by the server only."""
    return (Receipt.photo_location == "server") & Receipt.photo_path.is_not(None)


def blocked_reason(receipt: Receipt) -> str | None:
    """Why the photo cannot be archived yet (None = archivable)."""
    if receipt.extraction_status == "done":
        return None
    if receipt.extraction_status == "failed":
        return "extraction_failed"
    return "extraction_pending"


def pending_out(r: Receipt) -> dict[str, Any]:
    reason = blocked_reason(r)
    return {
        "id": r.id,
        "sha256": r.photo_sha256,
        "bytes": r.photo_bytes,
        "media_type": r.photo_media_type,
        "uploaded_at": iso_z(r.uploaded_at),
        "extraction_status": r.extraction_status,
        "archivable": reason is None,
        "blocked_reason": reason,
        "download": f"/api/v1/receipts/{r.id}/photo",
    }


def list_pending(db: Session) -> list[dict[str, Any]]:
    rows = db.scalars(
        select(Receipt).where(pending_filter()).order_by(Receipt.uploaded_at, Receipt.id)
    )
    return [pending_out(r) for r in rows]


def record_sync(db: Session, device_id: str, when: datetime | None = None) -> datetime:
    """The archive device finished a run (also when there was nothing to archive)."""
    when = when or utcnow()
    state.set_time(db, state.LAST_ARCHIVE_SYNC, when)
    state.set_value(db, state.ARCHIVE_DEVICE, device_id)
    return when


def confirm_archive(
    db: Session,
    settings: ReceiptsSettings,
    receipt_id: str,
    sha256: str,
    device_id: str,
    *,
    accept_failed: bool = False,
) -> dict[str, Any]:
    """Verify the laptop's copy and release the server's. Commits."""
    receipt = db.get(Receipt, receipt_id)
    if receipt is None:
        raise api_error(404, "receipt_not_found", "No such receipt.")
    sha = sha256.lower()
    if receipt.photo_location == "archived":
        if receipt.photo_sha256 and sha != receipt.photo_sha256:
            raise api_error(
                409, "sha256_mismatch", "The checksum does not match this receipt's photo."
            )
        record_sync(db, device_id)
        db.commit()
        _release_file(db, settings, receipt)  # finish a deletion a crash may have interrupted
        return {"status": "already_archived", "receipt_id": receipt.id}
    if receipt.photo_location != "server" or not receipt.photo_sha256:
        raise api_error(409, "no_photo", "This receipt has no photo on the server.")
    if sha != receipt.photo_sha256:
        raise api_error(
            409,
            "sha256_mismatch",
            "The checksum of the saved copy does not match the server's photo; it was kept.",
        )
    reason = blocked_reason(receipt)
    if reason == "extraction_pending":
        raise api_error(409, reason, "Extraction has not finished yet; confirm again later.")
    if reason == "extraction_failed" and not accept_failed:
        raise api_error(
            409,
            reason,
            "Extraction failed. Retry it, or confirm with accept_failed=true to give up on it.",
        )
    receipt.photo_location = "archived"
    receipt.archived_at = utcnow()
    receipt.archived_by = device_id
    record_sync(db, device_id, receipt.archived_at)
    db.commit()  # the database says "archived" before the file goes: a crash keeps the file
    _release_file(db, settings, receipt)
    return {"status": "archived", "receipt_id": receipt.id}


def _release_file(db: Session, settings: ReceiptsSettings, receipt: Receipt) -> None:
    """Delete the file of an archived receipt, then forget its path."""
    if receipt.photo_location != "archived" or not receipt.photo_path:
        return
    try:
        photos.delete_photo(settings.receipts_photos_dir, receipt.photo_path)
    except OSError:
        log.exception("could not delete archived photo of %s", receipt.id)
        return
    receipt.photo_path = None
    db.commit()


def sweep_archived(db: Session, settings: ReceiptsSettings) -> int:
    """Finish deletions of receipts already confirmed as archived (state based, never age based)."""
    n = 0
    for receipt in db.scalars(
        select(Receipt).where(Receipt.photo_location == "archived", Receipt.photo_path.is_not(None))
    ):
        _release_file(db, settings, receipt)
        n += 1
    return n


# --------------------------------------------------------------------------- status


def _disk_path(photos_dir: Path) -> Path:
    path = photos_dir
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def status(db: Session, settings: ReceiptsSettings, now: datetime | None = None) -> dict[str, Any]:
    now = now or utcnow()
    count, size, oldest = db.execute(
        select(
            func.count(Receipt.id),
            func.coalesce(func.sum(Receipt.photo_bytes), 0),
            func.min(Receipt.uploaded_at),
        ).where(pending_filter())
    ).one()
    last_sync = state.get_time(db, state.LAST_ARCHIVE_SYNC)
    # No laptop sync yet: count from the oldest waiting photo, so a fresh install is not overdue.
    if oldest is not None and oldest.tzinfo is None:
        oldest = oldest.replace(tzinfo=UTC)
    reference = last_sync or oldest
    overdue = bool(
        count
        and reference is not None
        and now - reference > timedelta(days=settings.receipts_archive_reminder_days)
    )
    usage = shutil.disk_usage(_disk_path(settings.receipts_photos_dir))
    warning = usage.free < settings.receipts_disk_warning_free_mb * 1024 * 1024
    queue = dict(
        db.execute(select(ExtractionJob.status, func.count()).group_by(ExtractionJob.status)).all()
    )
    from apps.receipts.llm.factory import provider_status

    return {
        "server_time": iso_z(now),
        "last_archive_sync_at": iso_z(last_sync),
        "archive_device_id": state.get_value(db, state.ARCHIVE_DEVICE),
        "unarchived_count": int(count),
        "unarchived_bytes": int(size or 0),
        "oldest_unarchived_at": iso_z(oldest),
        "disk_free_bytes": usage.free,
        "disk_total_bytes": usage.total,
        "archive_reminder_days": settings.receipts_archive_reminder_days,
        "disk_warning_free_mb": settings.receipts_disk_warning_free_mb,
        "archive_overdue": overdue,
        "disk_warning": warning,
        "queue": {k: int(queue.get(k, 0)) for k in ("queued", "processing", "done", "failed")},
        "llm": provider_status(settings),
    }


def reminder_text(st: dict[str, Any]) -> str | None:
    parts: list[str] = []
    if st["archive_overdue"]:
        mb = st["unarchived_bytes"] / 1e6
        parts.append(
            f"{st['unarchived_count']} receipt photo(s) ({mb:.0f} MB) wait on the server and the "
            f"laptop has not archived them for over {st['archive_reminder_days']} days. "
            "Open the Receipts app on your laptop and run the photo archive."
        )
    if st["disk_warning"]:
        parts.append(
            f"The server has only {st['disk_free_bytes'] / 1e9:.1f} GB free "
            f"(warning below {st['disk_warning_free_mb']} MB)."
        )
    return " ".join(parts) or None


def check_and_remind(
    session_factory: sessionmaker[Session],
    settings: ReceiptsSettings,
    notifier: Any,
    now: datetime | None = None,
) -> str:
    """Daily check. Returns none | throttled | sent | undelivered. `notifier(title, text)` returns
    True when the message was delivered. At most one reminder per
    `receipts_reminder_repeat_days`."""
    now = now or utcnow()
    with session_factory() as db:
        st = status(db, settings, now)
        text = reminder_text(st)
        if text is None:
            return "none"
        last = state.get_time(db, state.LAST_REMINDER)
        if last is not None and now - last < timedelta(days=settings.receipts_reminder_repeat_days):
            return "throttled"
        log.warning("receipts reminder: %s", text)
        if not notifier("Receipts: action needed", text):
            return "undelivered"
        state.set_time(db, state.LAST_REMINDER, now)
        db.commit()
        return "sent"
