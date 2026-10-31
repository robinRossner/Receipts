"""API errors of the receipts app: `{"detail": {"code": "...", "message": "..."}}` plus optional
extra fields, so clients can branch on `code` (documented in docs/api/receipts.md)."""

from __future__ import annotations

from typing import Any

from fastapi import HTTPException


def api_error(status: int, code: str, message: str, **extra: Any) -> HTTPException:
    return HTTPException(status, {"code": code, "message": message, **extra})
