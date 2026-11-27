#!/bin/bash
# H5 QA fixtures (process control). Run in the Tart VM only, never on the owner's Mac.
# Starts a process tree that THIS SCRIPT owns and writes only under ~/ADKQA-H5. stop/teardown signal only the pids this
# script recorded (never by name).
#   start     bash -> writer loop (dd in a loop) + sleep; pids in ~/ADKQA-H5/pids
#   status    show state (ps stat) of the recorded pids
#   stop      kill the recorded pids (the script's own fixtures)
#   teardown  stop + remove ~/ADKQA-H5
set -euo pipefail

ROOT="$HOME/ADKQA-H5"
guard() { [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }; }

case "${1:-}" in
  start)
    guard
    mkdir -p "$ROOT"
    cd "$ROOT"
    nohup bash -c 'while true; do dd if=/dev/zero of="$HOME/ADKQA-H5/w" bs=1m count=256 2>/dev/null; sync; done & sleep 100000 & wait' >/dev/null 2>&1 &
    echo $! > "$ROOT/pids"
    echo "fixture tree started (root pid $(cat "$ROOT/pids")). In AI Disk Keeper: Disk activity -> the bash/dd rows."
    echo "Steps: background (tree) and note the write rate before/after; pause -> ps shows T and 0 MB/s; auto-resume (set 1 min);"
    echo "pause then quit the app -> running again; pause then 'kill -9' the app -> relaunch -> recovery sheet; Finder -> refused."
    echo "Does a newly spawned dd inherit background? Check with: ps -o pid,nice,stat,command -p \$(pgrep -P \$(cat $ROOT/pids)) (record in docs/process-control.md)"
    ;;
  status)
    [ -f "$ROOT/pids" ] || { echo "not started"; exit 0; }
    ps -o pid,ppid,stat,command -g "$(cat "$ROOT/pids")" 2>/dev/null || ps -o pid,ppid,stat,command -p "$(cat "$ROOT/pids")"
    ;;
  stop)
    if [ -f "$ROOT/pids" ]; then
      root=$(cat "$ROOT/pids")
      # Children of our recorded root only; SIGCONT first so stopped fixtures can die, then SIGTERM (test fixtures, not app code).
      for p in $(pgrep -P "$root" 2>/dev/null || true) "$root"; do kill -CONT "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
      rm -f "$ROOT/pids"
    fi
    ;;
  teardown)
    guard
    "$0" stop
    rm -rf "$ROOT"
    ;;
  *) echo "usage: $0 start|status|stop|teardown" >&2; exit 2 ;;
esac
