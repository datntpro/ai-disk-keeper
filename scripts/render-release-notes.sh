#!/usr/bin/env bash
# Render .github/release-notes-template.md into release notes.
#
# scripts/render-release-notes.sh <version> <signing-status> <sha256sums-file> <out.md>
# Works with macOS (BSD) awk: multi-line content is passed through the environment, not awk -v.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in -h|--help) sed -n '2,5p' "$0"; exit 0 ;; esac
[ $# -eq 4 ] || die "usage: render-release-notes.sh <version> <status> <sums-file> <out.md> (see -h)"
VERSION="$1"; STATUS="$2"; SUMS_FILE="$3"; OUT="$4"
[ -f "$SUMS_FILE" ] || die "checksums file not found: $SUMS_FILE"
TEMPLATE="${RELEASE_NOTES_TEMPLATE:-$ROOT/.github/release-notes-template.md}"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

RN_VERSION="$VERSION" RN_STATUS="$STATUS" RN_MIN_MACOS="${MIN_MACOS:-14.0}" RN_SUMS="$(cat "$SUMS_FILE")" \
awk '
  function rep(s, key, val,   i, out) {
    out = ""
    while ((i = index(s, key)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(key)) }
    return out s
  }
  {
    if (index($0, "{{SHA256SUMS}}")) { print ENVIRON["RN_SUMS"]; next }
    $0 = rep($0, "{{VERSION}}", ENVIRON["RN_VERSION"])
    $0 = rep($0, "{{SIGNING_STATUS}}", ENVIRON["RN_STATUS"])
    $0 = rep($0, "{{MIN_MACOS}}", ENVIRON["RN_MIN_MACOS"])
    print
  }
' "$TEMPLATE" > "$OUT"
if grep -q '{{' "$OUT"; then die "unreplaced placeholder in $OUT"; fi
