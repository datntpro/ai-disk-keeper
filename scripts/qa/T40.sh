#!/usr/bin/env bash
# Manual QA fixtures for T40 (Storage). Run inside the Tart VM, never on the owner's Mac.
#   scripts/qa/T40.sh setup      creates ~/ADKQA-T40/ files and moves them to the Trash via Finder, so the Trash is non-empty
#   scripts/qa/T40.sh teardown   removes ~/ADKQA-T40 (the Trash entries named adkqa-t40-* are left for you to empty in the VM)
set -euo pipefail
DIR="$HOME/ADKQA-T40"

case "${1:-}" in
  setup)
    mkdir -p "$DIR"
    for i in 1 2 3; do
      dd if=/dev/zero of="$DIR/adkqa-t40-$i.bin" bs=1048576 count=$((i * 5)) 2>/dev/null
    done
    osascript <<APPLESCRIPT
tell application "Finder"
  repeat with n in {"adkqa-t40-1.bin", "adkqa-t40-2.bin", "adkqa-t40-3.bin"}
    delete POSIX file ("$DIR/" & n)
  end repeat
end tell
APPLESCRIPT
    echo "Put 3 fixture files in the Trash. For snapshots, run 'tmutil localsnapshot' yourself in the VM terminal (VM only)."
    ;;
  teardown)
    rm -rf "$DIR"
    rm -f "$HOME"/.Trash/adkqa-t40-*.bin
    echo "Removed $DIR and the adkqa-t40 Trash entries."
    ;;
  *)
    echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
