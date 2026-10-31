#!/usr/bin/env bash
# Copy the Receipts bearer token (RECEIPTS_API_TOKEN) from backend/.env.production to the macOS
# clipboard without printing it, to paste it into the Mac / iPhone app (iPhone: Universal
# Clipboard, same Apple ID, Bluetooth + Wi-Fi on).
#   deploy/copy-token.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ROOT/backend/.env.production"
key=RECEIPTS_API_TOKEN

[[ -f "$ENVF" ]] || { echo "error: $ENVF not found; run deploy/make-prod-env.sh first" >&2; exit 1; }
command -v pbcopy >/dev/null || { echo "error: pbcopy not found (macOS only)" >&2; exit 1; }

token="$(grep -E "^(export[[:space:]]+)?$key=" "$ENVF" | tail -n1 | sed -E "s/^(export[[:space:]]+)?$key=//; s/^\"(.*)\"\$/\1/; s/^'(.*)'\$/\1/" || true)"
[[ -n "$token" ]] || { echo "error: no $key in $ENVF" >&2; exit 1; }

printf '%s' "$token" | pbcopy
echo "$key copied to clipboard (${#token} chars). Paste it into the app now;"
echo "clear the clipboard afterwards with:  printf '' | pbcopy"
