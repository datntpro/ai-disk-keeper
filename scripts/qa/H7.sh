#!/usr/bin/env bash
# Manual QA fixtures for H7 (build caches). Run inside the Tart VM (macos-tahoe-xcode:26.3), never on the owner's Mac.
#   scripts/qa/H7.sh setup      creates fake DerivedData, pnpm store and Tart folders (all named ADKQA)
#   scripts/qa/H7.sh teardown   removes exactly those paths
# Then: scan, open AI Workspace -> Build caches. Expect:
#   ADKQA-Gone-*  Safe (project deleted, 9 days old)     ADKQA-Live-*  Review (project exists)
#   ADKQA-Recent-* Review (project gone, 2 days old)      pnpm store    Review + `pnpm store prune` hint
#   tart OCI      Review + `tart prune ...` hint          tart tmp      Safe      tart vms  report only (no checkbox)
# Clean the Safe items: they go to the Trash. The hints only copy text.
set -euo pipefail
DD="$HOME/Library/Developer/Xcode/DerivedData"
PNPM="$HOME/Library/pnpm/store/v10/ADKQA"
TART="$HOME/.tart"
PROJ="$HOME/ADKQA-H7"
OCI="$TART/cache/OCIs/adkqa.local/qa/image"

plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>WorkspacePath</key><string>%s</string></dict></plist>\n' "$1"; }
fake() { # dir bytes days-old
  mkdir -p "$1"; dd if=/dev/zero of="$1/payload.bin" bs=1m count="$2" 2>/dev/null
  touch -t "$(date -v-"$3"d +%Y%m%d%H%M)" "$1/payload.bin" "$1"
}

case "${1:-}" in
  setup)
    mkdir -p "$PROJ/App.xcodeproj"
    for spec in "ADKQA-Live-abc:$PROJ/App.xcodeproj:20" "ADKQA-Gone-abc:$PROJ/Deleted.xcodeproj:9" "ADKQA-Recent-abc:$PROJ/Moved.xcodeproj:2"; do
      IFS=: read -r name ws days <<<"$spec"
      fake "$DD/$name" 5 "$days"; plist "$ws" >"$DD/$name/info.plist"
      touch -t "$(date -v-"$days"d +%Y%m%d%H%M)" "$DD/$name/info.plist" "$DD/$name"
    done
    if [[ -e "$HOME/Library/pnpm/store" && ! -e "$PNPM" ]]; then
      echo "pnpm store exists already; not adding to it"
    else
      fake "$PNPM" 5 20
      # Age the parents too, so the store shows Review (a freshly created store dir is Keep).
      touch -t "$(date -v-20d +%Y%m%d%H%M)" "$HOME/Library/pnpm/store/v10" "$HOME/Library/pnpm/store"
    fi
    fake "$OCI" 5 20
    fake "$TART/tmp/adkqa-pull" 2 3
    fake "$TART/vms/adkqa-vm" 2 20
    echo "H7 fixtures created (ADKQA-Live points at $PROJ/App.xcodeproj, which exists; the other two projects do not)."
    ;;
  teardown)
    rm -rf "$DD"/ADKQA-* "$PROJ" "$PNPM" "$TART/cache/OCIs/adkqa.local" "$TART/tmp/adkqa-pull" "$TART/vms/adkqa-vm"
    rmdir "$HOME/Library/pnpm/store/v10" "$HOME/Library/pnpm/store" 2>/dev/null || true
    echo "Removed the H7 fixtures"
    ;;
  *) echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
