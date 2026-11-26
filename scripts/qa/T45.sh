#!/bin/bash
# T45 QA fixtures. Everything lives under ADKQA paths; teardown removes exactly those.
#   scripts/qa/T45.sh setup|teardown
set -euo pipefail

CACHE1="$HOME/Library/Caches/com.adkqa.cache1"
CACHE2="$HOME/Library/Caches/com.adkqa.cache2"
ROOT="$HOME/ADKQA-T45"

case "${1:-}" in
  setup)
    mkdir -p "$CACHE1" "$CACHE2" "$ROOT"
    dd if=/dev/urandom of="$CACHE1/blob" bs=1m count=50 2>/dev/null
    dd if=/dev/urandom of="$CACHE2/blob" bs=1m count=50 2>/dev/null
    echo "original" > "$ROOT/changeme"
    echo "T45 fixtures ready: $CACHE1 $CACHE2 $ROOT"
    ;;
  teardown)
    rm -rf "$CACHE1" "$CACHE2" "$ROOT"
    rm -rf "$HOME"/.Trash/com.adkqa.*
    echo "T45 fixtures removed"
    ;;
  *)
    echo "usage: $0 setup|teardown" >&2
    exit 2
    ;;
esac
