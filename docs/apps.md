# Apps: inventory and leftovers (T35, read-only)

Code: `Sources/DiskKeeperCore/Scanners/Apps/`. Nothing here writes, trashes, runs `launchctl`, `pkgutil` or
`lsregister`, or opens an app executable. Uninstalling is T36; the Applications UI is T37.

## Two outputs

1. **`AppInventoryScanner.inventory()`** returns an `AppInventory` (pure values) through a direct API. App
   bundles are *not* emitted through `ScanEngine`: its guard drops everything outside `~`, and
   `/Applications` is outside `~` (decision N9). `InstalledApp.makeScanItem()` builds the item
   (`category .application`, `tool .apps`, `tier .review`, `groupID "app:<bundleID>"`,
   `ruleID "apps.bundle"`). Until T36 adds the guard exception, `.trashApplication` items are blocked by the
   cleanup engine.
2. **`AppLeftoverScanner`** (id `app-leftovers`) is a normal `Scanner`. It only emits paths under `~/Library`,
   which the guard allows, so Care Scan can run it.

## Which apps can be uninstalled

`InstalledApp.viewOnlyReason` is `nil` only when the app can be offered for uninstall. First match wins:
`apple` (satisfies `anchor apple`), `systemVolume` (under `/System`, lexically or resolved), `symlink` (the
`.app` entry is a link), `notTopLevel` (inside `/Applications/Utilities` or a vendor folder), `notOwnedByUser`
(typically App Store apps, root-owned; the UI shows Finder guidance). View-only apps get
`cleanupMethod .none`. T36's `ApplicationBundlePolicy` re-checks at plan and execute time; this is only the
scan-time verdict. A running app is still listed (`isRunning`); T36 blocks it at plan time.

Signatures are read without validating bundle contents (full validation hashes the whole bundle). Last-used
dates come from Spotlight, "installed anywhere" from LaunchServices. Both, and the signature reader, are
injected; tests never touch the real `/Applications`, Spotlight or LaunchServices.

## Leftover match levels

The level lives in `ScanItem.ruleID` (no extra model fields). Every leftover is `.review`, `category
.appLeftover`, `cleanupMethod .trash`, and is never bulk-selectable.

| ruleID | Meaning | Rule (case/Unicode-folded) | UI |
|---|---|---|---|
| `apps.leftover.exact` | Tied to the app by bundle id | Entry named `<bundleID>` in Application Support, Caches, Containers, HTTPStorages, WebKit, Logs; `<bundleID>.plist` or `<bundleID>.*.plist` in Preferences and `Preferences/ByHost`; `<bundleID>.savedState`; Group Containers `<TEAMID>.<bundleID>`; Cookies `<bundleID>.binarycookies`; a LaunchAgent whose `Label` is the id (or starts with `<id>.`) or whose `Program`/`ProgramArguments[0]` is inside the app bundle | pre-ticked (T37) |
| `apps.leftover.name` | Named like the app, or same developer | Application Support, Caches or Logs entry equal to the app's name or `CFBundleName` (3+ characters, not on the stoplist); any other Group Containers `<TEAMID>.*` | never pre-ticked; copy says it may be shared |
| `apps.leftover.orphan` | The app is gone | See below | never pre-ticked |

Safety rules:

- **Longest bundle id wins**: with `com.foo.app` and `com.foo.app.helper` both installed, helper entries belong
  to the helper.
- **Shared**: a name-level entry that matches two or more installed apps is emitted once, with no group and no
  `requiresAppQuit`, and the explanation says "Used by A and B".
- **Apple**: Apple apps and any `com.apple.*` entry never produce leftovers or orphans. A name equal to an
  installed Apple app's name is never a name match.
- **Stoplist** (vendor-wide or generic names, never even a name match): `apple, com, library, caches, logs,
  default, shared, electron, chromium, google, microsoft, adobe, jetbrains, temp, tmp, data, cache, crashpad,
  sentry, squirrel`.
- Symlinked library entries are ignored. Entries owned by another user are dropped.
- Every match passes the scan guard before it is emitted; protected paths are dropped silently.

### Orphans

All of: a folder or plist in Containers, Caches, HTTPStorages, WebKit, Saved Application State, Preferences
or Application Support whose name is a valid bundle id with 3+ components; not `com.apple.*`; no installed app
claims it (equal, or a namespace parent or child of an installed id); LaunchServices says `false` (unknown is
treated as "not an orphan"); last modified more than 30 days ago, both the entry itself and the newest file
inside it. LaunchAgents are never orphans: broken launch agents are T38's job.

## Permissions (TCC)

Each `~/Library` location is listed once. EPERM on a listing gives one `needsFullDiskAccess` warning, EACCES
one `permissionDenied`; scanning continues. Listing `Containers` is allowed, but sizing another app's
container may hit the macOS "App Data" prompt; those items get `needsFullDiskAccess` and `sizeIncomplete`.

## Running with other scanners

The built-in rules already claim some app caches (for example `system.app-cache.claude`). If both run in one
`ScanEngine` pass, the engine keeps one and drops the other as an overlap, which is harmless. Care Scan (T44)
should run this scanner in its own pass or after the rule scanners.

## Benchmark

`ADK_BENCH=1` on the real `/Applications` (read-only, not in CI): target under 5 s for 200 apps, warm.
