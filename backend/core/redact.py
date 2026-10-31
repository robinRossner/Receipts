"""Keep secrets out of logs and exception text.

`install_log_redaction()` wraps the log record factory so *every* record (any logger, any
handler) is scrubbed: `Authorization`-style values, `Bearer`/`ApiKey` tokens, JWTs and any
secret registered with `register_secret()` (the API key itself, once loaded).
"""

from __future__ import annotations

import logging
import re

_PATTERNS = [
    re.compile(r"(?i)\b(Bearer|ApiKey|Basic)\s+[A-Za-z0-9._~+/=-]{6,}"),
    re.compile(
        r"(?i)(authorization['\"]?\s*[:=]\s*['\"]?)(?:(?:Bearer|ApiKey|Basic)\s+)?[^\s'\",}]+"
    ),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"),  # JWT
    re.compile(r"\bsk-ant-[A-Za-z0-9_-]{6,}"),  # Anthropic API keys (also admin / oauth ones)
]
_secrets: set[str] = set()
_installed = False


def register_secret(value: str | None) -> None:
    if value and len(value) >= 8:
        _secrets.add(value)


def redact(text: str) -> str:
    for secret in _secrets:
        text = text.replace(secret, "***")
    text = _PATTERNS[1].sub(lambda m: f"{m.group(1)}***", text)
    text = _PATTERNS[0].sub(lambda m: f"{m.group(1)} ***", text)
    text = _PATTERNS[2].sub("***", text)
    return _PATTERNS[3].sub("***", text)


class RedactingFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = redact(record.getMessage())
        record.args = None
        return True


def install_log_redaction() -> None:
    """Idempotent. Scrub all log records process-wide."""
    global _installed
    if _installed:
        return
    old_factory = logging.getLogRecordFactory()

    def factory(*args, **kwargs):  # type: ignore[no-untyped-def]
        record = old_factory(*args, **kwargs)
        RedactingFilter().filter(record)
        return record

    logging.setLogRecordFactory(factory)
    _installed = True
