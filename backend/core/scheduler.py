"""APScheduler plumbing for the job modules (receipts/jobs.py); the FastAPI lifespan starts the
scheduler only when SCHEDULER_ENABLED=true.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from typing import Any

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger


def hhmm(value: str) -> tuple[int, int]:
    """'19:45' -> (19, 45); a bare hour ('7') means :00."""
    hour, _, minute = value.strip().partition(":")
    return int(hour), int(minute or 0)


def add_cron_job(
    sched: BackgroundScheduler,
    func: Callable[..., Any],
    *,
    job_id: str,
    hour: int,
    minute: int,
    tz: str,
    misfire_grace_time: int,
    args: Sequence[Any] | None = None,
    day_of_week: str | None = None,
) -> None:
    """One cron job with the house defaults: a single running instance, missed runs coalesced,
    an existing job with the same id replaced."""
    sched.add_job(
        func,
        CronTrigger(day_of_week=day_of_week, hour=hour, minute=minute, timezone=tz),
        args=args,
        id=job_id,
        max_instances=1,
        coalesce=True,
        misfire_grace_time=misfire_grace_time,
        replace_existing=True,
    )
