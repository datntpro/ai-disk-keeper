#!/bin/bash
# H2 QA checks (status.json + adk). Run in the Tart VM only, never on the owner's Mac.
# Creates nothing except what the app itself writes; `check` only reads. Fill/unfill: reuse scripts/qa/T47.sh, writer: scripts/qa/H1.sh.
#   check     run `adk status` against the installed app and print the exit code with its meaning
#   teardown  remove ~/.local/bin/adk if it is our symlink, and ~/ADKQA-H2 (scratch only)
set -euo pipefail

APP_ADK="/Applications/AI Disk Keeper.app/Contents/MacOS/adk"
guard() { [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }; }
meaning() { case "$1" in 0) echo ok;; 10) echo warn;; 20) echo critical;; 3) echo "stale/missing/not running";; 4) echo "unreadable/schema";; 2) echo usage;; *) echo "?";; esac; }

case "${1:-}" in
  check)
    guard
    ADK="$APP_ADK"; command -v adk >/dev/null 2>&1 && ADK="$(command -v adk)"
    [ -x "$ADK" ] || { echo "adk not found" >&2; exit 1; }
    set +e
    "$ADK" status; code=$?
    echo "exit $code ($(meaning $code))"
    [ -n "${2:-}" ] && { "$ADK" status --worktree "$2"; echo "exit $? (worktree $2)"; }
    ;;
  teardown)
    guard
    link="$HOME/.local/bin/adk"
    if [ -L "$link" ] && [[ "$(readlink "$link")" == */Contents/MacOS/adk ]]; then rm -f "$link"; fi
    rm -rf "$HOME/ADKQA-H2"
    echo "H2 QA state removed"
    ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
