#!/usr/bin/env bash
# Create backend/.env.production (mode 600) and apply the production overrides.
#
#   deploy/make-prod-env.sh [--import-from OTHER_ENV_FILE]
#
# Sources, in this order of precedence:
#   backend/.env          optional; every key in it is copied (except the keys this script owns)
#   backend/.env.production (existing)  keys that exist ONLY here (e.g. CLAUDE_CODE_OAUTH_TOKEN set
#                         by hand on the server side) are kept: a re-run never drops a key
#   --import-from FILE    first setup only: take values from another env file so the installed apps
#                         keep working. ONLY these are imported, and only when not already known:
#                         RECEIPTS_API_TOKEN, CLAUDE_CODE_OAUTH_TOKEN and RECEIPTS_* settings
#                         (RECEIPTS_DATABASE_URL / RECEIPTS_PHOTOS_DIR excepted: docker-compose.yml
#                         fixes those). Nothing else in FILE is read into the output.
#
# RECEIPTS_API_TOKEN is kept if .env.production already has one, else imported, else generated.
# Prints key NAMES only, never values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/backend/.env"
DST="$ROOT/backend/.env.production"
IMPORT=""

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --import-from)   [[ $# -ge 2 ]] || { echo "error: --import-from needs a file" >&2; exit 1; }
                     IMPORT="$2"; shift ;;
    --import-from=*) IMPORT="${1#--import-from=}" ;;
    -h|--help)       usage 0 ;;
    *)               echo "error: unknown argument: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

command -v openssl >/dev/null || { echo "error: openssl not found" >&2; exit 1; }
if [[ -n "$IMPORT" ]]; then
  [[ -f "$IMPORT" && -r "$IMPORT" ]] || { echo "error: --import-from file not readable: $IMPORT" >&2; exit 1; }
  [[ "$(cd "$(dirname "$IMPORT")" && pwd)/$(basename "$IMPORT")" != "$DST" ]] \
    || { echo "error: --import-from must not be $DST itself" >&2; exit 1; }
fi

# Keys this script owns (removed from the copy, then appended with the production value).
OVERRIDE_KEYS="RECEIPTS_API_TOKEN DOCS_ENABLED SCHEDULER_ENABLED"
# Never imported: the compose file sets them for the container.
NO_IMPORT_KEYS="RECEIPTS_DATABASE_URL RECEIPTS_PHOTOS_DIR"

KEY_RE='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*='

# value_in FILE KEY: last assignment of KEY in FILE (quotes stripped); empty if absent.
value_in() {
  [[ -f "$1" ]] || return 0
  grep -E "^(export[[:space:]]+)?$2[[:space:]]*=" "$1" | tail -n1 \
    | sed -E "s/^(export[[:space:]]+)?$2[[:space:]]*=//; s/^\"(.*)\"\$/\1/; s/^'(.*)'\$/\1/" || true
}
# has_key FILE KEY
has_key() { [[ -f "$1" ]] && grep -Eq "^(export[[:space:]]+)?$2[[:space:]]*=" "$1"; }
# line_of FILE KEY: the last assignment line as written (without a leading `export `).
line_of() { grep -E "^(export[[:space:]]+)?$2[[:space:]]*=" "$1" | tail -n1 | sed -E 's/^export[[:space:]]+//'; }
is_owned() { [[ " $OVERRIDE_KEYS " == *" $1 "* ]]; }
no_import() { [[ " $NO_IMPORT_KEYS " == *" $1 "* ]]; }

# Keep the existing token (the apps are logged in with it), else take the imported one, else new.
token="$(value_in "$DST" RECEIPTS_API_TOKEN)"
token_from=kept
if [[ -z "$token" && -n "$IMPORT" ]]; then
  token="$(value_in "$IMPORT" RECEIPTS_API_TOKEN)"
  token_from=imported
fi
if [[ -z "$token" ]]; then
  token="$(openssl rand -hex 32)"
  token_from="newly generated"
fi

umask 077
tmp="$(mktemp "$ROOT/backend/.env.production.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

copied=()
kept_prod=()
imported=()

# 1) everything from backend/.env except the owned keys
if [[ -f "$SRC" ]]; then
  pattern="^(export[[:space:]]+)?($(echo "$OVERRIDE_KEYS" | tr ' ' '|'))[[:space:]]*="
  grep -Ev "$pattern" "$SRC" > "$tmp" || true
  # make sure the copy ends with a newline before appending
  [[ ! -s "$tmp" || -z "$(tail -c1 "$tmp")" ]] || echo >> "$tmp"
  while IFS= read -r line; do
    [[ "$line" =~ $KEY_RE ]] && copied+=("${BASH_REMATCH[2]}")
  done < "$tmp"
fi

# 2) keys set only in the existing .env.production must survive a re-run
if [[ -f "$DST" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ $KEY_RE ]] || continue
    key="${BASH_REMATCH[2]}"
    is_owned "$key" && continue
    has_key "$SRC" "$key" && continue
    # the last assignment only, written once
    [[ " ${kept_prod[*]:-} " == *" $key "* ]] && continue
    line_of "$DST" "$key" >> "$tmp"
    kept_prod+=("$key")
  done < "$DST"
fi

# 3) --import-from: only the credentials and RECEIPTS_* settings, only if still unknown
if [[ -n "$IMPORT" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ $KEY_RE ]] || continue
    key="${BASH_REMATCH[2]}"
    case "$key" in
      CLAUDE_CODE_OAUTH_TOKEN|RECEIPTS_*) ;;
      *) continue ;;
    esac
    is_owned "$key" && continue
    no_import "$key" && continue
    has_key "$SRC" "$key" && continue
    has_key "$DST" "$key" && continue
    [[ " ${imported[*]:-} " == *" $key "* ]] && continue
    line_of "$IMPORT" "$key" >> "$tmp"
    imported+=("$key")
  done < "$IMPORT"
fi

{
  echo "# --- production overrides (deploy/make-prod-env.sh) ---"
  echo "RECEIPTS_API_TOKEN=$token"
  echo "DOCS_ENABLED=false"
  echo "SCHEDULER_ENABLED=true"
} >> "$tmp"

chmod 600 "$tmp"
mv -f "$tmp" "$DST"
trap - EXIT
chmod 600 "$DST"

echo "wrote backend/.env.production (mode 600)"
echo "keys set/overridden:"
for k in $OVERRIDE_KEYS; do echo "  $k"; done
echo "RECEIPTS_API_TOKEN: $token_from"
if [[ ${#copied[@]} -gt 0 ]]; then
  echo "other keys copied from backend/.env:"
  printf '  %s\n' "${copied[@]}"
fi
if [[ ${#kept_prod[@]} -gt 0 ]]; then
  echo "production-only keys kept from the existing .env.production:"
  printf '  %s\n' "${kept_prod[@]}"
fi
if [[ ${#imported[@]} -gt 0 ]]; then
  echo "keys imported from the --import-from file:"
  printf '  %s\n' "${imported[@]}"
fi
if ! has_key "$DST" CLAUDE_CODE_OAUTH_TOKEN && ! has_key "$DST" ANTHROPIC_API_KEY; then
  echo "note: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set: uploads are stored but" \
       "extraction waits (jobs stay queued) until one is added" >&2
fi
