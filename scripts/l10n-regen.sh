#!/usr/bin/env bash
# Regenerates the derived Localizable.xcstrings for a PR (see docs/l10n.md).
#   scripts/l10n-regen.sh [--base origin/main] <Txx>...   catalog from base -> --sync -> apply scripts/l10n/<Txx>.vi.py -> --check
#   scripts/l10n-regen.sh --verify                        CI: every vi-file key is in the catalog, no duplicates, prefixes ok
# Then commit the catalog as "[Txx] Resync string catalog".
set -euo pipefail
cd "$(dirname "$0")/.."
CATALOG=Sources/AIDiskKeeperUI/Resources/Localizable.xcstrings
BASE=origin/main

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi
if [[ "${1:-}" == "--verify" ]]; then exec python3 -I scripts/l10n-apply.py --verify; fi
if [[ "${1:-}" == "--base" ]]; then BASE="${2:?--base needs a ref}"; shift 2; fi
[[ $# -ge 1 ]] || { echo "usage: $0 [--base REF] <Txx>... | --verify" >&2; exit 2; }

files=()
for t in "$@"; do
  f="scripts/l10n/$t.vi.py"
  [[ -f "$f" ]] || { echo "error: $f not found" >&2; exit 1; }
  files+=("$f")
done

git show "$BASE:$CATALOG" > "$CATALOG"
python3 -I scripts/l10n-extract.py --sync
python3 -I scripts/l10n-apply.py "${files[@]}"
python3 -I scripts/l10n-extract.py --check
