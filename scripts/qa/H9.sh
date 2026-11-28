#!/bin/bash
# H9 QA (SSD health card). Nothing to create or tear down: the card only reads.
#   vm     in a Tart VM: prints what to check (virtual disk -> "Health data isn't available for this disk")
#   mac    on a real Mac: runs the gated live read test (ADK_HW_TESTS=1), read-only
set -euo pipefail
case "${1:-}" in
  vm)
    [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "not in a VM" >&2; exit 1; }
    echo "Open Storage: the SSD health card must read \"Health data isn't available for this disk\"." ;;
  mac)
    ADK_HW_TESTS=1 nice -n 10 swift test --filter SSDHealthTests/testLiveReadOnRealHardware ;;
  *) echo "usage: $0 vm|mac" >&2; exit 2 ;;
esac
