#!/usr/bin/env bash
# Re-sign "AI Disk Keeper.app" with a Developer ID identity, hardened runtime and secure timestamp.
#
# scripts/sign-app.sh <path/to/App.app>
# Env: SIGN_IDENTITY (required), KEYCHAIN (optional keychain path),
#      ENTITLEMENTS (default Packaging/AIDiskKeeper.entitlements)
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1:-}" in -h|--help) sed -n '2,6p' "$0"; exit 0 ;; esac
[ $# -eq 1 ] || die "usage: sign-app.sh <App.app> (see -h)"
[ -d "${1%/}" ] || die "app bundle not found: ${1%/}"
APP="$(cd "${1%/}" && pwd)"
[ -n "${SIGN_IDENTITY:-}" ] || die "SIGN_IDENTITY is not set"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/Packaging/AIDiskKeeper.entitlements}"
[ -f "$ENTITLEMENTS" ] || die "entitlements file not found: $ENTITLEMENTS"

KC_ARGS=()
if [ -n "${KEYCHAIN:-}" ]; then KC_ARGS=(--keychain "$KEYCHAIN"); fi

INFO="$APP/Contents/Info.plist"
[ -f "$INFO" ] || die "Info.plist not found: $INFO"
EXE_NAME="$(plutil -extract CFBundleExecutable raw -o - "$INFO")" || die "cannot read CFBundleExecutable"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO")" || die "cannot read CFBundleIdentifier"
MAIN_EXE="$APP/Contents/MacOS/$EXE_NAME"
[ -n "$BUNDLE_ID" ] || die "could not read CFBundleIdentifier"

echo "==> Signing nested code (inside-out)"
while IFS= read -r -d '' f; do
  [ "$f" = "$MAIN_EXE" ] && continue
  if file -b "$f" | grep -q "Mach-O"; then
    echo "    $f"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$f" \
      || die "failed to sign $f"
  fi
done < <(find "$APP/Contents" -type f -perm +111 -print0)

echo "==> Signing bundle ($BUNDLE_ID)"
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" \
  --sign "$SIGN_IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$APP" \
  || die "failed to sign $APP"

echo "==> Verifying"
codesign --verify --strict --deep --verbose=2 "$APP" || die "signature verification failed"
codesign -d --entitlements - --xml "$APP" || true
echo "signed: $APP"
