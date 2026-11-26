# Shared helpers for the Tart VM scripts. Source, don't run.
ADK_BASE_VM="${ADK_BASE_VM:-adk-base}"
log() { echo "[tart-vm] $*" >&2; }
# Run a command in the guest through the Tart guest agent (no ssh/password needed).
gexec() { local vm="$1"; shift; tart exec "$vm" "$@"; }
# Wait until the guest agent answers (VM booted and logged in).
wait_guest() {
  local vm="$1" deadline=$((SECONDS + ${2:-300}))
  until tart exec "$vm" true >/dev/null 2>&1; do
    (( SECONDS < deadline )) || { log "timeout waiting for guest agent on $vm"; return 1; }
    sleep 2
  done
}
# Refuse to run big operations when the host disk is nearly full (<60 GB free).
require_free_gb() {
  local need="${1:-60}" free
  free=$(df -g / | awk 'NR==2{print $4}')
  (( free >= need )) || { log "only ${free} GB free on host, need >= ${need} GB"; return 1; }
}
