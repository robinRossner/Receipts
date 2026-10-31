#!/bin/sh
# End-to-end test: the Swift sync engine against the real backend (uvicorn from a temp var dir, dummy token, no
# Claude credentials, fake extraction) with a temp app data directory. Never touches
# ~/Library/Application Support/ReceiptsApp or backend/var. Needs `uv` and a synced backend venv (`uv sync` in backend/).
# The server code is this repo's backend/; RECEIPTS_BACKEND_DIR points the test at another copy.
set -eu
cd "$(dirname "$0")/.."
RECEIPTS_BACKEND_DIR="${RECEIPTS_BACKEND_DIR:-$PWD/backend}"
if [ ! -d "$RECEIPTS_BACKEND_DIR/receipts" ]; then
  echo "error: server code not found at $RECEIPTS_BACKEND_DIR (expected a receipts package inside)." >&2
  echo "It is this repo's backend/; set RECEIPTS_BACKEND_DIR only to use another copy." >&2
  exit 1
fi
export RECEIPTS_BACKEND_DIR
RECEIPTS_E2E=1 exec swift test --filter E2ETests "$@"
