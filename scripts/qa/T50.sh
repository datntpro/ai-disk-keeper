#!/bin/bash
# T50 QA load generators (menu bar system monitor). Run in the Tart VM only, never on the owner's Mac.
# Every subcommand refuses unless `sysctl -n kern.hv_vmm_present` = 1. Writes only under ~/ADKQA-T50.
#   cpu <sec>      N x `yes > /dev/null` (N = cores), killed after <sec>
#   mem <MB>       python3 holds a bytearray of <MB> until killed
#   net <sec>      curl from a host `python3 -m http.server` on 192.168.64.1 to /dev/null, repeated for <sec>
#   energy <sec>   `top` samples of the AIDiskKeeper process (cpu, idle wakeups, power), prints averages
#   teardown       kills all of the above and removes ~/ADKQA-T50
set -euo pipefail

ROOT="$HOME/ADKQA-T50"
HOST="${ADK_QA_HOST:-192.168.64.1}"
PORT="${ADK_QA_PORT:-8000}"

[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = "1" ] || { echo "refusing to run outside a VM" >&2; exit 1; }
mkdir -p "$ROOT"

track() { echo "$1" >> "$ROOT/pids"; }

case "${1:-}" in
  cpu)
    secs="${2:?seconds}"
    for _ in $(seq "$(sysctl -n hw.logicalcpu)"); do yes > /dev/null & track $!; done
    sleep "$secs"
    "$0" teardown-procs
    ;;
  mem)
    mb="${2:?size in MB}"
    python3 -c "import time; b = bytearray(${mb} * 1048576); b[::4096] = b'x' * len(b[::4096]); time.sleep(3600)" &
    track $!
    echo "holding ${mb} MB (pid $!); teardown frees it"
    ;;
  net)
    secs="${2:?seconds}"
    end=$((SECONDS + secs))
    while [ "$SECONDS" -lt "$end" ]; do curl -s -o /dev/null "http://$HOST:$PORT/${ADK_QA_FILE:-big.bin}" || break; done
    ;;
  energy)
    secs="${2:?seconds}"
    pid="$(pgrep -x AIDiskKeeper | head -1)" || { echo "AIDiskKeeper is not running" >&2; exit 1; }
    top -l "$secs" -s 1 -stats pid,command,cpu,idlew,power -pid "$pid" | awk -v pid="$pid" '
      $1 == pid { n++; cpu += $3; idle += $4; pw += $5 }
      END { if (n) printf "samples %d  avg cpu %.2f%%  avg idle wakeups %.2f/s  avg power %.2f\n", n, cpu / n, idle / n, pw / n }'
    ;;
  teardown-procs|teardown)
    if [ -f "$ROOT/pids" ]; then while read -r p; do kill "$p" 2>/dev/null || true; done < "$ROOT/pids"; rm -f "$ROOT/pids"; fi
    if [ "$1" = teardown ]; then rm -rf "$ROOT"; echo "T50 fixtures removed"; fi
    ;;
  *)
    echo "usage: $0 cpu <sec>|mem <MB>|net <sec>|energy <sec>|teardown" >&2
    exit 2
    ;;
esac
