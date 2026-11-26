#!/usr/bin/env bash
# Manual QA fixtures for T38 (Startup Items). Run inside the Tart VM, never on the owner's Mac.
#   scripts/qa/T38.sh setup      creates ~/Library/LaunchAgents/{com.adkqa.broken,com.adkqa.valid,com.adkqa.damaged,homebrew.mxcl.adkqa}.plist
#   scripts/qa/T38.sh teardown   removes exactly those four files
# Nothing is loaded into launchd: the files are only written.
set -euo pipefail
DIR="$HOME/Library/LaunchAgents"
FILES=(com.adkqa.broken.plist com.adkqa.valid.plist com.adkqa.damaged.plist homebrew.mxcl.adkqa.plist)

plist() { # label program [extra xml]
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$1</string>
	<key>Program</key><string>$2</string>
$3</dict>
</plist>
XML
}

case "${1:-}" in
  setup)
    mkdir -p "$DIR"
    plist com.adkqa.broken "/Applications/ADKQA Gone.app/Contents/MacOS/x" \
      "	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>14400</integer>
" > "$DIR/com.adkqa.broken.plist"
    plist com.adkqa.valid /bin/echo "" > "$DIR/com.adkqa.valid.plist"
    # Truncated XML: must show as "Can't be read" and never crash the app.
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>Label</key><str' > "$DIR/com.adkqa.damaged.plist"
    plist homebrew.mxcl.adkqa /bin/sleep "	<key>KeepAlive</key><true/>
" > "$DIR/homebrew.mxcl.adkqa.plist"
    echo "Created ${#FILES[@]} fixtures in $DIR"
    ;;
  teardown)
    for f in "${FILES[@]}"; do rm -f "$DIR/$f"; done
    echo "Removed the ADKQA fixtures from $DIR"
    ;;
  *)
    echo "usage: $0 setup|teardown" >&2; exit 2 ;;
esac
