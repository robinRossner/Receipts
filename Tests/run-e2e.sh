#!/bin/sh
# End-to-end test: the Swift sync engine against the real backend (uvicorn from a temp var dir, dummy token, no
# Claude credentials, fake extraction) with a temp app data directory. Never touches
# ~/Library/Application Support/ReceiptsApp or backend/var. Needs `uv` and a synced backend venv.
set -eu
cd "$(dirname "$0")/.."
RECEIPTS_E2E=1 exec swift test --filter E2ETests "$@"
