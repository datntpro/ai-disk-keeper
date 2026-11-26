# Developer caches and system junk II (T39)

Rule files: `Sources/DiskKeeperCore/Resources/Rules/dev-caches.json` (tool `dev-caches`) and
`system-junk-2.json` (tool `system`, same tool as `system-junk.json`). Format: [rules.md](rules.md).

Tiers: a regenerable cache that costs a re-download is **Review**; a pure build cache is **Safe**; anything
changed in the last day is **Keep** (a build may be running). Xcode archives, iOS backups and installers are never
Safe. DeviceSupport becomes Safe after 180 days unused (decision N12: rules cannot see the Xcode version).

`brew cleanup` and `xcrun simctl delete unavailable` need the `toolCommand` performer (#18) and are tracked in the
follow-up T39b.

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
