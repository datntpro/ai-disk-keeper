#!/usr/bin/env bash
# Build "AI Disk Keeper.app" from the SwiftPM package.
#
# scripts/make-app.sh [--config release|debug] [--universal] [--output DIR] [--zip] [--no-sign] [--skip-verify]
#   --config      default release
#   --universal   build arm64 + x86_64 (requires full Xcode); default: host arch only
#   --output      default <repo>/dist
#   --zip         also produce "<output>/AI-Disk-Keeper-<version>.zip" (ditto, keeps parent)
# Env overrides: BUNDLE_ID (default io.github.datntpro.aidiskkeeper), VERSION, BUILD_NUMBER
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG=release
UNIVERSAL=0
OUTPUT="$ROOT/dist"
ZIP=0
SIGN=1
VERIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || die "--config needs a value"; CONFIG="$2"; shift 2 ;;
    --universal) UNIVERSAL=1; shift ;;
    --output) [ $# -ge 2 ] || die "--output needs a value"; OUTPUT="$2"; shift 2 ;;
    --zip) ZIP=1; shift ;;
    --no-sign) SIGN=0; shift ;;
    --skip-verify) VERIFY=0; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$CONFIG" in release|debug) ;; *) die "--config must be release or debug" ;; esac

mkdir -p "$OUTPUT" || die "cannot create output dir $OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

BUNDLE_ID="${BUNDLE_ID:-io.github.datntpro.aidiskkeeper}"
VERSION="${VERSION:-$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' Sources/DiskKeeperCore/DiskKeeperCore.swift | head -1)}"
[ -n "$VERSION" ] || die "could not determine version from DiskKeeperCore.swift"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

ARCH_ARGS=()
if [ "$UNIVERSAL" = 1 ]; then ARCH_ARGS=(--arch arm64 --arch x86_64); fi

echo "==> Building ($CONFIG, universal=$UNIVERSAL)"
if ! swift build -c "$CONFIG" --product AIDiskKeeper ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}; then
  [ "$UNIVERSAL" = 1 ] && echo "hint: --universal requires full Xcode (not just Command Line Tools)" >&2
  die "swift build failed"
fi
BIN="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"
[ -x "$BIN/AIDiskKeeper" ] || die "executable not found at $BIN/AIDiskKeeper"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/AI Disk Keeper.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

echo "==> Assembling app bundle"
cp "$BIN/AIDiskKeeper" "$STAGE/Contents/MacOS/AIDiskKeeper"
found_core=0
found_ui=0
for b in "$BIN"/*.bundle; do
  [ -d "$b" ] || continue
  ditto "$b" "$STAGE/Contents/Resources/$(basename "$b")"
  if [ "$(basename "$b")" = "AIDiskKeeper_DiskKeeperCore.bundle" ]; then found_core=1; fi
  if [ "$(basename "$b")" = "AIDiskKeeper_AIDiskKeeperUI.bundle" ]; then found_ui=1; fi
done
[ "$found_core" = 1 ] || die "AIDiskKeeper_DiskKeeperCore.bundle not found in $BIN"
[ "$found_ui" = 1 ] || die "AIDiskKeeper_AIDiskKeeperUI.bundle not found in $BIN (is Xcode selected? xcstringstool ships only with Xcode)"
[ -d "$STAGE/Contents/Resources/AIDiskKeeper_AIDiskKeeperUI.bundle/Contents/Resources/vi.lproj" ] \
  || [ -d "$STAGE/Contents/Resources/AIDiskKeeper_AIDiskKeeperUI.bundle/vi.lproj" ] \
  || die "UI bundle has no vi.lproj (Vietnamese localization missing)"

# Escape sed-replacement specials (& \ |) and XML specials (& < >) in values.
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | sed -e 's/[&|\\]/\\&/g'; }
sed -e "s|__BUNDLE_ID__|$(esc "$BUNDLE_ID")|g" \
    -e "s|__VERSION__|$(esc "$VERSION")|g" \
    -e "s|__BUILD__|$(esc "$BUILD_NUMBER")|g" \
    Packaging/Info.plist > "$STAGE/Contents/Info.plist"
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null || die "generated Info.plist is invalid"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

if swift scripts/make-placeholder-icon.swift "$WORK/AppIcon.iconset" \
   && iconutil -c icns "$WORK/AppIcon.iconset" -o "$STAGE/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "warning: icon generation failed; continuing without icon" >&2
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$STAGE/Contents/Info.plist" || true
fi

APP="$OUTPUT/AI Disk Keeper.app"
rm -rf "$APP"
mv "$STAGE" "$OUTPUT/"

if [ "$SIGN" = 1 ]; then
  echo "==> Ad-hoc signing"
  codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" "$APP" || die "codesign failed"
  codesign --verify --strict --verbose=2 "$APP" || die "codesign verification failed"
fi

ARCHS="$(lipo -archs "$APP/Contents/MacOS/AIDiskKeeper" 2>/dev/null || echo unknown)"
if [ "$VERIFY" = 1 ]; then
  echo "==> Verifying bundled resources"
  OUT="$("$APP/Contents/MacOS/AIDiskKeeper" --verify-resources)" || die "--verify-resources failed: $OUT"
  echo "$OUT"
  case "$(printf '%s\n' "$OUT" | sed -n 's/^bundle=//p')" in
    "$APP/Contents/Resources/"*) ;;
    *) die "resource bundle did not resolve inside the .app" ;;
  esac
  [ "$(printf '%s\n' "$OUT" | sed -n 's/^rules=//p')" != "MISSING" ] || die "rules directory missing"
  case ",$(printf '%s\n' "$OUT" | sed -n 's/^ui_localizations=//p')," in
    *,vi,*) ;;
    *) die "UI localizations missing vi: $OUT" ;;
  esac
  if [ "$UNIVERSAL" = 1 ]; then
    case " $ARCHS " in *" arm64 "*) ;; *) die "missing arm64 slice ($ARCHS)" ;; esac
    case " $ARCHS " in *" x86_64 "*) ;; *) die "missing x86_64 slice ($ARCHS)" ;; esac
  fi
fi

if [ "$ZIP" = 1 ]; then
  ZIPFILE="$OUTPUT/AI-Disk-Keeper-$VERSION.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIPFILE" || die "zip failed"
  echo "zip:       $ZIPFILE"
fi

echo "app:       $APP"
echo "version:   $VERSION ($BUILD_NUMBER)"
echo "bundle id: $BUNDLE_ID"
echo "size:      $(du -sh "$APP" | cut -f1)"
echo "archs:     $ARCHS"
