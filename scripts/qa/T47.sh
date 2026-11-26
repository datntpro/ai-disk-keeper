#!/bin/bash
# T47 QA fixtures (menu bar extra). Run in the Tart VM only, never on the owner's Mac.
# Creates files ONLY under ~/ADKQA-T47 and ~/.claude/projects/-ADKQA; teardown removes exactly those.
# The low-space step needs a fill file: `fill <MB>` makes ~/ADKQA-T47/fill.bin to push free space under the threshold.
set -euo pipefail

ROOT="$HOME/ADKQA-T47"
CLAUDE="$HOME/.claude/projects/-ADKQA"

case "${1:-}" in
  setup)
    mkdir -p "$ROOT" "$CLAUDE"
    head -c 40000000 /dev/urandom > "$CLAUDE/session-adkqa.jsonl"
    touch -t 202001010000 "$CLAUDE/session-adkqa.jsonl"
    echo "T47 fixtures created in $ROOT and $CLAUDE"
    ;;
  fill)
    mkdir -p "$ROOT"
    mkfile -n "${2:?size in MB}m" "$ROOT/fill.bin"
    echo "fill.bin: ${2} MB"
    ;;
  unfill)
    rm -f "$ROOT/fill.bin"
    ;;
  teardown)
    rm -rf "$ROOT" "$CLAUDE"
    defaults delete io.github.datntpro.aidiskkeeper ADK.lowSpaceArmed 2>/dev/null || true
    echo "T47 fixtures removed"
    ;;
  *)
    echo "usage: $0 setup|fill <MB>|unfill|teardown" >&2
    exit 2
    ;;
esac
