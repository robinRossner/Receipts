#!/usr/bin/env bash
# Push the Receipts server from the Mac to the VM and (re)start it.
#
#   deploy/push.sh user@host [--with-env]
#
#   --with-env   upload backend/.env.production (mode 600). Required on the first push; make it
#                with deploy/make-prod-env.sh first.
#
# What it does: creates /opt/receipts (sudo, owned by the login user) if absent, rsyncs backend/
# and deploy/, installs the nightly backup cron (deploy/install-cron.sh), `docker compose up -d
# --build` and waits until /health answers inside the container. It never touches
# /opt/receipts/deploy/data (receipts.db, receipts_photos/) or deploy/backups.
#
# Env: SSH_OPTS="-i ~/.ssh/other_key" for extra ssh options.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DIR="${RECEIPTS_REMOTE_DIR:-/opt/receipts}"   # override only for tests
SERVICE=receipts-backend
LOCAL_ENV="$ROOT/backend/.env.production"

die()  { echo "error: $*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

# ---------- args ----------
HOST=""; WITH_ENV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-env) WITH_ENV=1 ;;
    -h|--help)  usage 0 ;;
    -*)         die "unknown option: $1 (see --help)" ;;
    *)          [[ -z "$HOST" ]] || die "unexpected argument: $1"; HOST="$1" ;;
  esac
  shift
done
[[ -n "$HOST" ]] || usage 1
[[ "$HOST" =~ ^[A-Za-z0-9._@:-]+$ && "$HOST" != -* ]] || die "invalid host: $HOST"

# ---------- local preflight ----------
command -v rsync >/dev/null || die "rsync not found"
command -v ssh   >/dev/null || die "ssh not found"
[[ -f "$ROOT/backend/Dockerfile" && -f "$ROOT/deploy/docker-compose.yml" ]] || die "run from the repo (backend/ and deploy/ missing)"
if [[ $WITH_ENV -eq 1 ]]; then
  [[ -f "$LOCAL_ENV" ]] || die "$LOCAL_ENV missing; run deploy/make-prod-env.sh first"
fi

WORK="$(mktemp -d)"
trap 'ssh -O exit -o ControlPath="$WORK/cm" "$HOST" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# One multiplexed ssh connection for all calls (one auth, fast).
SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=auto -o "ControlPath=$WORK/cm" -o ControlPersist=120)
# shellcheck disable=SC2206  # SSH_OPTS is intentionally word-split
[[ -n "${SSH_OPTS:-}" ]] && SSH_ARGS+=(${SSH_OPTS})
# shellcheck disable=SC2029  # client-side expansion of remote commands is intended
rssh() { ssh "${SSH_ARGS[@]}" "$HOST" "$@"; }
RSYNC_SSH="ssh ${SSH_ARGS[*]}"

# ---------- server preflight ----------
info "checking ssh + server setup ($HOST)"
rssh true 2>/dev/null || die "cannot ssh to $HOST (key auth, host reachable, port 22 open?)"
rssh "command -v docker >/dev/null && docker compose version >/dev/null 2>&1" \
  || die "docker / docker compose missing on the server (the VM must be set up already)"
rssh "docker info >/dev/null 2>&1" || die "ssh user cannot talk to docker (not in the docker group?)"
rssh "command -v sqlite3 >/dev/null && command -v rsync >/dev/null" \
  || warn "sqlite3 or rsync missing on the server: deploy/backup.sh needs both (apt install sqlite3 rsync)"

info "creating $REMOTE_DIR if needed (sudo, owned by the login user)"
rssh "bash -s -- $(printf '%q ' "$REMOTE_DIR")" <<'REMOTE'
set -euo pipefail
dir="$1"
if [ ! -d "$dir" ]; then
  sudo -n mkdir -p "$dir" || { echo "error: cannot create $dir (sudo -n failed): run 'sudo mkdir -p $dir && sudo chown $(id -un): $dir' once" >&2; exit 1; }
  sudo -n chown "$(id -u):$(id -g)" "$dir"
fi
[ -w "$dir" ] || { echo "error: $dir is not writable for $(id -un)" >&2; exit 1; }
mkdir -p "$dir/backend" "$dir/deploy/data" "$dir/deploy/backups"
REMOTE

