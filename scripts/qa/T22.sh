#!/usr/bin/env bash
# Manual QA fixtures for T22 (Scheduled scans). Run inside the Tart VM, never on the owner's Mac. Fake data only.
#   scripts/qa/T22.sh setup      seeds ~/.claude/projects/-ADKQA-T22 with an old ~6 GB transcript set (Safe-sized)
#   scripts/qa/T22.sh teardown   removes it
# Check: Settings -> Schedule -> Daily: the notification permission prompt appears now (not at launch).
# Login item toggle -> System Settings > Login Items lists the app. Then
#   defaults write io.github.datntpro.aidiskkeeper ADK.scheduledLastRun -date 2000-01-01   and relaunch:
# a scheduled run happens within the hourly check; notification "... is safe to free"; clicking it opens Overview;
# nothing is selected and the Trash is untouched. Off -> the popover's "Next Care Scan" row disappears. vi pass.
# Battery / Low Power gating is not simulable in the VM: covered by unit tests.
set -euo pipefail
DIR="$HOME/.claude/projects/-ADKQA-T22"
case "${1:-}" in
  setup)
    [[ "$(id -un)" != "datnt" ]] || { echo "refusing to run outside the VM" >&2; exit 1; }
    mkdir -p "$DIR"
    for i in 1 2 3 4 5 6; do
      dd if=/dev/zero bs=1048576 count=1024 of="$DIR/adkqa-t22-$i.jsonl" 2>/dev/null   # real blocks, not sparse
      touch -t 202001010000 "$DIR/adkqa-t22-$i.jsonl"
    done
    echo "seeded $DIR" ;;
  teardown) rm -rf "$DIR"; echo "removed $DIR" ;;
  *) echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
