#!/usr/bin/env bash
# Seed FAKE AI-tool data into the current user's home so AI Disk Keeper has something to scan.
# Intended for the Tart test VM ONLY. Refuses to run on bare metal (kern.hv_vmm_present != 1)
# unless ADK_SEED_FORCE=1 AND ADK_SEED_HOME points at a scratch directory.
# Usage: scripts/vm/seed-fake-ai-data.sh        (inside the VM)
# Sizes are small (~100 MB total) but the directory structure mirrors the real tools.
set -euo pipefail

if [[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" != "1" ]]; then
  if [[ "${ADK_SEED_FORCE:-}" != "1" || -z "${ADK_SEED_HOME:-}" ]]; then
    echo "refusing: not running inside a VM (set ADK_SEED_FORCE=1 and ADK_SEED_HOME=<scratch dir> to test elsewhere)" >&2
    exit 1
  fi
fi
H="${ADK_SEED_HOME:-$HOME}"
OLD="202401010000"   # touch -t stamp used for "old" files
mkdir -p "$H"

# blob <path> <size-in-KB>: dummy file of random-ish bytes
blob() { mkdir -p "$(dirname "$1")"; dd if=/dev/urandom of="$1" bs=1024 count="$2" 2>/dev/null; }
zeros() { mkdir -p "$(dirname "$1")"; dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null; }

echo "== Claude Code (~/.claude)"
C="$H/.claude"
for p in -Users-admin-proj-alpha -Users-admin-proj-beta -Users-admin-orca-workspaces-demo; do
  for i in 1 2 3; do
    f="$C/projects/$p/$(printf '%08x-0000-4000-8000-%012x' $((RANDOM*RANDOM)) $((RANDOM*RANDOM))).jsonl"
    mkdir -p "$(dirname "$f")"
    for n in $(seq 1 200); do
      printf '{"type":"user","message":{"role":"user","content":"fake prompt %s"},"timestamp":"2026-01-01T00:00:%02dZ"}\n' "$n" $((n%60))
      printf '{"type":"assistant","message":{"role":"assistant","content":"fake answer %s lorem ipsum dolor sit amet"}}\n' "$n"
    done > "$f"
  done
done
touch -t "$OLD" "$C/projects/-Users-admin-proj-beta"/*.jsonl
mkdir -p "$C/todos" "$C/shell-snapshots" "$C/memory" "$C/statsig" "$C/ide"
for i in 1 2 3 4 5; do echo '[{"content":"fake todo","status":"completed"}]' > "$C/todos/agent-$i.json"; done
for i in 1 2 3; do zeros "$C/shell-snapshots/snapshot-zsh-$i.sh" 64; done
printf -- '---\nname: fake-memory\ndescription: fake\n---\nhello\n' > "$C/memory/MEMORY.md"
echo '{"theme":"dark"}' > "$C/settings.json"
echo '{"fake":true}' > "$C/.credentials.json.example"   # NOT a real credential

echo "== Cursor / Codex / Gemini"
blob "$H/.cursor/projects/demo/cache.bin" 2048
echo '{}' > "$H/.cursor/mcp.json"
mkdir -p "$H/.codex/sessions/2026/01/01"
for i in 1 2 3; do blob "$H/.codex/sessions/2026/01/01/rollout-$i.jsonl" 512; done
touch -t "$OLD" "$H/.codex/sessions/2026/01/01/"*
echo 'model = "fake"' > "$H/.codex/config.toml"
blob "$H/.gemini/tmp/abc123/logs.json" 256
echo '{}' > "$H/.gemini/settings.json"

echo "== Model caches"
blob "$H/.ollama/models/blobs/sha256-$(printf 'a%.0s' {1..64})" 20480
blob "$H/.ollama/models/blobs/sha256-$(printf 'b%.0s' {1..64})" 10240
mkdir -p "$H/.ollama/models/manifests/registry.ollama.ai/library/fakellama"
echo '{"schemaVersion":2}' > "$H/.ollama/models/manifests/registry.ollama.ai/library/fakellama/latest"
HF="$H/.cache/huggingface/hub/models--fake-org--fake-model"
blob "$HF/blobs/$(printf 'c%.0s' {1..40})" 20480
mkdir -p "$HF/snapshots/main" "$HF/refs"
ln -sf "../../blobs/$(printf 'c%.0s' {1..40})" "$HF/snapshots/main/model.safetensors"
echo main > "$HF/refs/main"
touch -t "$OLD" "$HF/blobs/"*

echo "== Dev junk: node_modules, DerivedData, caches"
for p in proj-alpha proj-beta; do
  mkdir -p "$H/Developer/$p"
  echo '{"name":"'"$p"'"}' > "$H/Developer/$p/package.json"
  for m in left-pad lodash react; do blob "$H/Developer/$p/node_modules/$m/index.js" 1024; done
done
touch -t "$OLD" "$H/Developer/proj-beta/package.json" "$H/Developer/proj-beta/node_modules" || true
blob "$H/Library/Developer/Xcode/DerivedData/Fake-abcdef/Build/Products/Debug/Fake.o" 8192
blob "$H/Library/Developer/Xcode/DerivedData/Fake-abcdef/Index.noindex/DataStore/rec" 2048
blob "$H/Library/Caches/com.fake.vendor/cache.db" 4096
blob "$H/.npm/_cacache/content-v2/sha512/aa/bb/blob" 4096
blob "$H/.cache/pip/http/x/y" 1024

echo "== Duplicates + large old file"
D="$H/Documents/dupes"; mkdir -p "$D/a" "$D/b"
blob "$D/a/report.bin" 4096; cp "$D/a/report.bin" "$D/b/report-copy.bin"; cp "$D/a/report.bin" "$D/report (1).bin"
zeros "$H/Documents/old-vm-disk.img" 51200   # 50 MB "large" file
touch -t "$OLD" "$H/Documents/old-vm-disk.img"

echo "== Orca workspaces with git worktrees (clean / dirty / unpushed)"
if command -v git >/dev/null; then
  # Identity via env only: never touch global git config.
  export GIT_AUTHOR_NAME="Fake User" GIT_AUTHOR_EMAIL=fake@example.invalid
  export GIT_COMMITTER_NAME="Fake User" GIT_COMMITTER_EMAIL=fake@example.invalid
  W="$H/orca/workspaces/demo"; REMOTE="$H/orca/remotes/demo.git"
  rm -rf "$W" "$REMOTE"; mkdir -p "$W" "$(dirname "$REMOTE")"
  git init -q --bare -b main "$REMOTE"
  git clone -q "$REMOTE" "$W/main" 2>/dev/null
  ( cd "$W/main" && echo hello > README.md && git add . && git commit -qm init && git push -q origin main
    git worktree add -q -b clean-wt "$W/clean-wt" && git -C "$W/clean-wt" push -q -u origin clean-wt
    git worktree add -q -b dirty-wt "$W/dirty-wt" && git -C "$W/dirty-wt" push -q -u origin dirty-wt \
      && echo wip > "$W/dirty-wt/uncommitted.txt" && echo more >> "$W/dirty-wt/README.md"
    git worktree add -q -b unpushed-wt "$W/unpushed-wt" \
      && ( cd "$W/unpushed-wt" && echo x > local.txt && git add . && git commit -qm "local only" )
  )
  for wt in clean-wt dirty-wt unpushed-wt; do blob "$W/$wt/node_modules/dep/index.js" 512; done
else
  echo "git not found; skipping worktrees" >&2
fi

echo "== Fake third-party app in /Applications"
# Only inside a real VM does the fake app go to /Applications; test mode keeps it under $H.
if [[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" == "1" ]]; then A="/Applications/FakeVendorApp.app"; else A="$H/Applications/FakeVendorApp.app"; fi
if mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources" 2>/dev/null || sudo -n mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"; then
  [[ -w "$A" ]] || sudo -n chown -R "$(id -un)" "$A"
  cat > "$A/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.fakevendor.app</string>
<key>CFBundleName</key><string>FakeVendorApp</string>
<key>CFBundleExecutable</key><string>FakeVendorApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PL
  printf '#!/bin/sh\nexit 0\n' > "$A/Contents/MacOS/FakeVendorApp"; chmod +x "$A/Contents/MacOS/FakeVendorApp"
  blob "$A/Contents/Resources/assets.bin" 8192
  # leftovers an uninstall scan should find
  blob "$H/Library/Application Support/FakeVendorApp/data.db" 2048
  blob "$H/Library/Caches/com.fakevendor.app/cache.db" 1024
  mkdir -p "$H/Library/Preferences"; echo '{}' > "$H/Library/Preferences/com.fakevendor.app.plist"
else
  echo "cannot write /Applications; skipping fake app" >&2
fi

echo "done. Seeded under $H"; du -sh "$H" 2>/dev/null | tail -1
