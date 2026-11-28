#!/usr/bin/env bash
# T23 manual QA fixture for a disposable macOS VM (fake data only).
#   scripts/qa/T23.sh setup | teardown
# Creates ~/ADKQA-T23/junk and, in the user rules folder, good.json (Safe rule on the junk, shown as Review),
# bad.json (syntax error) and evil.json (targets ~/.ssh: the path is dropped). Teardown removes only those files and
# ~/ADKQA-T23; the rules folder is removed only if the script created it (marker).
set -euo pipefail
Q="$HOME/ADKQA-T23"
R="$HOME/Library/Application Support/AIDiskKeeper/Rules"
MARK="$Q/.adkqa-T23-created-rules-dir"
case "${1:-}" in
setup)
  [[ -e "$Q" && ! -e "$Q/.adkqa-T23" ]] && { echo "refusing: $Q exists without marker" >&2; exit 1; }
  mkdir -p "$Q/junk"; touch "$Q/.adkqa-T23"
  head -c 2000000 /dev/zero > "$Q/junk/blob.bin"; touch -t 202001010000 "$Q/junk/blob.bin" "$Q/junk"
  if [[ ! -d "$R" ]]; then mkdir -p "$R"; chmod 700 "$R"; touch "$MARK"; fi
  cat > "$R/adkqa-good.json" <<J
{"schemaVersion":1,"tool":{"id":"adkqa","name":"ADK QA"},"rules":[{"id":"adkqa.junk","title":"QA junk","category":"aiToolData","paths":["~/ADKQA-T23/junk"],"match":{"kind":"self"},"tier":"safe","explanation":"Fake data for QA."}]}
J
  echo '{"schemaVersion":1,' > "$R/adkqa-bad.json"
  cat > "$R/adkqa-evil.json" <<J
{"schemaVersion":1,"tool":{"id":"adkevil","name":"ADK QA evil"},"rules":[{"id":"adkevil.ssh","title":"Evil","category":"aiToolData","paths":["~/.ssh"],"match":{"kind":"self"},"tier":"safe","explanation":"Must never load."}]}
J
  echo "set up. Check: Settings > Rules > Reload shows errors for adkqa-bad and a warning for adkqa-evil; scan shows 'QA junk' as Review (not Safe)."
  echo "Then: Never show this item (gone after rescan, back after Remove); Mark as Keep on a Safe item; disable a rule." ;;
teardown)
  rm -f "$R/adkqa-good.json" "$R/adkqa-bad.json" "$R/adkqa-evil.json"
  if [[ -e "$MARK" ]]; then rmdir "$R" 2>/dev/null || true; fi
  [[ -e "$Q/.adkqa-T23" ]] && rm -rf "$Q"
  echo "torn down." ;;
*) echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
