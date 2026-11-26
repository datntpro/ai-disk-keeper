#!/bin/bash
# T44 QA fixtures (Care Scan coordinator is Core-only; these give a later UI QA run something to scan).
# Creates files ONLY under ~/ADKQA-T44 and ~/.claude/projects/-ADKQA; teardown removes exactly those.
set -euo pipefail

ROOT="$HOME/ADKQA-T44"
CLAUDE="$HOME/.claude/projects/-ADKQA"

case "${1:-}" in
  setup)
    mkdir -p "$ROOT/Large" "$ROOT/Dupes" "$CLAUDE"
    mkdir -p "$ROOT/Dupes/a" "$ROOT/Dupes/b"
    head -c 3000000 /dev/urandom > "$ROOT/Dupes/a/copy.bin"
    cp "$ROOT/Dupes/a/copy.bin" "$ROOT/Dupes/b/copy.bin"
    head -c 60000000 /dev/urandom > "$ROOT/Large/old-archive.bin"
    touch -t 202001010000 "$ROOT/Large/old-archive.bin"
    head -c 2000000 /dev/urandom > "$CLAUDE/session-adkqa.jsonl"
    touch -t 202001010000 "$CLAUDE/session-adkqa.jsonl"
    echo "T44 fixtures created in $ROOT and $CLAUDE"
    ;;
  teardown)
    rm -rf "$ROOT" "$CLAUDE"
    echo "T44 fixtures removed"
    ;;
  *)
    echo "usage: $0 setup|teardown" >&2
    exit 2
    ;;
esac
