#!/usr/bin/env bash
# Manual QA fixtures for T39b (unavailable simulators). Run inside the Tart VM (macos-tahoe-xcode:26.3), never on the owner's Mac.
#   scripts/qa/T39b.sh setup      creates simulator "ADKQA-iPhone" and makes it unavailable
#   scripts/qa/T39b.sh teardown   deletes every simulator whose name starts with ADKQA-
set -euo pipefail
case "${1:-}" in
  setup)
    runtime=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["identifier"].split(".")[-1].startswith("iOS")]; print(r[-1]["identifier"])')
    udid=$(xcrun simctl create "ADKQA-iPhone" "com.apple.CoreSimulator.SimDeviceType.iPhone-15" "$runtime")
    echo "Created ADKQA-iPhone ($udid) on $runtime"
    echo "Now make it unavailable IN THE VM ONLY: xcrun simctl runtime delete <id of $runtime>,"
    echo "or remove only that runtime's disk image. Then: xcrun simctl list devices unavailable"
    ;;
  teardown)
    xcrun simctl list devices -j | python3 -c '
import json,sys
for rt in json.load(sys.stdin)["devices"].values():
    for d in rt:
        if d["name"].startswith("ADKQA-"): print(d["udid"])' | while read -r u; do xcrun simctl delete "$u"; done
    echo "Removed ADKQA-* simulators"
    ;;
  *) echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
