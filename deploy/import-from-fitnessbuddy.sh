#!/usr/bin/env bash
# ONE-OFF, NON-DESTRUCTIVE: copy the receipts data that the old shared FitnessBuddy server holds
# (/opt/fitnessbuddy/deploy/data/receipts.db and receipts_photos/) into this server's own data
# directory (/opt/receipts/deploy/data). Run it from the Mac after `deploy/push.sh` created the
# Receipts stack.
#
#   deploy/import-from-fitnessbuddy.sh user@host [--dry-run] [--freeze-fitness]
#
#   --dry-run          check everything, print the counts of both sides, change nothing
#   --freeze-fitness   stop the FitnessBuddy backend container before the copy so that nothing is
#                      written to the old receipts data between the copy and the cut-over. The
#                      fitness API stays DOWN until FitnessBuddy's own deploy/push.sh runs next
#                      (it is restarted automatically only when this script fails). Without the
#                      flag the copy is still consistent (sqlite3 .backup), but receipts written to
#                      the old server after it are not carried over.
#
# What it does, in order:
#   1. snapshots the old receipts.db with `sqlite3 .backup` into a scratch file inside the new data
#      dir and integrity-checks it
#   2. REFUSES if the new receipts.db already holds receipts, unless its content is identical to the
#      snapshot (then the database step is skipped and only the photos are completed)
#   3. stops only the new receipts container (if it runs), puts the snapshot in place (an existing
#      empty receipts.db is moved aside, not deleted), integrity-checks it, starts the container
#      again if it ran
#   4. copies receipts_photos/ with rsync (never --delete, the source is only read) and verifies
#      every file by checksum
#   5. prints the counts of receipts, line items, dictionary entries and photo files of BOTH sides
# It deletes nothing. The old files stay where they are; removing them is a later, manual step
# (deploy/README.md, "Removing the old copy").
set -euo pipefail

