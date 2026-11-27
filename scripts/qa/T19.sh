#!/usr/bin/env bash
# Manual QA fixtures for T19 (Breakdown views). Run inside the Tart VM, never on the owner's Mac. Fake data only.
#   scripts/qa/T19.sh setup      creates ~/ADKQA-T19: repo "app", its linked worktree "app-wt", a second repo "other/app"
#                                (same folder name), a non-repo "notrepo", and Claude transcripts whose cwd points at each
#   scripts/qa/T19.sh teardown   removes ~/ADKQA-T19 and the seeded ~/.claude/projects/-*ADKQA-T19* folders
# Check: AI Tools -> "By tool" / "By project"; app + app-wt are ONE bar; the two "app" repos are two bars with
# different labels (parent folder shown) and both are clickable; clicking filters the list, Clear filter restores it;
# a tool filter + a project filter show both names; switching to Worktrees clears them; light/dark; VoiceOver reads
# "name, total, safe" and each bar is a button; vi pass.
set -euo pipefail
DIR="$HOME/ADKQA-T19"
CLAUDE="$HOME/.claude/projects"

seed_transcript() { # <cwd> <size-kb>
  local cwd="$1" kb="$2" enc
  enc="$(printf '%s' "$cwd" | sed 's|[/.]|-|g')"
  mkdir -p "$CLAUDE/$enc"
  python3 - "$CLAUDE/$enc/adkqa-t19.jsonl" "$cwd" "$kb" <<'PY'
import json, sys
path, cwd, kb = sys.argv[1], sys.argv[2], int(sys.argv[3])
line = json.dumps({"type": "user", "cwd": cwd, "message": {"role": "user", "content": "x" * 900}}) + "\n"
with open(path, "w") as f:
    for _ in range(max(1, kb * 1024 // len(line))):
        f.write(line)
PY
}

case "${1:-}" in
  setup)
    [[ "$(id -un)" != "datnt" ]] || { echo "refusing to run outside the VM" >&2; exit 1; }
    mkdir -p "$DIR/app" "$DIR/other/app" "$DIR/notrepo"
    git -C "$DIR/app" init -q && git -C "$DIR/app" -c user.email=qa@example.invalid -c user.name=qa commit -q --allow-empty -m init
    git -C "$DIR/app" worktree add -q "$DIR/app-wt" -b adkqa-wt
    git -C "$DIR/other/app" init -q
    seed_transcript "$DIR/app" 3800
    seed_transcript "$DIR/app-wt" 2500
    seed_transcript "$DIR/other/app" 1900
    seed_transcript "$DIR/notrepo" 600
    echo "Fixtures ready under $DIR and $CLAUDE. Run a scan."
    ;;
  teardown)
    rm -rf "$DIR"
    rm -rf "$CLAUDE"/*ADKQA-T19*
    echo "Removed $DIR and the seeded Claude project folders."
    ;;
  *)
    echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
