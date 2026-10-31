#!/bin/sh
# The archive_overdue / disk_warning banners, on the iPhone (screenshots) and, with a data dir of its own, on the Mac.
# The backend runs with the thresholds forced (RECEIPTS_ARCHIVE_REMINDER_DAYS=0, RECEIPTS_DISK_WARNING_FREE_MB huge).
# usage: Tests/ios-e2e/banners.sh [shots_dir]
set -eu
cd "$(dirname "$0")/../.."
SHOTS="${1:-${TMPDIR:-/tmp}/receipts-ios-shots}"
T=Tests/ios-e2e
trap '$T/server.sh stop >/dev/null 2>&1 || true' EXIT
RECEIPTS_ARCHIVE_REMINDER_DAYS=0 RECEIPTS_DISK_WARNING_FREE_MB=999999999 $T/server.sh start
$T/uitest.sh testPhase1ConfigureAndUpload "$SHOTS"
$T/server.sh seed
$T/uitest.sh testBannersFromTheStatusEndpoint "$SHOTS"
$T/server.sh status | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['receipts']), 'receipts on the server')"
