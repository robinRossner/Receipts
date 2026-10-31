"""Scheduled jobs of the receipts app, registered through core/scheduler.py: one daily check that
finishes interrupted archive deletions and sends the archive / disk reminder (at most once every
few days, receipts/archive.py)."""

from __future__ import annotations

import logging

from apscheduler.schedulers.background import BackgroundScheduler

from core.scheduler import add_cron_job, hhmm
from receipts import archive, notify
from receipts.db.session import get_session_factory
from receipts.settings import ReceiptsSettings, get_settings

log = logging.getLogger(__name__)


def daily_job() -> None:
    """Never raises into the scheduler."""
    settings = get_settings()
    try:
        factory = get_session_factory()
        with factory() as db:
            swept = archive.sweep_archived(db, settings)
        if swept:
            log.info("receipts: finished %d interrupted archive deletion(s)", swept)
        outcome = archive.check_and_remind(factory, settings, notify.send)
        log.info("receipts daily check: reminder %s", outcome)
    except Exception:
        log.exception("receipts daily job failed")


def add_receipts_jobs(sched: BackgroundScheduler, settings: ReceiptsSettings) -> None:
    hour, minute = hhmm(settings.receipts_reminder_time)
    add_cron_job(
        sched,
        daily_job,
        job_id="receipts_daily",
        hour=hour,
        minute=minute,
        tz=settings.scheduler_tz,
        misfire_grace_time=6 * 3600,
    )
