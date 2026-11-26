# Tart macOS test VM

Disposable macOS VMs ([Tart](https://tart.run)) for testing AI Disk Keeper without touching a real Mac.

```sh
brew install openai/tools/tart          # Tart moved from cirruslabs/cli to openai/tools
scripts/vm/tart-build-base.sh           # once: pulls macos-tahoe-xcode:26.3 (~67 GB download), builds `adk-base`
tart clone adk-base adk-test-1          # copy-on-write, seconds
tart run --no-graphics adk-test-1 &     # or without --no-graphics to see the desktop
tart exec adk-test-1 /bin/bash -lc 'cd ~/ai-disk-keeper && git pull && scripts/vm/seed-fake-ai-data.sh'
tart stop adk-test-1; tart delete adk-test-1
```

- **Orca recipe** `tart-macos` (`orca.yaml`): `create` clones `adk-base`, boots it and starts `orca serve` inside;
  `destroy` deletes the clone. Check with `orca vm recipe doctor tart-macos [--provision]`.
- `seed-fake-ai-data.sh` creates fake `~/.claude`, `~/.cursor`, `~/.codex`, `~/.gemini`, model caches, worktrees
  (clean/dirty/unpushed), node_modules/DerivedData, duplicates, a large old file and `/Applications/FakeVendorApp.app`.
  It **refuses to run outside a VM**.
- Host limits: macOS allows 2 VMs running at once; keep >= 60 GB free (scripts check).
- Guest login is `admin`/`admin` (cirruslabs default); the VM is NAT-only and shares no host folders.
