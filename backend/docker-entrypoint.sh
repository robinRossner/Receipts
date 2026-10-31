#!/bin/sh
# Migrate receipts.db, then serve.
# Single worker on purpose: SQLite + in-process APScheduler + the extraction worker thread.
set -eu

mkdir -p /app/var/receipts_photos
alembic upgrade head
exec uvicorn server:app --host 0.0.0.0 --port 8000 --proxy-headers --forwarded-allow-ips='*' --workers 1
