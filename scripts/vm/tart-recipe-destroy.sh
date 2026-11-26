#!/usr/bin/env bash
# Orca environment recipe `destroy` step: reads the lifecycle payload JSON on stdin,
# stops and deletes the cloned test VM. Never touches the base image.
set -euo pipefail
. "$(dirname "$0")/tart-lib.sh"
VM=$(python3 -c 'import sys,json
d=json.load(sys.stdin); print((d.get("recipeResult") or {}).get("userData",{}).get("vmName",""))' || true)
if [[ -z "$VM" || "$VM" != adk-test-* ]]; then log "no adk-test-* vmName in payload; nothing to destroy"; exit 0; fi
log "destroying $VM"
tart stop "$VM" >&2 2>/dev/null || true
tart delete "$VM" >&2 2>/dev/null || true
