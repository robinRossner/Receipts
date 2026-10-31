"""FastAPI entry point of the Receipts server: `uv run uvicorn server:app --reload`.

One process, one SQLite database (receipts.db). The API lives under `/api/v1/receipts/...`
(receipts/router.py); `/health` is public. A daily scheduler job (archive / disk reminder) runs
when SCHEDULER_ENABLED=true and the extraction queue worker runs as a daemon thread
(receipts/worker.py).
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from core.settings import get_core_settings
from receipts import __version__
from receipts.router import include_receipts_routes
from receipts.settings import get_settings

log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    scheduler = None
    if settings.scheduler_enabled:
        from apscheduler.schedulers.background import BackgroundScheduler

        from receipts.jobs import add_receipts_jobs

        scheduler = BackgroundScheduler(timezone=settings.scheduler_tz)
        add_receipts_jobs(scheduler, settings)
        scheduler.start()
        log.info("scheduler started (%d jobs)", len(scheduler.get_jobs()))
    worker = _start_worker()
    try:
        yield
    finally:
        if worker is not None:
            worker.stop()
        if scheduler is not None:
            scheduler.shutdown(wait=False)


def _start_worker():
    """The extraction worker thread; a failure here must not stop the API."""
    if not get_settings().receipts_worker_enabled:
        return None
    try:
        from receipts import worker
        from receipts.db.session import get_session_factory

        extraction_worker = worker.ExtractionWorker(get_session_factory())
        extraction_worker.start()
        worker.set_worker(extraction_worker)
        return extraction_worker
    except Exception:
        log.exception("receipts worker did not start")
        return None


def create_app(docs_enabled: bool | None = None) -> FastAPI:
    """`/docs`, `/redoc` and `/openapi.json` exist only with DOCS_ENABLED (dev)."""
    if docs_enabled is None:
        docs_enabled = get_core_settings().docs_enabled
    app = FastAPI(
        title="Receipts",
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if docs_enabled else None,
        redoc_url="/redoc" if docs_enabled else None,
        openapi_url="/openapi.json" if docs_enabled else None,
    )

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    include_receipts_routes(app)
    return app


app = create_app()
