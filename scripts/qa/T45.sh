#!/bin/bash
# T45 QA fixtures. Everything lives under ADKQA paths; teardown removes exactly those.
#   scripts/qa/T45.sh setup        create the fixtures (Safe, Review and duplicate items)
#   scripts/qa/T45.sh run-app      launch the fake "ADKQA Runner" app (bundle id com.adkqa.runner): cache3 then
#                                  shows "ADKQA Runner is running — quit it first"
#   scripts/qa/T45.sh quit-app     quit it again
#   scripts/qa/T45.sh teardown     remove everything, including the ADKQA items in the Trash
#
# What scans as what (tier rules: system.app-caches, claude-code.transcripts, duplicates.copy):
#   ~/Library/Caches/com.adkqa.cache1|cache2|runner  Safe    (app cache older than 1 day; setup backdates it 5 days)
#   ~/.claude/projects/-ADKQA/adkqa-old.jsonl        Safe    (transcript older than 30 days)
#   ~/.claude/projects/-ADKQA/adkqa-review.jsonl     Review  (transcript 7–30 days old)
#   ~/ADKQA-T45/dup/{a,b,c}/adkqa-dup.bin            Review  (three identical 3 MB copies: Duplicates, keep one)
#   ~/ADKQA-T45/changeme                             plain file for "changed since scan" (edit it or cache1/blob)
# A fresh scan is needed after setup. Never run this against anything but a QA VM or a throwaway account.
set -euo pipefail

CACHES="$HOME/Library/Caches"
CACHE1="$CACHES/com.adkqa.cache1"
CACHE2="$CACHES/com.adkqa.cache2"
CACHE3="$CACHES/com.adkqa.runner"
TRANSCRIPTS="$HOME/.claude/projects/-ADKQA"
ROOT="$HOME/ADKQA-T45"
RUNNER="$HOME/Applications/ADKQA Runner.app"

# touch -t stamp for "N days ago"
ago() { date -v-"$1"d +%Y%m%d%H%M; }

case "${1:-}" in
  setup)
    for d in "$CACHE1" "$CACHE2" "$CACHE3"; do
      mkdir -p "$d"
      dd if=/dev/urandom of="$d/blob" bs=1m count=50 2>/dev/null
      touch -t "$(ago 5)" "$d/blob"
      touch -t "$(ago 5)" "$d"
    done

    mkdir -p "$TRANSCRIPTS"
    dd if=/dev/urandom of="$TRANSCRIPTS/adkqa-old.jsonl" bs=1m count=5 2>/dev/null
    dd if=/dev/urandom of="$TRANSCRIPTS/adkqa-review.jsonl" bs=1m count=5 2>/dev/null
    touch -t "$(ago 60)" "$TRANSCRIPTS/adkqa-old.jsonl"
    touch -t "$(ago 15)" "$TRANSCRIPTS/adkqa-review.jsonl"
    touch -t "$(ago 15)" "$TRANSCRIPTS"

    mkdir -p "$ROOT/dup/a" "$ROOT/dup/b" "$ROOT/dup/c"
    dd if=/dev/urandom of="$ROOT/dup/a/adkqa-dup.bin" bs=1m count=3 2>/dev/null
    # plain cp (no -c): real copies, not APFS clones, so each member keeps its own blocks
    cp "$ROOT/dup/a/adkqa-dup.bin" "$ROOT/dup/b/adkqa-dup.bin"
    cp "$ROOT/dup/a/adkqa-dup.bin" "$ROOT/dup/c/adkqa-dup.bin"
    echo "original" > "$ROOT/changeme"

    mkdir -p "$RUNNER/Contents/MacOS"
    cat > "$RUNNER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.adkqa.runner</string>
<key>CFBundleName</key><string>ADKQA Runner</string>
<key>CFBundleExecutable</key><string>runner</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    printf '#!/bin/bash\nexec sleep 86400\n' > "$RUNNER/Contents/MacOS/runner"
    chmod +x "$RUNNER/Contents/MacOS/runner"
    echo "T45 fixtures ready. Rescan, then select the com.adkqa caches, the -ADKQA transcripts, or the dup copies."
    ;;
  run-app)
    open -g "$RUNNER"
    ;;
  quit-app)
    pkill -f "ADKQA Runner.app/Contents/MacOS/runner" || true
    ;;
  teardown)
    pkill -f "ADKQA Runner.app/Contents/MacOS/runner" || true
    rm -rf "$CACHE1" "$CACHE2" "$CACHE3" "$TRANSCRIPTS" "$ROOT" "$RUNNER"
    rm -rf "$HOME"/.Trash/com.adkqa.* "$HOME"/.Trash/adkqa-* "$HOME/.Trash/ADKQA Runner"*
    echo "T45 fixtures removed"
    ;;
  *)
    echo "usage: $0 setup|run-app|quit-app|teardown" >&2
    exit 2
    ;;
esac
