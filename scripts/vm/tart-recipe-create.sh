#!/usr/bin/env bash
# Orca environment recipe `create` step: clone adk-base (copy-on-write), boot it headless,
# start `orca serve` inside, and print the recipe result JSON on stdout (all logs go to stderr).
# Contract: https://orca (orca.yaml environmentRecipes) – schemaVersion 1, orca-worktree mode.
set -euo pipefail
. "$(dirname "$0")/tart-lib.sh"

command -v tart >/dev/null || { log "tart not installed (brew install openai/tools/tart)"; exit 1; }
tart list --quiet 2>/dev/null | grep -qx "$ADK_BASE_VM" || { log "base VM '$ADK_BASE_VM' missing; run scripts/vm/tart-build-base.sh"; exit 1; }
require_free_gb "${ADK_MIN_FREE_GB:-40}"

ID="${ORCA_VM_INSTANCE_ID:-$(date +%s)-$RANDOM}"
VM="adk-test-${ID//[^A-Za-z0-9_-]/}"
log "cloning $ADK_BASE_VM -> $VM"
tart clone "$ADK_BASE_VM" "$VM"
# Headless boot; keep it detached so it outlives this script. Isolated: no host dirs are shared.
nohup tart run --no-graphics --no-audio "$VM" >"${TMPDIR:-/tmp}/$VM.run.log" 2>&1 &
wait_guest "$VM" 300
IP=$(tart ip "$VM" --wait 120)
log "$VM up at $IP"

PROJECT_ROOT="/Users/admin/ai-disk-keeper"
# Every copy of the image must have its own pairing identity.
gexec "$VM" /bin/bash -lc "export ORCA_INSTANCE_ID='$VM'; \
  [ -d '$PROJECT_ROOT/.git' ] || git clone --quiet '${ORCA_REPO_URL:-https://github.com/datntpro/ai-disk-keeper.git}' '$PROJECT_ROOT'; \
  nohup env ORCA_SERVE_RUNTIME=orcad ORCA_INSTANCE_ID='$VM' /usr/local/bin/orca serve --project-root '$PROJECT_ROOT' \
    --pairing-address '$IP' --bind 0.0.0.0 --recipe-json >/tmp/orca-serve.out 2>/tmp/orca-serve.err </dev/null & disown" >&2

# Wait for the result JSON line that `orca serve --recipe-json` prints.
for _ in $(seq 1 90); do
  OUT=$(gexec "$VM" /bin/cat /tmp/orca-serve.out 2>/dev/null || true)
  if printf '%s' "$OUT" | grep -q '"schemaVersion"'; then
    printf '%s' "$OUT" | python3 -c '
import sys, json
raw = sys.stdin.read()
for line in raw.splitlines():
    line = line.strip()
    if line.startswith("{") and "schemaVersion" in line:
        d = json.loads(line); d.setdefault("userData", {})["vmName"] = sys.argv[1]
        print(json.dumps(d)); break' "$VM"
    exit 0
  fi
  sleep 2
done
log "orca serve never printed a recipe result; stderr:"; gexec "$VM" /bin/cat /tmp/orca-serve.err >&2 || true
exit 1
