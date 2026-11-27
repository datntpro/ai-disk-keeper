#!/bin/bash
# T20 QA fixtures (In-use detection). Run in the Tart VM only, never on the owner's Mac.
# Creates files ONLY under ~/ADKQA-T20 and ~/.claude/projects/-ADKQA-T20; teardown removes exactly those.
#   setup     an old (2020) Safe log directory under a seeded Claude Code path
#   hold      start `tail -f` on a file inside it (PID in ~/ADKQA-T20/hold.pid)
#   release   stop the holder
#   fresh     touch a file in the directory (expect "Modified in the last hour")
#   teardown  release + remove both folders
set -euo pipefail

ROOT="$HOME/ADKQA-T20"
SEED="$HOME/.claude/projects/-ADKQA-T20"
LOGDIR="$ROOT/logs"
guard() { [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }; }

case "${1:-}" in
  setup)
    guard
    mkdir -p "$LOGDIR" "$SEED"
    for n in a b c; do head -c 1048576 /dev/zero > "$LOGDIR/$n.log"; done
    head -c 1048576 /dev/zero > "$SEED/old.jsonl"
    touch -t 202001010000 "$LOGDIR"/*.log "$SEED/old.jsonl"
    touch -t 202001010000 "$LOGDIR" "$SEED" "$ROOT"
    echo "created $LOGDIR and $SEED (mtime 2020); rescan: expect Safe"
    ;;
  hold)
    guard
    [ -f "$LOGDIR/a.log" ] || { echo "run setup first" >&2; exit 1; }
    nohup tail -f "$LOGDIR/a.log" >/dev/null 2>&1 &
    echo $! > "$ROOT/hold.pid"
    echo "tail holds $LOGDIR/a.log (pid $(cat "$ROOT/hold.pid")); rescan: expect Keep, 'In use by tail'"
    ;;
  release)
    [ -f "$ROOT/hold.pid" ] && { kill "$(cat "$ROOT/hold.pid")" 2>/dev/null || true; rm -f "$ROOT/hold.pid"; }
    echo "released; rescan: expect Safe again"
    ;;
  fresh)
    guard
    touch "$LOGDIR/b.log"
    echo "touched b.log; rescan: expect Keep, 'Modified in the last hour'"
    ;;
  teardown)
    guard
    "$0" release
    rm -rf "$ROOT" "$SEED"
    ;;
  *)
    echo "usage: $0 setup|hold|release|fresh|teardown" >&2
    exit 2
    ;;
esac
