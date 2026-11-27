# Developer caches and system junk II (T39)

Rule files: `Sources/DiskKeeperCore/Resources/Rules/dev-caches.json` (tool `dev-caches`) and
`system-junk-2.json` (tool `system`, same tool as `system-junk.json`). Format: [rules.md](rules.md).

Tiers: a regenerable cache that costs a re-download is **Review**; a pure build cache is **Safe**; anything
changed in the last day is **Keep** (a build may be running). Xcode archives, iOS backups and installers are never
Safe. DeviceSupport becomes Safe after 180 days unused (decision N12: rules cannot see the Xcode version).

## Simulators (T39b)

Unavailable simulators (their runtime is no longer installed) are found by a small read-only scanner, not a JSON rule:
"unavailable" is runtime state only `simctl` knows, and `~/Library/Developer/CoreSimulator/Devices` holds every simulator.

- The scanner runs `xcrun simctl list devices unavailable --json` (the only read command), and only when the Devices
  folder exists **and** `xcode-select -p` finds developer tools, so it never triggers the "install developer tools" dialog.
- One item per unavailable device folder, measured by its own size, tier **Review** (rule id
  `tool.devtools.simulator.unavailable`). Booted devices and symlinked folders are skipped.
- Cleanup is the allowlisted tool command `xcrun simctl delete <UDID>` (UDID must equal the folder name), shown verbatim in
  the dry-run sheet. Right before it runs, a fresh list must still show the device as unavailable and not booted, and
  afterwards the folder must be gone. It is not moved to the Trash: `simctl delete` also updates CoreSimulator's device set.
- Never run: `delete unavailable`, `delete all`, `erase`, `shutdown`, `boot`, `runtime`. Tests use a fake `xcrun` script only.

## Homebrew (`brew cleanup`)

Not a tool command, and the app never runs `brew`. `brew cleanup` mainly removes old formula versions in the Cellar
(`/opt/homebrew/Cellar`, `/usr/local/Cellar`), which is outside the home folder and so outside the scan guard (invariant 1).
Its other effect, the download cache, is already the reversible Trash rule `dev-caches.homebrew`. That rule's
explanation tells the user to run `brew cleanup` in Terminal for old formula versions.

## Build caches (H7)

Rules in `build-caches.json` (tool `build-caches`) plus one small scanner; the **AI Workspace → Build caches** module lists
them with the `dev-caches.*` rules and the `system.{npm,pnpm,uv,pip,bun}` rules, grouped by tool family. Every cache is
its own item (per project, per image), recency under a day is **Keep**, and there is no wipe-all.
Cleanup is the ordinary Trash path. The app never runs `pnpm`, `tart`, `go`, `npm` or `xcodebuild`.

| rule | what | tier |
|---|---|---|
| `build-caches.xcode-deriveddata` (scanner) | each folder in `~/Library/Developer/Xcode/DerivedData`, except `ModuleCache.noindex` | Safe when the project in `info.plist` `WorkspacePath` is gone **and** the folder is over 7 days old; Review otherwise (also when the path can't be read); Keep when changed in the last day |
| `build-caches.xcode-modulecache` | `DerivedData/ModuleCache.noindex`, shared by all projects | Review (Keep if < 1 day) |
| `build-caches.pnpm-store` | `$PNPM_HOME/store`, `~/Library/pnpm/store`, `~/.local/share/pnpm/store` | Review (Keep if < 1 day). Files are hard-linked into projects, so deleting frees only what no project uses |
| `build-caches.tart-oci` | one item per image folder, `~/.tart/cache/OCIs/<host>/<org>/<name>` (the folder holds the tag and digest entries; the rule can reach three levels down, not four) | Review (Keep if < 1 day). Symlinked folders are not items and are never followed |
| `build-caches.tart-tmp` | children of `~/.tart/tmp` | Safe when over 1 day old, else Keep |
| `build-caches.tart-vms` | children of `~/.tart/vms` | Review, **report only** (`cleanup: none`): a VM holds user state. Remove with `tart delete <name>` |

The DerivedData scanner reads only `info.plist` (a regular file, at most 64 KiB, never a symlink) and leaves a symlinked
DerivedData folder alone. A project on an external volume that is not mounted counts as present, not gone.
Global DerivedData belongs here; the in-project artifact rules (T15) leave it out.

**Hints** (copy buttons, never executed): `pnpm store prune`, `tart prune --entries=caches --older-than=7`,
`tart delete <name>`, `go clean -cache` (go-build also trims itself after 5 days) and `npm cache verify`.
They are shown above the list for the caches that were found (`BuildCacheCatalog`).

Sources: https://pnpm.io/cli/store, https://tart.run/quick-start/ (cache and `prune`), https://docs.npmjs.com/cli/commands/npm-cache,
https://pkg.go.dev/cmd/go#hdr-Remove_object_files_and_cached_files.

## Sources

| rule | source |
|---|---|
| `dev-caches.yarn` | https://classic.yarnpkg.com/en/docs/cli/cache |
| `dev-caches.yarn-berry` | https://yarnpkg.com/configuration/yarnrc#enableGlobalCache |
| `dev-caches.cargo-registry`, `dev-caches.cargo-git` | https://doc.rust-lang.org/cargo/guide/cargo-home.html |
| `dev-caches.go-build` | https://pkg.go.dev/cmd/go#hdr-Build_and_test_caching |
| `dev-caches.go-mod` | https://go.dev/ref/mod#module-cache |
| `dev-caches.gradle`, `dev-caches.gradle-wrapper` | https://docs.gradle.org/current/userguide/directory_layout.html |
| `dev-caches.cocoapods` | https://guides.cocoapods.org/terminal/commands.html#pod_cache_clean |
| `dev-caches.swiftpm` | https://www.swift.org/documentation/package-manager |
| `dev-caches.homebrew` | https://docs.brew.sh/Manpage#--cache |
| `dev-caches.xcode-archives` | https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases |
| `dev-caches.device-support` | https://developer.apple.com/documentation/xcode/running-your-app-on-a-device |
| `dev-caches.simulator-caches` | https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device |
| `dev-caches.xcode-previews` | https://developer.apple.com/documentation/xcode/previewing-your-apps-interface-in-xcode |

The rule format has one `docs` URL per tool (`tool.docs`), not per rule, so the per-rule sources live here.

## `system.app-caches`

Matches `~/Library/Caches/<bundle-id>` (glob `*.*`, directories) with `requiresAppQuit: "{name}"`, so the app that
owns the folder must be quit. `exclude` lists every glob another bundled rule claims under `$CACHES`, plus
`com.apple.*`, `CloudKit`, `com.crashlytics*`, `*.savedState`, `GeoServices`, `familycircled`, updater staging folders (`*.ShipIt`, whose app-quit id would not match a running app) and security/VPN agents (`com.microsoft.wdav*`, `com.fortinet.*`), which are daemons that the quit check cannot see.
`testGenericCachesRuleExcludesEveryOtherCachesRule` fails when a new rule rooted at `$CACHES` is not excluded.

## Permissions

`~/Downloads` and `~/Library/Application Support/MobileSync` are consent-protected. Without Full Disk Access the
scan may show the macOS prompt or the existing `needsFullDiskAccess` warning; nothing new is requested.
