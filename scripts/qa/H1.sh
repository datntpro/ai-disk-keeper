#!/bin/bash
# H1 QA fixtures (Disk activity). Run in the Tart VM only, never on the owner's Mac.
# Creates files ONLY under ~/ADKQA-H1 (a temp git repo and one linked worktree "repo-wt"); teardown removes exactly that.
#   writer    start a fixture writer inside the worktree: one long-lived python process, 64 MB per loop. PID in ~/ADKQA-H1/writer.pid
#   stop      stop the writer
#   teardown  stop + remove ~/ADKQA-H1
# For the 15 % warning step reuse T47's `fill` / `unfill` (scripts/qa/T47.sh).
set -euo pipefail

ROOT="$HOME/ADKQA-H1"
guard() { [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }; }

case "${1:-}" in
  writer)
    guard
    mkdir -p "$ROOT"
    if [ ! -d "$ROOT/repo/.git" ]; then
      git init -q "$ROOT/repo"
      git -C "$ROOT/repo" -c user.name=qa -c user.email=qa@example.invalid commit -q --allow-empty -m init
      git -C "$ROOT/repo" worktree add -q "$ROOT/repo-wt" -b qa-h1
    fi
    cd "$ROOT/repo-wt"
    # One long-lived writer: a loop of 25 ms `dd` processes is never in two samples (their counters die with them).
    nohup python3 -c "import os
f=open('w','wb')
b=b'0'*(1<<20)
while True:
    f.seek(0)
    for _ in range(64): f.write(b)
    f.flush(); os.fsync(f.fileno())" >/dev/null 2>&1 &
    echo $! > "$ROOT/writer.pid"
    echo "writer started (pid $(cat "$ROOT/writer.pid")); expect repo-wt at the top of Disk activity"
    ;;
  stop)
    [ -f "$ROOT/writer.pid" ] && { pkill -P "$(cat "$ROOT/writer.pid")" 2>/dev/null || true; kill "$(cat "$ROOT/writer.pid")" 2>/dev/null || true; rm -f "$ROOT/writer.pid"; }
    ;;
  teardown)
    guard
    "$0" stop
    git -C "$ROOT/repo" worktree remove --force "$ROOT/repo-wt" 2>/dev/null || true
    rm -rf "$ROOT"
    ;;
  *)
    echo "usage: $0 writer|stop|teardown" >&2
    exit 2
    ;;
esac
