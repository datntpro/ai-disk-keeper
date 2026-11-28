#!/bin/bash
# H6 QA checks (real reclaimable space on APFS). Run in the Tart VM only, never on the owner's Mac.
#   setup     make ~/ADKQA-H6/base.img (2 GB) and an APFS clone of it at the fake Tart OCI path
#   teardown  remove ~/ADKQA-H6 and the fake Tart image dir
# Then scan: the item shows "Shown 2 GB · Frees about 0 B". Delete base.img, rescan: about 2 GB.
set -euo pipefail

guard() { [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }; }
BASE="$HOME/ADKQA-H6/base.img"
CLONE_DIR="$HOME/.tart/cache/OCIs/adkqa.local/fake/latest"

case "${1:-}" in
  setup)
    guard
    mkdir -p "$HOME/ADKQA-H6" "$CLONE_DIR"
    dd if=/dev/urandom of="$BASE" bs=1m count=2048 2>/dev/null
    cp -c "$BASE" "$CLONE_DIR/disk.img"
    echo "created $BASE and clone $CLONE_DIR/disk.img"
    ;;
  teardown)
    guard
    rm -rf "$HOME/ADKQA-H6" "$HOME/.tart/cache/OCIs/adkqa.local"
    echo "H6 QA state removed"
    ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
