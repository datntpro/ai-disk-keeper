#!/usr/bin/env bash
# Manual QA fixtures for T37b (Quit / Force Quit in the Uninstaller). Tart VM ONLY: there is no override.
#   scripts/qa/T37b.sh setup                  builds the ADKQA fixture apps (swiftc, unsigned) and registers them
#   scripts/qa/T37b.sh launch <kind>          quitter | saver | hung | helper | twin | relauncher
#   scripts/qa/T37b.sh status                 what ADKQA is running
#   scripts/qa/T37b.sh teardown               stops everything and removes exactly what setup created
set -euo pipefail

if [[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" != "1" ]]; then
  echo "refusing: this script quits and launches real processes and only runs inside a VM" >&2
  exit 1
fi

APPS="$HOME/Applications"
WORK="$HOME/ADKQA-T37b"
AGENT="$HOME/Library/LaunchAgents/com.adkqa.relauncher.plist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
QUITTER="$APPS/ADKQA Quitter.app"; SAVER="$APPS/ADKQA Saver.app"; HUNG="$APPS/ADKQA Hung.app"
HELPER="$APPS/ADKQA Helper.app"; RELAUNCH="$APPS/ADKQA Relaunch.app"
HELPER_AGENT="$HELPER/Contents/Library/LoginItems/ADKQA Helper Agent.app"

plist() { # app id name [ui-element]
  /usr/bin/plutil -create xml1 "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string "$3" "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string run "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$1/Contents/Info.plist"
  if [[ "${4:-}" == "ui" ]]; then /usr/bin/plutil -insert LSUIElement -bool true "$1/Contents/Info.plist"; fi
}

appkit() { # app id name source-file : a tiny AppKit app, built here
  mkdir -p "$1/Contents/MacOS"
  swiftc -O -o "$1/Contents/MacOS/run" "$4"
  plist "$1" "$2" "$3"
}

setup() {
  mkdir -p "$APPS" "$WORK"
  cat > "$WORK/quitter.swift" <<'SW'
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
SW
  cat > "$WORK/saver.swift" <<'SW'
import AppKit
final class D: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
    let a = NSAlert(); a.messageText = "Save changes?"
    a.addButton(withTitle: "Save"); a.addButton(withTitle: "Don't Save"); a.addButton(withTitle: "Cancel")
    switch a.runModal() { case .alertThirdButtonReturn: return .terminateCancel; default: return .terminateNow }
  }
}
let app = NSApplication.shared; let d = D(); app.delegate = d
app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true); app.run()
SW
  cat > "$WORK/agent.swift" <<'SW'
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
SW
  appkit "$QUITTER" com.adkqa.quitter "ADKQA Quitter" "$WORK/quitter.swift"
  appkit "$SAVER" com.adkqa.saver "ADKQA Saver" "$WORK/saver.swift"
  appkit "$RELAUNCH" com.adkqa.relaunch "ADKQA Relaunch" "$WORK/quitter.swift"
  # Hung: a shell script that never handles the quit Apple event, so only Force Quit works.
  mkdir -p "$HUNG/Contents/MacOS"
  printf '#!/bin/sh\nsleep 600\n' > "$HUNG/Contents/MacOS/run"; chmod +x "$HUNG/Contents/MacOS/run"
  plist "$HUNG" com.adkqa.hung "ADKQA Hung"
  # Helper: main app + a login-item helper app + a non-LaunchServices CLI that stays behind.
  mkdir -p "$HELPER/Contents/MacOS" "$HELPER_AGENT/Contents/MacOS"
  swiftc -O -o "$HELPER_AGENT/Contents/MacOS/run" "$WORK/agent.swift"
  plist "$HELPER_AGENT" com.adkqa.helper.agent "ADKQA Helper Agent" ui
  # Compiled, not a shell script: a script's process image is /bin/sh, so it would never match the bundle.
  printf 'import Foundation\nwhile true { sleep(5) }\n' > "$WORK/bg.swift"
  swiftc -O -o "$HELPER/Contents/MacOS/adkqa-bg" "$WORK/bg.swift"
  swiftc -O -o "$HELPER/Contents/MacOS/run" "$WORK/quitter.swift"
  plist "$HELPER" com.adkqa.helper "ADKQA Helper"
  for a in "$QUITTER" "$SAVER" "$HUNG" "$HELPER" "$HELPER_AGENT" "$RELAUNCH"; do "$LSREGISTER" -f "$a"; done
  mkdir -p "$(dirname "$AGENT")"
  cat > "$AGENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>com.adkqa.relauncher</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-W</string><string>-a</string><string>$RELAUNCH</string></array>
<key>KeepAlive</key><true/>
</dict></plist>
PL
  echo "setup done: open AI Disk Keeper > Uninstaller and follow docs/apps.md (T37b)"
}

launch() {
  case "${1:-}" in
    quitter) open "$QUITTER" ;;
    saver) open "$SAVER" ;;
    hung) open "$HUNG" ;;
    helper) open "$HELPER"; open "$HELPER_AGENT"; nohup "$HELPER/Contents/MacOS/adkqa-bg" >/dev/null 2>&1 & ;;
    twin) open -n "$QUITTER"; open -n "$QUITTER" ;;
    relauncher) launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || true ;;
    *) echo "usage: $0 launch quitter|saver|hung|helper|twin|relauncher" >&2; exit 2 ;;
  esac
}

status() {
  pgrep -lf ADKQA || echo "no ADKQA process running"
  launchctl print "gui/$(id -u)/com.adkqa.relauncher" 2>/dev/null | head -5 || true
}

teardown() {
  launchctl bootout "gui/$(id -u)/com.adkqa.relauncher" 2>/dev/null || true
  pkill -f ADKQA 2>/dev/null || true
  pkill -f adkqa-bg 2>/dev/null || true
  rm -f "$AGENT"
  for a in "$QUITTER" "$SAVER" "$HUNG" "$HELPER" "$RELAUNCH"; do rm -rf "$a"; done
  rm -rf "$WORK"
  rm -rf "$HOME/.Trash"/ADKQA* 2>/dev/null || true
  echo "teardown done"
}

case "${1:-}" in
  setup) setup ;;
  launch) shift; launch "$@" ;;
  status) status ;;
  teardown) teardown ;;
  *) echo "usage: $0 setup | launch <kind> | status | teardown" >&2; exit 2 ;;
esac
