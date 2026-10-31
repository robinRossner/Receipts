#!/usr/bin/env bash
# Offsite copy of the Receipts database to this Mac (run by launchd, see deploy/README.md).
# Takes a fresh snapshot on the server with backup.sh, downloads it, verifies it locally and
# mirrors the not-yet-archived receipt photos (a mirror that follows deletions: it never holds a
# photo the laptop archive already confirmed). Runs at most once per MIN_AGE_DAYS, so launchd can
# call it daily and at login: whenever the Mac is on, the copy is never more than about a week old.
#   bash deploy/pull-backup.sh            # weekly check (skips if a recent copy exists)
#   bash deploy/pull-backup.sh --force    # copy now
set -euo pipefail

HOST="${RECEIPTS_BACKUP_HOST:-user@your-server}"
REMOTE_DIR="${RECEIPTS_REMOTE_DIR:-/opt/receipts/deploy}"
DEST="${RECEIPTS_BACKUP_DEST:-$HOME/Backups/Receipts}"
KEEP="${RECEIPTS_BACKUP_KEEP:-12}"            # weekly copies to keep
MIN_AGE_DAYS="${RECEIPTS_BACKUP_MIN_AGE_DAYS:-7}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20)

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }
notify() { osascript -e "display notification \"$1\" with title \"Receipts backup\"" >/dev/null 2>&1 || true; }
fail() { log "FAILED: $*"; notify "Backup failed: $*"; exit 1; }

mkdir -p "$DEST/db" "$DEST/receipts_photos_pending"

if [[ "${1:-}" != "--force" ]]; then
  newest="$(find "$DEST/db" -name 'receipts_*.db.gz' -mtime -"$MIN_AGE_DAYS" | head -1)"
  if [[ -n "$newest" ]]; then
    log "skip: recent copy exists ($(basename "$newest"))"
    exit 0
  fi
fi

# Fresh, integrity-checked snapshot on the server; backup.sh prints "... backup ok: <path>".
out="$("${SSH[@]}" "$HOST" "$REMOTE_DIR/backup.sh" 2>&1)" || fail "server snapshot ($out)"
remote_file="$(sed -n 's/.*backup ok: //p' <<<"$out" | tail -1)"
[[ -n "$remote_file" ]] || fail "could not read snapshot path from server output"

local_file="$DEST/db/$(basename "$remote_file")"
scp -q -o BatchMode=yes "$HOST:$remote_file" "$local_file.part" || fail "download"
mv "$local_file.part" "$local_file"

# Verify the copy: gzip stream, SQLite integrity and that the history is there.
tmp="$(mktemp -t rcheck)"
trap 'rm -f "$tmp"' EXIT
gunzip -c "$local_file" > "$tmp" || fail "gzip check"
[[ "$(sqlite3 "$tmp" 'PRAGMA integrity_check;')" == "ok" ]] || fail "integrity check"
counts="$(sqlite3 "$tmp" "select (select count(*) from receipts) || ' receipts, ' || (select count(*) from receipts where photo_location = 'server') || ' photos on the server';")"

# The pending photos (one mirror on the server, refreshed by backup.sh).
rsync -a --delete -e "ssh -o BatchMode=yes" "$HOST:$REMOTE_DIR/backups/receipts_photos_pending/" \
  "$DEST/receipts_photos_pending/" || log "warning: receipts photo mirror failed"

# Keep the newest $KEEP copies.
ls -1t "$DEST"/db/receipts_*.db.gz | tail -n +"$((KEEP + 1))" | while read -r old; do rm -f "$old"; done

log "ok: $(basename "$local_file") ($(du -h "$local_file" | cut -f1)), $counts"
notify "Saved $(basename "$local_file"): $counts"
