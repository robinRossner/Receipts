#!/bin/sh
# Runs one phase (a test method of E2EFlowTests) on the iPhone 17 Pro simulator against the e2e backend.
# usage: Tests/ios-e2e/uitest.sh <TestMethod> [shots_dir] [suffix]
set -eu
cd "$(dirname "$0")/../.."
STATE="${RECEIPTS_IOS_E2E_STATE:-${TMPDIR:-/tmp}/receipts-ios-e2e.env}"; . "$STATE"
DD="${DERIVED_DATA:-${TMPDIR:-/tmp}/receipts-ios-dd}"
export TEST_RUNNER_E2E_URL="http://localhost:$PORT" TEST_RUNNER_E2E_TOKEN="$TOKEN"
export TEST_RUNNER_E2E_SHOTS="${2:-${TMPDIR:-/tmp}/receipts-ios-shots}" TEST_RUNNER_E2E_SUFFIX="${3:-}"
xcodebuild test -project Receipts.xcodeproj -scheme ReceiptsiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath "$DD" -only-testing:"ReceiptsiOSUITests/E2EFlowTests/$1" 2>&1 | grep -E "error:|Test Case|BUILD|TEST |failed" | sort -u
