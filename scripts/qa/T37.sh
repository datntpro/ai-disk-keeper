#!/usr/bin/env bash
# Manual QA fixtures for T37 (Uninstaller). Run inside the Tart VM, never on the owner's Mac.
#   scripts/qa/T37.sh setup      builds two unsigned fixture apps + their leftovers + one orphan
#   scripts/qa/T37.sh teardown   removes exactly those paths (and the ADKQA items in the Trash)
set -euo pipefail
APPS="$HOME/Applications"
LIB="$HOME/Library"
SLIDE="$APPS/ADKQA Slidecraft.app"
NOTELY="$APPS/ADKQA Notely.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

make_app() { # path bundle-id name
  mkdir -p "$1/Contents/MacOS"
  cat > "$1/Contents/MacOS/run" <<'SH'
#!/bin/sh
sleep 600
SH
  chmod +x "$1/Contents/MacOS/run"
  /usr/bin/plutil -create xml1 "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string "$3" "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string run "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$1/Contents/Info.plist"
}
filler() { mkdir -p "$1"; mkfile -n "$2" "$1/data.bin"; }

case "${1:-}" in
  setup)
    mkdir -p "$APPS"
    make_app "$SLIDE" com.adkqa.slidecraft "ADKQA Slidecraft"
    make_app "$NOTELY" com.adkqa.notely "ADKQA Notely"
    filler "$LIB/Caches/com.adkqa.slidecraft" 20m
    filler "$LIB/Application Support/com.adkqa.slidecraft" 5m
    filler "$LIB/Application Support/ADKQA Slidecraft" 1m
    mkdir -p "$LIB/Saved Application State/com.adkqa.slidecraft.savedState"
    touch "$LIB/Saved Application State/com.adkqa.slidecraft.savedState/windows.plist"
    # Orphan: LaunchServices doesn't know this id, and both entries are old.
    filler "$LIB/Containers/com.adkqa.ghost.app" 2m
    filler "$LIB/Caches/com.adkqa.ghost.app" 1m
    find "$LIB/Containers/com.adkqa.ghost.app" "$LIB/Caches/com.adkqa.ghost.app" -exec touch -t 202601010000 {} +
    "$LSREGISTER" -f "$SLIDE"; "$LSREGISTER" -f "$NOTELY"   # VM only
    echo "Created the ADKQA fixtures. Launch Notely with: open \"$NOTELY\""
    ;;
  teardown)
    pkill -f "ADKQA Notely" 2>/dev/null || true
    pkill -f "ADKQA Slidecraft" 2>/dev/null || true
    rm -rf "$SLIDE" "$NOTELY" \
      "$LIB/Caches/com.adkqa.slidecraft" "$LIB/Application Support/com.adkqa.slidecraft" \
      "$LIB/Application Support/ADKQA Slidecraft" "$LIB/Saved Application State/com.adkqa.slidecraft.savedState" \
      "$LIB/Containers/com.adkqa.ghost.app" "$LIB/Caches/com.adkqa.ghost.app"
    rm -rf "$HOME/.Trash/"*ADKQA* "$HOME/.Trash/"*adkqa* 2>/dev/null || true
    echo "Removed the ADKQA fixtures."
    ;;
  *) echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
