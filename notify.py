"""Delivering a reminder to the operator.

`apps/fitness/notify/` is an empty stub and the backend has no push / e-mail channel, so the only
delivery implemented here is optional and needs one setting: RECEIPTS_NOTIFY_URL, an ntfy.sh-style
endpoint (the body is the message, the `Title` header the title) that the ntfy phone app shows as
a push. Unset (the default) there is no way to reach the operator from the server: `send` returns False,
the reminder is logged, and the `archive_overdue` / `disk_warning` fields of the status endpoint
are the signal clients show.
"""

from __future__ import annotations

import logging

import httpx

from apps.receipts.settings import get_settings
from core.redact import redact

log = logging.getLogger(__name__)


def send(title: str, message: str) -> bool:
    url = get_settings().receipts_notify_url
    if not url:
        return False
    try:
        resp = httpx.post(
            url,
            content=message.encode(),
            headers={"Title": title, "Priority": "high"},
            timeout=15.0,
        )
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        log.warning("receipts notification failed: %s", redact(str(exc)))
        return False
    return True
