#!/bin/sh
# The whole iPhone simulator e2e run, as used for the release check:
#   backend from a temp var dir (dummy token, no Claude credentials) -> simulator: set up, add photos -> fake
#   extraction (`seed`) -> edit + confirm on the phone -> verify on the server -> the Mac engine archives the photos ->
#   phone clears its cached photos and shows "on your laptop" -> screen tour in light and dark mode. Stops the server.
# usage: Tests/ios-e2e/run.sh [shots_dir]
set -eu
cd "$(dirname "$0")/../.."
SHOTS="${1:-${TMPDIR:-/tmp}/receipts-ios-shots}"
SAMPLES="$(mktemp -d "${TMPDIR:-/tmp}/receipts-samples.XXXXXX")"
T=Tests/ios-e2e
trap '$T/server.sh stop >/dev/null 2>&1 || true; xcrun simctl ui booted appearance light >/dev/null 2>&1 || true' EXIT

swift Tests/e2e/make_sample_receipts.swift "$SAMPLES" >/dev/null
sips -s format heic "$SAMPLES/receipt-2.jpg" --out "$SAMPLES/receipt-2.heic" >/dev/null
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcrun simctl bootstatus "iPhone 17 Pro" -b >/dev/null
xcrun simctl uninstall booted com.robinrossner.receipts 2>/dev/null || true   # fresh install: no settings, no data
xcrun simctl ui booted appearance light
xcrun simctl addmedia booted "$SAMPLES/receipt-2.heic" "$SAMPLES/receipt-1.jpg"   # picker order: newest first

$T/server.sh start
. "${RECEIPTS_IOS_E2E_STATE:-${TMPDIR:-/tmp}/receipts-ios-e2e.env}"
$T/uitest.sh testPhase1ConfigureAndUpload "$SHOTS"
$T/server.sh seed
$T/uitest.sh testPhase2ReviewEditConfirm "$SHOTS"
$T/server.sh status | python3 $T/verify.py edited
RECEIPTS_ARCHIVE_HELPER_URL="http://127.0.0.1:$PORT" RECEIPTS_ARCHIVE_HELPER_TOKEN="$TOKEN" swift test --filter ArchiveHelperTests 2>&1 | grep -E "ARCHIVE-HELPER|error|failed" || true
$T/server.sh status | python3 $T/verify.py archived
$T/uitest.sh testPhase3PhotoOnTheLaptop "$SHOTS"
$T/uitest.sh testScreenTour "$SHOTS"
# the simulator only picks up a new appearance reliably after a restart (app data survives it)
xcrun simctl shutdown booted; xcrun simctl boot "iPhone 17 Pro"; xcrun simctl bootstatus "iPhone 17 Pro" -b >/dev/null
xcrun simctl ui booted appearance dark; sleep 3
$T/uitest.sh testScreenTour "$SHOTS" -dark
echo "e2e run finished; screenshots in $SHOTS"
