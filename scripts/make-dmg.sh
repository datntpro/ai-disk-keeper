#!/usr/bin/env bash
# Build a compressed DMG containing the app and an /Applications symlink.
#
# scripts/make-dmg.sh <App.app> <out.dmg>
# Env: SIGN_IDENTITY (optional: sign the DMG), KEYCHAIN (optional keychain path)
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

case "${1:-}" in -h|--help) sed -n '2,5p' "$0"; exit 0 ;; esac
[ $# -eq 2 ] || die "usage: make-dmg.sh <App.app> <out.dmg> (see -h)"
APP="${1%/}"
OUT="$2"
[ -d "$APP" ] || die "app bundle not found: $APP"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/AI Disk Keeper"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $(basename "$OUT")"
for attempt in 1 2 3; do
  if hdiutil create -volname "AI Disk Keeper" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
       -imagekey zlib-level=9 -ov "$OUT" 2> "$WORK/err.txt"; then
    break
  fi
  if grep -qi "resource busy" "$WORK/err.txt" && [ "$attempt" -lt 3 ]; then
    echo "hdiutil: resource busy, retrying" >&2; sleep 5
  else
    cat "$WORK/err.txt" >&2; die "hdiutil create failed"
  fi
done

if [ -n "${SIGN_IDENTITY:-}" ]; then
  KC_ARGS=()
  if [ -n "${KEYCHAIN:-}" ]; then KC_ARGS=(--keychain "$KEYCHAIN"); fi
  echo "==> Signing DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$OUT" || die "DMG signing failed"
  codesign --verify --verbose=2 "$OUT" || die "DMG signature verification failed"
fi

hdiutil verify "$OUT" >/dev/null || die "hdiutil verify failed"
echo "dmg: $OUT"
