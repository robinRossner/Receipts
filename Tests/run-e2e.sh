#!/bin/sh
# End-to-end test: the Swift sync engine against the real backend (uvicorn from a temp var dir, dummy token, no
# Claude credentials, fake extraction) with a temp app data directory. Never touches
# ~/Library/Application Support/ReceiptsApp or backend/var. Needs `uv` and a synced backend venv.
# The server code is in the FitnessBuddy repo: RECEIPTS_BACKEND_DIR (default ~/Projects/FitnessBuddy/backend).
set -eu
cd "$(dirname "$0")/.."
RECEIPTS_BACKEND_DIR="${RECEIPTS_BACKEND_DIR:-$HOME/Projects/FitnessBuddy/backend}"
if [ ! -d "$RECEIPTS_BACKEND_DIR/apps/receipts" ]; then
  echo "error: server code not found at $RECEIPTS_BACKEND_DIR (expected apps/receipts inside)." >&2
  echo "It lives in the FitnessBuddy repo: set RECEIPTS_BACKEND_DIR=/path/to/FitnessBuddy/backend" >&2
  exit 1
fi
export RECEIPTS_BACKEND_DIR
RECEIPTS_E2E=1 exec swift test --filter E2ETests "$@"
