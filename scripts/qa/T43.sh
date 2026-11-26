#!/usr/bin/env bash
# Manual QA fixtures for T43 (Overview + Care Scan). Run inside the Tart VM, never on the owner's Mac.
#   scripts/qa/T43.sh setup      AI-tool, Large & Old, Duplicates and Startup fixtures (only ADKQA paths)
#   scripts/qa/T43.sh teardown   removes exactly those paths
set -euo pipefail
DIR="$HOME/ADKQA-T43"
CLAUDE="$HOME/.claude/projects/-ADKQA"
CACHE="$HOME/Library/Caches/com.adkqa.cache1"
AGENT="$HOME/Library/LaunchAgents/com.adkqa.broken.plist"

case "${1:-}" in
  setup)
    mkdir -p "$DIR/dups" "$CLAUDE" "$CACHE" "$HOME/Library/LaunchAgents"
    dd if=/dev/zero of="$CLAUDE/abc.jsonl" bs=1048576 count=5 2>/dev/null
    touch -t "$(date -v-60d +%Y%m%d%H%M)" "$CLAUDE/abc.jsonl"
    dd if=/dev/zero of="$CACHE/cache.bin" bs=1048576 count=50 2>/dev/null
    dd if=/dev/zero of="$DIR/big.bin" bs=1048576 count=600 2>/dev/null
    touch -t "$(date -v-1y +%Y%m%d%H%M)" "$DIR/big.bin"
    head -c 2097152 /dev/urandom > "$DIR/dups/a.bin"
    cp "$DIR/dups/a.bin" "$DIR/dups/b.bin"
    cat > "$AGENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.adkqa.broken</string>
  <key>ProgramArguments</key><array><string>/Users/Shared/adkqa-missing-program</string></array>
</dict></plist>
PLIST
    echo "Fixtures created. The first index may raise Desktop/Documents/Downloads prompts: answer Don't Allow once, Allow on a second run, and record both."
    ;;
  teardown)
    rm -rf "$DIR" "$CLAUDE" "$CACHE"
    rm -f "$AGENT"
    echo "Removed the ADKQA-T43 fixtures."
    ;;
  *)
    echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
