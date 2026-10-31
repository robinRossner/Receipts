#!/bin/sh
# Backend for the iPhone simulator e2e run: the real FastAPI server from a TEMP var dir (dummy token, no Claude
# credentials, worker off; extraction is finished by `seed`, with the backend tests' scripted fake provider).
# Never touches backend/var or ~/Library/Application Support/ReceiptsApp. Needs `uv` and `cd backend && uv sync`.
#
#   Tests/ios-e2e/server.sh start     # prints URL and token, state in $STATE (default /tmp/receipts-ios-e2e.env)
#   Tests/ios-e2e/server.sh seed      # finish queued extractions (no Claude call)
#   Tests/ios-e2e/server.sh status    # receipts as the server sees them
#   Tests/ios-e2e/server.sh stop
set -eu
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND="$HERE/../../backend"
STATE="${RECEIPTS_IOS_E2E_STATE:-${TMPDIR:-/tmp}/receipts-ios-e2e.env}"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"

load() { [ -f "$STATE" ] || { echo "no state file $STATE: run start" >&2; exit 1; }; . "$STATE"; }

server_env() {
  export DATABASE_URL="sqlite:///$ROOT/var/fitness/fitness.db"
  export RECEIPTS_DATABASE_URL="sqlite:///$ROOT/var/receipts.db"
  export RECEIPTS_PHOTOS_DIR="$ROOT/var/receipts_photos"
  export RECEIPTS_API_TOKEN="$TOKEN" API_TOKEN="e2e-dummy-fitness-token"
  export RECEIPTS_WORKER_ENABLED=false SCHEDULER_ENABLED=false
  export ANTHROPIC_API_KEY="" CLAUDE_CODE_OAUTH_TOKEN="" NOTIFY_URL="" RECEIPTS_NOTIFY_URL=""
  export GARMIN_TOKEN_CACHE_PATH="$ROOT/var/fitness/garmin_token.json" GARMIN_CONNECT_TOKEN_DIR="$ROOT/var/fitness/garminconnect" GARMIN_FIT_DIR="$ROOT/var/fitness/fit"
}

case "${1:-}" in
  start)
    ROOT="$(mktemp -d "${TMPDIR:-/tmp}/receipts-ios-e2e.XXXXXX")"
    TOKEN="ios-e2e-dummy-token"; PORT="${PORT:-8787}"
    mkdir -p "$ROOT/var/fitness" "$ROOT/var/receipts_photos"
    printf 'ROOT=%s\nTOKEN=%s\nPORT=%s\n' "$ROOT" "$TOKEN" "$PORT" > "$STATE"
    server_env; cd "$BACKEND"
    uv run alembic -c apps/fitness/alembic.ini upgrade head >"$ROOT/alembic1.log" 2>&1
    uv run alembic -c apps/receipts/alembic.ini upgrade head >"$ROOT/alembic2.log" 2>&1
    nohup uv run uvicorn server:app --host 127.0.0.1 --port "$PORT" >"$ROOT/uvicorn.log" 2>&1 &
    echo $! > "$ROOT/pid"
    for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
    curl -fs "http://127.0.0.1:$PORT/health" >/dev/null || { echo "server did not start, see $ROOT/uvicorn.log" >&2; exit 1; }
    echo "url=http://localhost:$PORT token=$TOKEN root=$ROOT" ;;
  seed)
    load; server_env; cd "$BACKEND"; uv run python "$HERE/Tests/e2e/seed_extractions.py" ;;
  status)
    load; curl -fs -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/v1/receipts/sync/pull?since=" ;;
  stop)
    load
    pkill -f "uvicorn server:app --host 127.0.0.1 --port $PORT" || true
    [ -f "$ROOT/pid" ] && kill "$(cat "$ROOT/pid")" 2>/dev/null || true
    sleep 1; rm -rf "$ROOT" "$STATE"; echo stopped ;;
  *) echo "usage: $0 start|seed|status|stop" >&2; exit 2 ;;
esac
