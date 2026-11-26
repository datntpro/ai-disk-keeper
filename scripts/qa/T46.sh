#!/usr/bin/env bash
# T46 QA fixtures (VM only). Usage: scripts/qa/T46.sh setup|teardown
set -euo pipefail
ROOT="$HOME/ADKQA-T46"
case "${1:-}" in
  setup)
    mkdir -p "$ROOT/locked" "$ROOT/backup"
    AS="$HOME/Library/Application Support/AIDiskKeeper"
    [[ -d "$AS" ]] && mv "$AS" "$ROOT/backup/AIDiskKeeper"
    chmod 000 "$ROOT/locked"
    echo "setup done: first-run state restored; $ROOT/locked is unreadable" ;;
  teardown)
    chmod 755 "$ROOT/locked" 2>/dev/null || true
    AS="$HOME/Library/Application Support/AIDiskKeeper"
    chmod 755 "$AS" 2>/dev/null || true
    if [[ -d "$ROOT/backup/AIDiskKeeper" ]]; then rm -rf "$AS"; mv "$ROOT/backup/AIDiskKeeper" "$AS"; fi
    rm -rf "$ROOT"; echo "teardown done" ;;
  *) echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
