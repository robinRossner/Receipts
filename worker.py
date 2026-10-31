"""The persisted extraction queue and its in-process worker.

State lives in the database (`extraction_jobs`, mirrored onto the receipt so clients see it through
pull): queued -> processing -> done | failed, with `attempts` and `last_error`. One job runs at a
time on one daemon thread. After a restart jobs stuck in `processing` go back to `queued`
(`recover_stuck`), but a job that was interrupted `max_attempts` times fails instead of looping.
A failed attempt is retried after an exponential backoff until `max_attempts`; then the job is
`failed` and waits for `POST /receipts/{id}/extraction/retry`. A failed extraction never touches
the photo or the receipt: both stay in place and visible.

Without a configured LLM credential nothing is claimed: jobs stay `queued` (no attempt is spent).
"""

from __future__ import annotations

import logging
import threading
from datetime import timedelta

from sqlalchemy import or_, select
from sqlalchemy.orm import Session, sessionmaker

from apps.receipts.db.models import ExtractionJob, Receipt
from apps.receipts.extraction.pipeline import run_extraction
from apps.receipts.extraction.taxonomy import get_taxonomy
from apps.receipts.llm.base import LLMError, LLMProvider
from apps.receipts.llm.factory import build_provider
from apps.receipts.settings import ReceiptsSettings, get_settings
from core.db import utcnow
from core.redact import redact

log = logging.getLogger(__name__)

POLL_S = 30.0
ERROR_MAX_CHARS = 500


def _mirror(receipt: Receipt, job: ExtractionJob) -> None:
    """The client-visible copy of the queue state."""
    receipt.extraction_status = job.status
    receipt.extraction_attempts = job.attempts
    receipt.extraction_error = job.last_error


def enqueue(db: Session, receipt: Receipt) -> ExtractionJob:
    """Create the job of a receipt, or put it back to `queued` with a fresh attempt budget. The
    caller commits. A `processing` job is left alone."""
    job = db.scalar(select(ExtractionJob).where(ExtractionJob.receipt_id == receipt.id))
    if job is None:
        job = ExtractionJob(receipt_id=receipt.id)
        db.add(job)
    elif job.status == "processing":
        return job
    job.status = "queued"
    job.attempts = 0
    job.last_error = None
    job.queued_at = utcnow()
    job.not_before = None
    job.started_at = job.finished_at = None
    _mirror(receipt, job)
    return job


def recover_stuck(session_factory: sessionmaker[Session], max_attempts: int) -> int:
    """Startup: a job left in `processing` was interrupted by a restart. Back to `queued`, unless
    it has used up its attempts (then `failed`, so a crashing photo cannot loop forever)."""
    n = 0
    with session_factory() as db:
        for job in db.scalars(select(ExtractionJob).where(ExtractionJob.status == "processing")):
            receipt = db.get(Receipt, job.receipt_id)
            if job.attempts >= max_attempts:
                job.status = "failed"
                job.finished_at = utcnow()
                job.last_error = "Interrupted by a server restart too often; use retry."
            else:
                job.status = "queued"
                job.not_before = None
                job.last_error = "Interrupted by a server restart; queued again."
            if receipt is not None:
                _mirror(receipt, job)
            n += 1
        db.commit()
    if n:
        log.info("receipts queue: recovered %d interrupted job(s)", n)
    return n


def retry(db: Session, receipt: Receipt) -> ExtractionJob:
    """Manual retry (the caller checks preconditions and commits)."""
    return enqueue(db, receipt)


def claim_next(session_factory: sessionmaker[Session], *, now=None) -> int | None:
    """Move the oldest runnable queued job to `processing` (attempts + 1); its id, or None."""
    now = now or utcnow()
    with session_factory() as db:
        job = db.scalar(
            select(ExtractionJob)
            .where(
                ExtractionJob.status == "queued",
                or_(ExtractionJob.not_before.is_(None), ExtractionJob.not_before <= now),
            )
            .order_by(ExtractionJob.queued_at, ExtractionJob.id)
            .limit(1)
        )
        if job is None:
            return None
        job.status = "processing"
        job.attempts += 1
        job.started_at = now
        receipt = db.get(Receipt, job.receipt_id)
        if receipt is not None:
            _mirror(receipt, job)
        db.commit()
        return job.id


