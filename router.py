"""Mounts the receipts API on the shared FastAPI app under `/api/v1/receipts`."""

from __future__ import annotations

from fastapi import FastAPI

from apps.receipts.api.router import router

RECEIPTS_PREFIX = "/api/v1"  # the router itself carries `/receipts`


def include_receipts_routes(app: FastAPI) -> None:
    app.include_router(router, prefix=RECEIPTS_PREFIX)