remote_main() {
  set -euo pipefail
  # no `local`: the EXIT trap (cleanup) runs after this function has returned
  DRY=0; FREEZE=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY=1 ;;
      --freeze-fitness) FREEZE=1 ;;
      *) echo "error: unknown option: $arg" >&2; return 2 ;;
    esac
  done
  # paths: fixed on the server; overridable only for the local test (IMPORT_LOCAL=1)
  SRC_DEPLOY="${FB_DEPLOY:-/opt/fitnessbuddy/deploy}"
  DST_DEPLOY="${RC_DEPLOY:-/opt/receipts/deploy}"
  SRC_DIR="$SRC_DEPLOY/data"; DST_DIR="$DST_DEPLOY/data"
  SRC_DB="$SRC_DIR/receipts.db"; DST_DB="$DST_DIR/receipts.db"
  SRC_PHOTOS="$SRC_DIR/receipts_photos"; DST_PHOTOS="$DST_DIR/receipts_photos"
  RC_SERVICE=receipts-backend; FB_SERVICE=backend
  scratch=""; fb_stopped=0; rc_stopped=0; done_ok=0
  local ts live_receipts

  die()  { echo "error: $*" >&2; exit 1; }
  info() { printf '==> %s\n' "$*"; }
  sha()  { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
  # RO=-readonly only for the live source database (never create files next to it); every other
  # database is ours, and a normal open also recovers a WAL left behind by a stopped process.
  RO=""
  has_table() { [ "$(sqlite3 $RO "$1" "select count(*) from sqlite_master where type='table' and name='$2';" 2>/dev/null || echo 0)" = 1 ]; }
  count() {  # count DB TABLE [WHERE]: 0 when the table does not exist
    if has_table "$1" "$2"; then sqlite3 $RO "$1" "select count(*) from $2 ${3:-};"; else echo 0; fi
  }
  photo_files() { if [ -d "$1" ]; then find "$1" -type f ! -name '.*' | wc -l | tr -d ' '; else echo 0; fi; }
  report() {  # report LABEL DB PHOTOS [ro]
    local label="$1" db="$2" photos="$3"
    RO=""; [ "${4:-}" = ro ] && RO=-readonly
    if [ -f "$db" ]; then
      printf '  %-12s receipts %s (not deleted %s), line items %s, dictionary %s, photo files %s (receipts with photo on server: %s)\n' \
        "$label" "$(count "$db" receipts)" "$(count "$db" receipts 'where deleted_at is null')" \
        "$(count "$db" line_items)" "$(count "$db" item_dictionary)" "$(photo_files "$photos")" \
        "$(count "$db" receipts "where photo_location = 'server'")"
      RO=""
    else
      RO=""
      printf '  %-12s no database, photo files %s\n' "$label" "$(photo_files "$photos")"
    fi
  }
  dc() { ( cd "$1" && shift && docker compose "$@" </dev/null ); }
  running() { [ -n "$(dc "$1" ps -q "$2" 2>/dev/null || true)" ]; }
  cleanup() {
    local status=$?
    if [ "$done_ok" -ne 1 ] && [ "$status" -ne 0 ]; then
      [ "$fb_stopped" -eq 1 ] && { echo "restarting the stopped FitnessBuddy backend" >&2; dc "$SRC_DEPLOY" start "$FB_SERVICE" || true; }
      [ "$rc_stopped" -eq 1 ] && { echo "restarting the receipts backend" >&2; dc "$DST_DEPLOY" start "$RC_SERVICE" || true; }
    fi
    [ -z "${scratch:-}" ] || rm -rf "$scratch"
    return $status
  }
  trap cleanup EXIT

  # ---- preflight (read-only)
  command -v sqlite3 >/dev/null || die "sqlite3 missing on the server (apt install sqlite3)"
  command -v rsync   >/dev/null || die "rsync missing on the server (apt install rsync)"
  [ -f "$SRC_DB" ] || die "no source database at $SRC_DB: nothing to import"
  [ -d "$DST_DEPLOY" ] || die "$DST_DEPLOY missing: run deploy/push.sh first"
  case "$SRC_DB$DST_DIR" in *\'*) die "paths must not contain a single quote" ;; esac
  mkdir -p "$DST_DIR"

  info "before (nothing has been changed yet)"
  report "DESTINATION" "$DST_DB" "$DST_PHOTOS"

  # ---- freeze the old backend (optional)
  if [ "$FREEZE" -eq 1 ] && [ "$DRY" -eq 0 ]; then
    if running "$SRC_DEPLOY" "$FB_SERVICE"; then
      info "stopping the FitnessBuddy backend (--freeze-fitness)"
      dc "$SRC_DEPLOY" stop "$FB_SERVICE"
      fb_stopped=1
    else
      echo "FitnessBuddy backend is not running: nothing to freeze"
    fi
  fi

  # ---- 1. consistent snapshot of the source
  scratch="$(mktemp -d "$DST_DIR/.import.XXXXXX")"
  info "snapshot of the source database (sqlite3 .backup)"
  sqlite3 "$SRC_DB" ".backup '$scratch/source.db'"
  [ "$(sqlite3 "$scratch/source.db" 'PRAGMA integrity_check;')" = ok ] || die "the snapshot failed integrity_check; nothing was changed"
  [ "$(sqlite3 "$scratch/source.db" 'PRAGMA foreign_key_check;' | wc -l | tr -d ' ')" = 0 ] || die "the snapshot has foreign key violations; nothing was changed"
  has_table "$scratch/source.db" receipts || die "the source database has no receipts table (is it really a receipts.db?)"
  local snap_receipts snap_items snap_dict
  snap_receipts="$(count "$scratch/source.db" receipts)"
  snap_items="$(count "$scratch/source.db" line_items)"
  snap_dict="$(count "$scratch/source.db" item_dictionary)"
  report "SOURCE (snap)" "$scratch/source.db" "$SRC_PHOTOS"

  # ---- 2. destination check
  local db_step=1
  if [ -f "$DST_DB" ] && [ "$(count "$DST_DB" receipts)" -gt 0 ]; then
    if [ "$(sqlite3 "$DST_DB" .dump | sha)" = "$(sqlite3 "$scratch/source.db" .dump | sha)" ]; then
      echo "the destination database already holds exactly this data: database step skipped"
      db_step=0
    else
      die "the destination $DST_DB already holds receipts and differs from the source snapshot. Refusing to touch it.
If it is a leftover you want replaced, move it aside yourself (mv $DST_DB $DST_DB.old, plus -wal/-shm) and run this again."
    fi
  fi

  if [ "$DRY" -eq 1 ]; then
    info "dry run: would import $snap_receipts receipts, $snap_items line items, $snap_dict dictionary entries and the photos; nothing changed"
    done_ok=1
    return 0
  fi

  # ---- 3. put the database in place
  if [ "$db_step" -eq 1 ]; then
    if running "$DST_DEPLOY" "$RC_SERVICE"; then
      info "stopping the receipts backend while its database is replaced"
      dc "$DST_DEPLOY" stop "$RC_SERVICE"
      rc_stopped=1
    fi
    if [ -f "$DST_DB" ] || [ -e "$DST_DB-wal" ] || [ -e "$DST_DB-shm" ]; then
      ts="$(date +%Y%m%d_%H%M%S)"
      info "moving the existing (empty) destination database aside as receipts.db.before-import-$ts"
      [ -f "$DST_DB" ] && mv "$DST_DB" "$DST_DB.before-import-$ts"
      [ -e "$DST_DB-wal" ] && mv "$DST_DB-wal" "$DST_DB-wal.before-import-$ts"
      [ -e "$DST_DB-shm" ] && mv "$DST_DB-shm" "$DST_DB-shm.before-import-$ts"
    fi
    mv "$scratch/source.db" "$DST_DB"
    [ "$(sqlite3 "$DST_DB" 'PRAGMA integrity_check;')" = ok ] || die "the new $DST_DB failed integrity_check (the old one, if any, is at $DST_DB.before-import-*)"
    [ "$(count "$DST_DB" receipts)" = "$snap_receipts" ] || die "receipt count after the copy differs from the snapshot"
    info "database in place, integrity ok"
  fi

  # ---- 4. photos (copy only; the source is never modified)
  if [ -d "$SRC_PHOTOS" ]; then
    mkdir -p "$DST_PHOTOS"
    info "copying receipt photos (rsync, no --delete)"
    rsync -a --ignore-existing --exclude '.*.tmp' "$SRC_PHOTOS/" "$DST_PHOTOS/"
    local diff
    diff="$(rsync -a -n -i --checksum --exclude '.*.tmp' "$SRC_PHOTOS/" "$DST_PHOTOS/")"
    if [ -n "$diff" ]; then
      printf '%s\n' "$diff" | head -n 10 >&2
      die "photo verification found differences (above): the source changed during the copy? Run again (the photo copy is incremental)."
    fi
    echo "photos verified by checksum: every source file is in the destination, identical"
  else
    echo "no $SRC_PHOTOS: no photos to copy"
    mkdir -p "$DST_PHOTOS"
  fi

  # ---- start again what we stopped
  if [ "$rc_stopped" -eq 1 ]; then
    info "starting the receipts backend again"
    dc "$DST_DEPLOY" start "$RC_SERVICE"
    rc_stopped=0
  fi
  done_ok=1

  # ---- 5. counts of both sides
  info "result"
  report "SOURCE (live)" "$SRC_DB" "$SRC_PHOTOS" ro
  report "DESTINATION" "$DST_DB" "$DST_PHOTOS"
  if [ "$(count "$DST_DB" receipts)" = "$snap_receipts" ] && [ "$(count "$DST_DB" line_items)" = "$snap_items" ] \
     && [ "$(count "$DST_DB" item_dictionary)" = "$snap_dict" ]; then
    echo "destination equals the snapshot taken from the source: OK"
  else
    echo "WARNING: destination counts differ from the snapshot" >&2
    return 1
  fi
  RO=-readonly
  live_receipts="$(count "$SRC_DB" receipts)"
  RO=""
  if [ "$live_receipts" != "$snap_receipts" ]; then
    echo "note: the live source changed after the snapshot (receipts were written meanwhile); rerun with --freeze-fitness for a lossless cut-over" >&2
  fi
  [ "$fb_stopped" -eq 1 ] && echo "NOTE: the FitnessBuddy backend is stopped; run FitnessBuddy's deploy/push.sh now (it starts it again)."
  echo "Nothing was deleted: the old files are still in $SRC_DIR (see deploy/README.md, \"Removing the old copy\")."
  return 0
}

if [[ "${IMPORT_LOCAL:-}" == 1 ]]; then   # test hook: run on this machine, paths from FB_DEPLOY / RC_DEPLOY
  remote_main "$@"
  exit $?
fi

HOST="${1:-}"
[[ -n "$HOST" && "$HOST" =~ ^[A-Za-z0-9._@:-]+$ && "$HOST" != -* ]] \
  || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
shift
for a in "$@"; do
  [[ "$a" == --dry-run || "$a" == --freeze-fitness ]] || { echo "error: unknown option: $a" >&2; exit 1; }
done

# the function is shipped to the server as text and run there
# shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
{ declare -f remote_main; echo 'remote_main "$@"'; } \
  | ssh -o BatchMode=yes -o ConnectTimeout=15 ${SSH_OPTS:-} "$HOST" bash -s -- "$@"
