#!/usr/bin/env bash
# Build the shared `adk-base` Tart image: cirruslabs macOS Tahoe + Xcode 26.3 (what CI uses)
# plus the Orca CLI/runtime copied from the host's /Applications/Orca.app, git, and the repo cache.
# Idempotent-ish: refuses to overwrite an existing adk-base unless ADK_REBUILD=1.
# Needs ~120 GB of sparse disk for the image; stops if the host would drop below 60 GB free.
set -euo pipefail
. "$(dirname "$0")/tart-lib.sh"
SRC_IMAGE="${SRC_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:26.3}"
ORCA_APP="${ORCA_APP:-/Applications/Orca.app}"
TMPVM=adk-base-build

command -v tart >/dev/null || { log "brew install openai/tools/tart"; exit 1; }
if tart list --quiet | grep -qx "$ADK_BASE_VM"; then
  [[ "${ADK_REBUILD:-}" == 1 ]] || { log "$ADK_BASE_VM exists (ADK_REBUILD=1 to rebuild)"; exit 0; }
fi
# Never delete a stale build VM someone else made; clear only our own leftover.
cleanup() { tart stop "$TMPVM" >/dev/null 2>&1 || true; tart delete "$TMPVM" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup   # leftover from a previous failed run
require_free_gb 60   # clone is copy-on-write; the pull (~67 GB download, ~87 GB on disk) needs ~150 GB free if not cached
tart list --quiet | grep -qx "$(basename "${SRC_IMAGE%%:*}"):${SRC_IMAGE##*:}\|$SRC_IMAGE" || tart pull "$SRC_IMAGE"
tart clone "$SRC_IMAGE" "$TMPVM"
nohup tart run --no-graphics "$TMPVM" >"${TMPDIR:-/tmp}/$TMPVM.log" 2>&1 &
wait_guest "$TMPVM" 300

log "copying Orca into the guest"
tar -C "$(dirname "$ORCA_APP")" -cf - "$(basename "$ORCA_APP")" | tart exec -i "$TMPVM" tar -C /Users/admin -xf -
gexec "$TMPVM" /bin/bash -lc 'sudo mkdir -p /usr/local/bin && sudo rm -rf /Applications/Orca.app && sudo mv ~/Orca.app /Applications/ && sudo ln -sf /Applications/Orca.app/Contents/Resources/bin/orca /usr/local/bin/orca && orca --version'
gexec "$TMPVM" /bin/bash -lc 'command -v git && git --version; xcode-select -p; xcodebuild -version | head -1; command -v brew'
# Warm the repo checkout + SwiftPM cache so test clones build fast.
gexec "$TMPVM" /bin/bash -lc 'rm -rf ~/ai-disk-keeper && git clone --quiet https://github.com/datntpro/ai-disk-keeper.git ~/ai-disk-keeper'

tart stop "$TMPVM"
# Swap in only after everything above succeeded, so a failed rebuild keeps the old base.
if tart list --quiet | grep -qx "$ADK_BASE_VM"; then tart delete "$ADK_BASE_VM"; fi
tart clone "$TMPVM" "$ADK_BASE_VM"
log "base ready: $ADK_BASE_VM"; tart list
