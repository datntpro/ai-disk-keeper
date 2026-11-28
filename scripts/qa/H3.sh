#!/bin/bash
# H3 QA fixtures (Worktree inventory). Run in the Tart VM only, never on the owner's Mac.
# Creates files ONLY under ~/ADKQA-H3 (a bare "origin", a main repo "proj" and linked worktrees); teardown removes exactly that.
#   setup     build the fixture: ff-merged, squash-merged / cherry-picked (pushed: sqp, cpp; never pushed: sq, cp), unmerged, dirty, untracked, ignored-env, detached, locked
#   teardown  remove ~/ADKQA-H3
# Expected in the app (Worktrees > Inventory, add ~/ADKQA-H3 as a project folder, idle time 1 h or `touch -t` the files):
#   ff, sqp, cpp = Safe to clean; sq, cp (content in origin/main, branch never pushed) and um = Review; dirty, untracked, env, det, locked = Keep. Orca is absent in the VM, so a
#   warning says git alone is used.
set -euo pipefail

ROOT="$HOME/ADKQA-H3"
guard() { [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }; }
g() { git -c user.name=qa -c user.email=qa@example.invalid -c protocol.file.allow=always "$@"; }

case "${1:-}" in
  setup)
    guard
    rm -rf "$ROOT"; mkdir -p "$ROOT"
    g init -q --bare -b main "$ROOT/origin.git"
    g init -q -b main "$ROOT/proj"
    cd "$ROOT/proj"
    echo base > README.md; echo .env > .gitignore; g add -A; g commit -q -m init
    g remote add origin "$ROOT/origin.git"; g push -q -u origin main; g remote set-head origin main
    wt() { g worktree add -q -b "$1" "$ROOT/$1"; echo "$1" > "$ROOT/$1/$1.txt"; g -C "$ROOT/$1" add -A; g -C "$ROOT/$1" commit -q -m "work $1"; }
    wt ff;  g merge -q --ff-only ff
    wt sq;  g merge -q --squash sq; g commit -q -m "squash sq"
    # main must move first, or the cherry-pick has the same parent and timestamp = the same SHA (a fast-forward)
    wt cp;  echo adv1 > adv1.txt; g add adv1.txt; g commit -q -m adv1; g cherry-pick "$(g rev-parse cp)" >/dev/null
    wt um
    wt sqp; g -C "$ROOT/sqp" push -q origin sqp; g merge -q --squash sqp; g commit -q -m "squash sqp"
    wt cpp; g -C "$ROOT/cpp" push -q origin cpp; echo adv2 > adv2.txt; g add adv2.txt; g commit -q -m adv2; g cherry-pick "$(g rev-parse cpp)" >/dev/null
    wt dirty; echo changed >> "$ROOT/dirty/README.md"
    wt untracked; echo new > "$ROOT/untracked/new.txt"
    wt env; echo SECRET=1 > "$ROOT/env/.env"
    g worktree add -q --detach "$ROOT/det"; echo only > "$ROOT/det/only.txt"; g -C "$ROOT/det" add -A; g -C "$ROOT/det" commit -q -m only-here
    wt locked; g worktree lock "$ROOT/locked"
    g push -q origin main
    echo "fixture ready under $ROOT"
    ;;
  teardown)
    guard
    rm -rf "$ROOT"
    ;;
  *) echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
