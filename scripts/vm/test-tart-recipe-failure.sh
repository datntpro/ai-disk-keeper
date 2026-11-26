#!/usr/bin/env bash
# Offline test of tart-recipe-create.sh failure paths using a fake `tart` (no VM is created).
#  1. two VMs already running  -> refuses with a clear error, never clones
#  2. boot never becomes ready  -> the clone is stopped and deleted (no leak)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/tart" <<'STUB'
#!/usr/bin/env bash
echo "tart $*" >> "$STUB_LOG"
case "$1" in
  list)
    if [[ " $* " == *" --quiet "* ]]; then echo adk-base; exit 0; fi
    n=${STUB_RUNNING:-0}; out="["
    for ((i=1;i<=n;i++)); do out+="{\"Name\":\"vm$i\",\"Source\":\"local\",\"Running\":true},"; done
    echo "${out}{\"Name\":\"adk-base\",\"Source\":\"local\",\"Running\":false}]" ;;
  exec) exit 1 ;;   # guest agent never answers
  *) exit 0 ;;
esac
STUB
chmod +x "$W/bin/tart"
export PATH="$W/bin:$PATH" STUB_LOG="$W/log" TMPDIR="$W" ADK_MIN_FREE_GB=1 ORCA_VM_INSTANCE_ID=t1
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

: > "$W/log"; STUB_RUNNING=2 "$HERE/tart-recipe-create.sh" 2>"$W/err1"; rc=$?
check "refuses with 2 running VMs"        "[[ $rc -ne 0 ]] && grep -q 'limit is 2' '$W/err1'"
check "does not clone when refused"       "! grep -q '^tart clone' '$W/log'"

: > "$W/log"; STUB_RUNNING=0 ADK_BOOT_TIMEOUT=2 "$HERE/tart-recipe-create.sh" 2>"$W/err2"; rc=$?
check "boot failure exits non-zero"       "[[ $rc -ne 0 ]]"
check "clone was created"                 "grep -q '^tart clone adk-base adk-orca-t1' '$W/log'"
check "failed clone is stopped + deleted" "grep -q '^tart stop adk-orca-t1' '$W/log' && grep -q '^tart delete adk-orca-t1' '$W/log'"
[[ $fail -ne 0 ]] && { echo "--- stderr (boot-failure run)"; cat "$W/err2"; }
exit $fail