# ---------- code ----------
info "rsync backend/"
rsync -az --delete --no-owner --no-group -e "$RSYNC_SSH" \
  --exclude='/.venv/' --exclude='/var/' --exclude='/.env' --exclude='/.env.*' \
  --exclude='__pycache__/' --exclude='.pytest_cache/' --exclude='.ruff_cache/' --exclude='.mypy_cache/' \
  --exclude='.DS_Store' --exclude='*.pyc' \
  "$ROOT/backend/" "$HOST:$REMOTE_DIR/backend/"

info "rsync deploy/ (data/ and backups/ are never touched)"
rsync -az --delete --no-owner --no-group -e "$RSYNC_SSH" \
  --exclude='/data/' --exclude='/backups/' --exclude='/.env' --exclude='.DS_Store' \
  "$ROOT/deploy/" "$HOST:$REMOTE_DIR/deploy/"

# ---------- env ----------
if [[ $WITH_ENV -eq 1 ]]; then
  info "uploading backend/.env.production (mode 600)"
  rsync -t --no-owner --no-group -e "$RSYNC_SSH" "$LOCAL_ENV" "$HOST:$REMOTE_DIR/backend/.env.production"
fi
rssh "test -s $REMOTE_DIR/backend/.env.production" \
  || die "no backend/.env.production on the server: run deploy/make-prod-env.sh, then push with --with-env"
rssh "chmod 600 $REMOTE_DIR/backend/.env.production"

info "writing deploy/.env on the server (APP_UID, APP_GID)"
rssh "bash -s -- $(printf '%q ' "$REMOTE_DIR/deploy/.env")" <<'REMOTE'
set -euo pipefail
f="$1"
touch "$f"; chmod 600 "$f"
setkey() {  # setkey KEY VALUE: replace or append (other keys, e.g. PROXY_NETWORK, are kept)
  grep -v "^$1=" "$f" > "$f.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$f.tmp"
  mv "$f.tmp" "$f"; chmod 600 "$f"
}
setkey APP_UID "$(id -u)"
setkey APP_GID "$(id -g)"
REMOTE

# The shared proxy network must exist (the Caddy stack creates it); fail early with a clear message.
NETWORK="$(rssh "sed -n 's/^PROXY_NETWORK=//p' $REMOTE_DIR/deploy/.env | tail -n1")"
NETWORK="${NETWORK:-deploy_default}"
rssh "docker network inspect $(printf '%q' "$NETWORK") >/dev/null 2>&1" \
  || die "docker network '$NETWORK' not found: start the Caddy stack on the VM first (docker network ls), or set PROXY_NETWORK in $REMOTE_DIR/deploy/.env"

# ---------- backup cron ----------
info "installing the nightly backup cron (03:45) if absent"
rssh "bash $REMOTE_DIR/deploy/install-cron.sh" || warn "could not install the backup cron (see deploy/README.md)"

# ---------- start ----------
info "docker compose up -d --build (first build on ARM takes a few minutes)"
rssh "cd $REMOTE_DIR/deploy && docker compose up -d --build" || die "docker compose up failed"

info "waiting for /health inside the container"
HEALTH_PY="import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).read().decode())"
healthy=0; body=""
for _ in $(seq 1 60); do
  if body="$(rssh "cd $REMOTE_DIR/deploy && docker compose exec -T $SERVICE python -c $(printf '%q' "$HEALTH_PY")" 2>/dev/null)"; then
    healthy=1; break
  fi
  sleep 3
done
if [[ $healthy -ne 1 ]]; then
  warn "backend did not answer /health within 3 min. Last logs:"
  rssh "cd $REMOTE_DIR/deploy && docker compose logs --tail=40 $SERVICE" >&2 || true
  exit 1
fi
echo "backend healthy: $body"

# Soft check: the alias the proxy uses is on this container in the shared network.
if rssh "cd $REMOTE_DIR/deploy && docker inspect -f '{{json .NetworkSettings.Networks}}' \$(docker compose ps -q $SERVICE)" 2>/dev/null | grep -q '"receipts-backend"'; then
  echo "network alias receipts-backend on $NETWORK: ok"
else
  warn "alias receipts-backend not found on network $NETWORK (docker inspect); the proxy would answer 502"
fi
info "done (the public route /api/v1/receipts/* is configured in the Caddy stack, see deploy/README.md)"