def _finish(
    session_factory: sessionmaker[Session],
    job_id: int,
    *,
    error: LLMError | Exception | None,
    settings: ReceiptsSettings,
) -> None:
    now = utcnow()
    with session_factory() as db:
        job = db.get(ExtractionJob, job_id)
        if job is None:
            return
        receipt = db.get(Receipt, job.receipt_id)
        if error is None:
            job.status = "done"
            job.last_error = None
            job.finished_at = now
            job.not_before = None
        else:
            message = redact(getattr(error, "message", None) or str(error))[:ERROR_MAX_CHARS]
            retryable = getattr(error, "retryable", True)  # unknown errors: worth another try
            job.last_error = message
            if retryable and job.attempts < settings.receipts_extraction_max_attempts:
                backoff = settings.receipts_extraction_backoff_s * 2 ** (job.attempts - 1)
                job.status = "queued"
                job.not_before = now + timedelta(seconds=backoff)
            else:
                job.status = "failed"
                job.finished_at = now
                job.not_before = None
        if receipt is not None:
            _mirror(receipt, job)
        db.commit()


def process_job(
    session_factory: sessionmaker[Session],
    job_id: int,
    provider: LLMProvider,
    settings: ReceiptsSettings | None = None,
) -> None:
    """Run one claimed job to its next state. Never raises."""
    settings = settings or get_settings()
    with session_factory() as db:
        job = db.get(ExtractionJob, job_id)
        receipt = db.get(Receipt, job.receipt_id) if job else None
        if job is None or receipt is None:
            return
        receipt_id, deleted = receipt.id, receipt.deleted_at is not None
    if deleted:  # a deleted receipt needs no extraction
        _finish(session_factory, job_id, error=None, settings=settings)
        return
    try:
        run_extraction(session_factory, receipt_id, provider, get_taxonomy(), settings)
    except LLMError as exc:
        log.warning("receipts extraction failed (%s): %s", exc.kind, redact(exc.message))
        _finish(session_factory, job_id, error=exc, settings=settings)
    except Exception as exc:
        log.exception("receipts extraction crashed")
        _finish(session_factory, job_id, error=exc, settings=settings)
    else:
        _finish(session_factory, job_id, error=None, settings=settings)


def run_next(
    session_factory: sessionmaker[Session],
    provider: LLMProvider | None,
    settings: ReceiptsSettings | None = None,
) -> bool:
    """Claim and process one job; False if there was nothing to do (or no provider)."""
    if provider is None:
        return False
    job_id = claim_next(session_factory)
    if job_id is None:
        return False
    process_job(session_factory, job_id, provider, settings)
    return True


class ExtractionWorker:
    """Daemon thread that drains the queue, one job at a time."""

    def __init__(self, session_factory: sessionmaker[Session]):
        self._factory = session_factory
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        settings = get_settings()
        recover_stuck(self._factory, settings.receipts_extraction_max_attempts)
        self._thread = threading.Thread(target=self._loop, name="receipts-worker", daemon=True)
        self._thread.start()

    def wake(self) -> None:
        self._wake.set()

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout)

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                settings = get_settings()
                worked = run_next(self._factory, build_provider(settings), settings)
            except Exception:
                log.exception("receipts worker loop error")
                worked = False
            if not worked:
                self._wake.wait(POLL_S)
                self._wake.clear()


_worker: ExtractionWorker | None = None


def set_worker(worker: ExtractionWorker | None) -> None:
    global _worker
    _worker = worker


def wake_worker() -> None:
    if _worker is not None:
        _worker.wake()
