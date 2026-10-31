#!/usr/bin/env bash
# Nightly consistent SQLite snapshot of receipts.db (safe while the app runs in WAL mode) plus a
# mirror of the receipt photos that are not archived yet.
# Installed by deploy/install-cron.sh (push.sh runs it); manual equivalent (crontab -e):
#   45 3 * * * /opt/receipts/deploy/backup.sh >> /var/log/receipts-backup.log 2>&1
# Requires the sqlite3 and rsync CLIs on the host (apt install sqlite3 rsync).
#
# Receipt photos: the server keeps a photo only until the laptop has archived it (the archive
# confirmation deletes it). So data/receipts_photos holds exactly the photos that exist nowhere
# else but possibly on a phone. They are NOT copied day by day (that would grow without bound and
# would keep photos the laptop already archived): backups/receipts_photos_pending is ONE mirror,
# refreshed with rsync --delete, so it always equals the current set of unarchived photos, never
# resurrects an archived one and never needs more disk than the photos themselves.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${DB:-$DEPLOY_DIR/data/receipts.db}"
PHOTOS="${PHOTOS:-$DEPLOY_DIR/data/receipts_photos}"
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
KEEP_DAYS="${KEEP_DAYS:-30}"

[[ -f "$DB" ]] || { echo "$(date -Is) backup skipped: $DB not found" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
stamp="$(date +%Y%m%d_%H%M%S)"
out="$BACKUP_DIR/receipts_$stamp.db"

sqlite3 "$DB" ".backup '$out'"
sqlite3 "$out" "PRAGMA integrity_check;" | grep -qx ok
rm -f "$out-wal" "$out-shm"   # an integrity check on a WAL-mode copy can leave these behind
gzip "$out"
find "$BACKUP_DIR" -name 'receipts_*.db.gz' -mtime +"$KEEP_DAYS" -delete
echo "$(date -Is) backup ok: $out.gz"

# --- not-yet-archived receipt photos: one mirror, deletions follow the source
if [[ -d "$PHOTOS" ]]; then
  mirror="$BACKUP_DIR/receipts_photos_pending"
  need_kb="$(du -sk "$PHOTOS" | cut -f1)"
  mkdir -p "$mirror"
  have_kb="$(du -sk "$mirror" | cut -f1)"
  free_kb="$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
  # the mirror needs at most the photos' size; refuse (loudly) rather than fill the disk
  if (( free_kb + have_kb < need_kb * 2 )); then
    echo "$(date -Is) receipts photos mirror SKIPPED: not enough free disk (${free_kb} KB free," \
      "photos ${need_kb} KB)" >&2
    exit 1
  fi
  rsync -a --delete --exclude '.*.tmp' "$PHOTOS/" "$mirror/"
  echo "$(date -Is) receipts photos mirror ok: $(find "$mirror" -type f | wc -l | tr -d ' ') files," \
    "$(du -sh "$mirror" | cut -f1)"
fi
