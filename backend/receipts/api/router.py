"""Receipts API under `/api/v1/receipts/...`. Every route needs the receipts bearer token
(`RECEIPTS_API_TOKEN`); any other token gets 401. Contract and examples: docs/api/receipts.md.

PUT  /{id}/photo                 idempotent photo upload (raw JPEG / PNG body), queues extraction
GET  /{id}/photo                 download a photo the server still holds (archive device)
GET  /{id}/extraction            queue state of one receipt
POST /{id}/extraction/retry      queue the extraction again (a user's edits are never overwritten)
POST /{id}/archive-confirm       laptop confirms its copy (sha256) -> server deletes the file
GET  /archive/pending            photos not yet archived
POST /archive/sync               the archive device finished a run
GET  /status                     archive / disk / queue / provider status
GET  /taxonomy, GET /dictionary  category taxonomy and item dictionary
POST /sync/push, GET /sync/pull  offline-first sync
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from core.auth import require_token
from core.db import iso_z, utcnow
from receipts import archive, photos, worker
from receipts.db.models import ExtractionJob, ItemDictionary, Receipt
from receipts.db.session import get_db
from receipts.errors import api_error
from receipts.extraction.taxonomy import merged_taxonomy
from receipts.settings import get_settings
from receipts.sync import pull as pull_mod
from receipts.sync import push as push_mod
from receipts.sync.schemas import PushRequest, PushResponse
from receipts.sync.serialize import dictionary_out, receipt_out
from receipts.uploads import store_photo

router = APIRouter(prefix="/receipts", dependencies=[Depends(require_token)])

HEX64 = r"^[0-9a-fA-F]{64}$"


def _receipt_or_404(db: Session, receipt_id: str) -> Receipt:
    receipt = db.get(Receipt, receipt_id.lower())
    if receipt is None:
        raise api_error(404, "receipt_not_found", "No such receipt.")
    return receipt


async def _read_body(request: Request, limit: int) -> bytes:
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > limit:
        raise api_error(413, "too_large", f"Photos may be at most {limit} bytes.", max_bytes=limit)
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            raise api_error(
                413, "too_large", f"Photos may be at most {limit} bytes.", max_bytes=limit
            )
        chunks.append(chunk)
    return b"".join(chunks)


# --------------------------------------------------------------------------- photos


@router.put("/{receipt_id}/photo")
async def upload_photo(
    receipt_id: str,
    request: Request,
    created_at: Annotated[datetime | None, Query(description="client capture time (UTC)")] = None,
    x_content_sha256: Annotated[str | None, Header()] = None,
    db: Session = Depends(get_db),
) -> Any:
    settings = get_settings()
    data = await _read_body(request, settings.receipts_max_photo_bytes)
    declared = (request.headers.get("content-type") or "").split(";")[0].strip().lower() or None
    if created_at is not None and created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=UTC)
    receipt, created = await run_in_threadpool(
        store_photo,
        db,
        settings,
        receipt_id,
        data,
        declared_type=declared,
        claimed_sha256=x_content_sha256,
        created_at=created_at,
    )
    return JSONResponse(
        {"created": created, "receipt": receipt_out(receipt)}, status_code=201 if created else 200
    )


@router.get("/{receipt_id}/photo")
def download_photo(receipt_id: str, db: Session = Depends(get_db)) -> FileResponse:
    receipt = _receipt_or_404(db, receipt_id)
    if receipt.photo_location == "archived":
        raise api_error(410, "photo_archived", "This photo was archived on the laptop and removed.")
    if receipt.photo_location != "server" or not receipt.photo_path:
        raise api_error(404, "no_photo", "This receipt has no photo on the server.")
    path = photos.photo_abspath(get_settings().receipts_photos_dir, receipt.photo_path)
    if not path.is_file():
        raise api_error(404, "photo_file_missing", "The photo file is missing on the server.")
    return FileResponse(
        path,
        media_type=receipt.photo_media_type or photos.JPEG,
        headers={
            "X-Content-SHA256": receipt.photo_sha256 or "",
            "Cache-Control": "private, no-store",
        },
    )


# --------------------------------------------------------------------------- extraction


def _job_out(receipt: Receipt, job: ExtractionJob | None) -> dict[str, Any]:
    return {
        "receipt_id": receipt.id,
        "status": job.status if job else receipt.extraction_status,
        "attempts": job.attempts if job else receipt.extraction_attempts,
        "max_attempts": get_settings().receipts_extraction_max_attempts,
        "last_error": job.last_error if job else receipt.extraction_error,
        "queued_at": iso_z(job.queued_at) if job else None,
        "not_before": iso_z(job.not_before) if job else None,
        "started_at": iso_z(job.started_at) if job else None,
        "finished_at": iso_z(job.finished_at) if job else None,
    }


@router.get("/{receipt_id}/extraction")
def extraction_state(receipt_id: str, db: Session = Depends(get_db)) -> dict[str, Any]:
    receipt = _receipt_or_404(db, receipt_id)
    job = db.scalar(select(ExtractionJob).where(ExtractionJob.receipt_id == receipt.id))
    return _job_out(receipt, job)


@router.post("/{receipt_id}/extraction/retry", status_code=202)
def retry_extraction(receipt_id: str, db: Session = Depends(get_db)) -> dict[str, Any]:
    receipt = _receipt_or_404(db, receipt_id)
    if receipt.photo_location != "server":
        raise api_error(
            409,
            "photo_not_on_server",
            "The photo is not on the server, so it cannot be extracted again.",
        )
    job = db.scalar(select(ExtractionJob).where(ExtractionJob.receipt_id == receipt.id))
    if job is not None and job.status in ("queued", "processing"):
        raise api_error(409, "already_queued", "The extraction is already queued or running.")
    job = worker.retry(db, receipt)
    db.commit()
    worker.wake_worker()
    return _job_out(receipt, job)


# --------------------------------------------------------------------------- archive


class ArchiveConfirm(BaseModel):
    sha256: str = Field(pattern=HEX64, description="sha256 of the copy the laptop saved")
    device_id: str = Field(min_length=1, max_length=100)
    accept_failed: bool = False


class ArchiveSync(BaseModel):
    device_id: str = Field(min_length=1, max_length=100)


@router.post("/{receipt_id}/archive-confirm")
def archive_confirm(
    receipt_id: str, body: ArchiveConfirm, db: Session = Depends(get_db)
) -> dict[str, Any]:
    return archive.confirm_archive(
        db,
        get_settings(),
        receipt_id.lower(),
        body.sha256,
        body.device_id,
        accept_failed=body.accept_failed,
    )


@router.get("/archive/pending")
def archive_pending(db: Session = Depends(get_db)) -> dict[str, Any]:
    items = archive.list_pending(db)
    return {"count": len(items), "photos": items}


@router.post("/archive/sync")
def archive_sync(body: ArchiveSync, db: Session = Depends(get_db)) -> dict[str, Any]:
    when = archive.record_sync(db, body.device_id)
    db.commit()
    return {"last_archive_sync_at": iso_z(when)}


@router.get("/status")
def status(db: Session = Depends(get_db)) -> dict[str, Any]:
    return archive.status(db, get_settings())


# --------------------------------------------------------------------------- taxonomy, dictionary


@router.get("/taxonomy")
def taxonomy(db: Session = Depends(get_db)) -> dict[str, Any]:
    return merged_taxonomy(db).to_json()  # bundled categories + client additions


@router.get("/dictionary")
def dictionary(
    include_deleted: bool = Query(False),
    flagged: bool = Query(False, description="only live entries flagged as missing a category"),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    q = select(ItemDictionary).order_by(ItemDictionary.canonical_name)
    if flagged:
        q = q.where(ItemDictionary.category_flagged.is_(True), ItemDictionary.deleted_at.is_(None))
    elif not include_deleted:
        q = q.where(ItemDictionary.deleted_at.is_(None))
    entries = [dictionary_out(d) for d in db.scalars(q)]
    return {
        "count": len(entries),
        "taxonomy_version": merged_taxonomy(db).version,
        "entries": entries,
    }


# --------------------------------------------------------------------------- sync


@router.post("/sync/push", response_model=PushResponse)
def sync_push(body: PushRequest, db: Session = Depends(get_db)) -> PushResponse:
    out = push_mod.apply_push(db, body)
    db.commit()
    return PushResponse(server_time=iso_z(utcnow()) or "", results=out.results)


@router.get("/sync/pull")
def sync_pull(
    since: str = Query("", description="cursor from the previous pull; empty = from the start"),
    limit: int = Query(pull_mod.PAGE_SIZE, ge=1, le=5000, description="page size (records)"),
    db: Session = Depends(get_db),
) -> dict[str, Any]:
    try:
        return pull_mod.pull(db, since, limit=limit)
    except pull_mod.BadCursor as exc:
        raise api_error(400, "bad_cursor", str(exc)) from None
