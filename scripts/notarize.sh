#!/usr/bin/env bash
# Submit a .zip or .dmg to Apple's notary service and wait for the verdict.
#
# scripts/notarize.sh <file.zip|file.dmg>
# Auth (first match wins):
#   NOTARY_KEYCHAIN_PROFILE                      (xcrun notarytool store-credentials profile)
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER   (App Store Connect API key)
#   NOTARY_APPLE_ID + NOTARY_APP_PASSWORD + NOTARY_TEAM_ID
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

case "${1:-}" in -h|--help) sed -n '2,8p' "$0"; exit 0 ;; esac
[ $# -eq 1 ] || die "usage: notarize.sh <file.zip|file.dmg> (see -h)"
FILE="$1"
[ -f "$FILE" ] || die "file not found: $FILE"

AUTH=()
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ]; then
  [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ] || die "NOTARY_KEY_ID and NOTARY_ISSUER are required with NOTARY_KEY_PATH"
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
  [ -n "${NOTARY_APP_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] || die "NOTARY_APP_PASSWORD and NOTARY_TEAM_ID are required with NOTARY_APPLE_ID"
  AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_APP_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
  die "no notary credentials (set NOTARY_KEY_PATH/..., NOTARY_APPLE_ID/..., or NOTARY_KEYCHAIN_PROFILE)"
fi

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK="$(mktemp -d "$TMP/notary.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
JSON="$WORK/notary.json"

ID=""
for attempt in 1 2 3; do
  echo "==> Submitting $(basename "$FILE") (attempt $attempt/3)"
  rc=0
  xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 30m --output-format json > "$JSON" || rc=$?
  ID="$(plutil -extract id raw -o - "$JSON" 2>/dev/null || true)"
  # Only retry when the submission never got an id (network-level failure).
  if [ -n "$ID" ] || [ "$attempt" = 3 ]; then break; fi
  echo "submit failed (exit $rc, no submission id); retrying in 30s" >&2
  sleep 30
done
[ -n "$ID" ] || die "notarization submit failed (no submission id)"

STATUS="$(plutil -extract status raw -o - "$JSON" 2>/dev/null || echo unknown)"
echo "submission $ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  echo "==> Notary log" >&2
  xcrun notarytool log "$ID" "${AUTH[@]}" "$WORK/notary-log.json" >&2 || true
  [ -f "$WORK/notary-log.json" ] && cat "$WORK/notary-log.json" >&2
  die "notarization not accepted (status: $STATUS)"
fi
echo "notarized: $FILE"
