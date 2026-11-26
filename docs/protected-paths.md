# Protected paths (T04)

`ProtectedPaths.check(path)` is the single gate used by scan (T05) and cleanup (T08). The built-in
table is hard-coded and cannot be overridden; rules may only **add** anchored patterns.

## Semantics

- A path is denied if **either its lexical form or its resolved (symlink-free) form** is denied. This
  covers symlinks into `~/.ssh`, intermediate symlinks that escape home, and `link/..` tricks.
- Any raw `..` component is rejected (`parentTraversal`). Scanners never produce one.
- The pure core `evaluate(raw:resolution:)` does no syscalls. `SystemPathResolver` uses only
  `realpath`/`lstat` (read-only). Nothing is cached: re-check right before acting.
- Comparison runs on a canonical key: `/tmp`, `/var`, `/etc` → `/private/...`;
  `/System/Volumes/Data/X` → `/X`; case-folded; Unicode NFC; split into components.
- Allowed roots: home, `$TMPDIR`, `/private/tmp`. Everything else is `outsideAllowedRoots` or
  `systemLocation`. Roots are injected; this module never reads the real home.
- Reasons are either **hard** or **container**. `protectedLocation` and `containsProtectedPath` mean the
  path itself must never be an item, but it may be scanned *inside*. A hard reason always wins.

- **Root validation (fail closed):** `init` throws `invalidRoot` if a home or `$TMPDIR` form (lexical or
  resolved) has fewer than 2 components, is `/Volumes/<vol>`, equals or contains a system root, or (home
  outside `/Volumes`; always for `$TMPDIR`) lies under one.
- **Glob escaping:** `~`/`$APP_SUPPORT` expansion escapes `\ * ? [ ]` in the home path. Entries in
  `additionalPatterns` are globs: callers embedding literal paths (e.g. `$HOME`, `$TMPDIR`) must wrap
  them in the public helper `ProtectedPaths.escapeGlob(_:)`.

## Pattern classes

1. **Anchored**: absolute. Denies the path, everything below it, and its *ancestors*
   (`~/.claude` is `containsProtectedPath` because of `~/.claude/.credentials.json`).
2. **Exact-only**: only the directory itself (e.g. `~/Documents`); children stay allowed.
3. **Basename**: any component below the allowed root (`.env`, `*.pem`, `.git`, ...).
4. **System roots**: `/System`, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/opt`, `/cores`,
   `/private/etc`, `/private/var/db`, `/private/var/root`, `/Volumes`, `/Network`, `/dev`.

## Table

The authoritative table is `ProtectedPaths.builtInAnchored`, `builtInExactOnly`, `builtInBasenames` and
`systemRoots` in `Sources/DiskKeeperCore/Safety/ProtectedPaths.swift`; it is covered by table-driven
tests. Summary:

| Group | Entries |
|---|---|
| Claude | `~/.claude.json*`, `~/.claude/{settings*.json,.credentials.json,CLAUDE.md,skills,agents,commands,hooks,output-styles,keybindings.json}`, `~/.claude/plugins/{config*,*.json}`, `~/.claude/projects/*/memory` |
| Codex | `~/.codex/{auth.json,config.*,AGENTS.md}` |
| Gemini | `~/.gemini/{oauth_creds.json,settings.json,google_accounts.json,GEMINI.md}` |
| Cursor | `~/.cursor/mcp.json`, `$APP_SUPPORT/Cursor/User/{settings.json,keybindings.json,snippets}` |
| Copilot | `~/.config/github-copilot` |
| Dev credentials | `~/.ssh ~/.aws ~/.gnupg ~/.azure ~/.kube ~/.docker/config.json ~/.config/{gh,gcloud,git} ~/.gitconfig ~/.git-credentials ~/.netrc ~/.npmrc ~/.pypirc ~/.password-store` |
| macOS | `~/Library/{Keychains,Preferences,Mobile Documents,CloudStorage,Mail,Messages}`, `~/.Trash` |
| Docker | `~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw` |
| Other credentials | `$APP_SUPPORT/Claude/claude_desktop_config.json`, `~/.cargo/credentials*`, `~/.config/op`, `~/.vault-token`, `~/.terraform.d/credentials*`, `~/.gem/credentials`, `~/.m2/settings*.xml`, browser `Login Data*`/`Cookies*`/Firefox `logins.json`/`key4.db`/`cookies.sqlite`, `~/Library/Cookies`, `/private/tmp/com.apple.launchd.*` |
| Self | `$APP_SUPPORT/AIDiskKeeper` |
| Exact-only | `~`, `~/Library` and its main subfolders, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Public`, `~/Applications`, `~/Developer`, `~/.cache`, `~/.config`, `~/.local`, `~/.local/share`, `~/orca`, `~/orca/workspaces`, `/private/tmp`, `$TMPDIR` (as an allowed root) |
| Basenames | `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.keychain`, `*.keychain-db`, `id_rsa*`, `id_ed25519*`, `id_ecdsa*`, `id_dsa*`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.credentials.json`, `.git` |
| Media libraries (basename) | `*.photoslibrary`, `*.photolibrary`, `*.musiclibrary`, `*.tvlibrary`, `*.aplibrary`, `*.imovielibrary`, `*.fcpbundle` (matched wherever they live, case/Unicode-folded; plus `~/Library/Mail` above) |

## Known limits

- The guard does not detect hard links or APFS clones; trashing one leaves the other copies intact.
  Since M4 the duplicate engine (T33) handles both (members sharing storage count 0 reclaimable bytes),
  not this guard.
- On a case-sensitive volume, case folding only over-blocks (the safe direction).
- Basenames are narrowed on purpose: `id_*` would match `id_utils/` and `.env*` would match `.envrc`;
  the concrete key and `.env`/`.env.*` names cover the intent.
- Basename rules look only at the candidate's own components, not inside it: a worktree that *contains*
  `.env` or `*.pem` is not denied (T14 must downgrade such worktrees).
- `~/.claude/projects/<proj>` can never be an item (it contains `memory`); T06 must emit per-transcript
  (`*.jsonl`) items.

## Application-bundle exception (implemented in T36)

Safety invariant 15 allows exactly one exception to "everything outside `~`/`$TMPDIR` is protected": trashing
an installed application. T36 implements it as `ApplicationBundlePolicy` (`Safety/ApplicationBundlePolicy.swift`, with a faked-in-tests
filesystem probe in `Safety/AppBundleProbe.swift`). Nothing in `ProtectedPaths` changes for it.

The exception is evaluated **only** when `item.cleanupMethod == .trashApplication`. `ProtectedPaths.check`
stays unchanged for every other caller (scan, rules, other cleanup methods). The check runs at plan time and
again at execute time (after `fastChecks`), comparing (dev, inode) with the plan fingerprint. It cannot
grant more than macOS does: TCC *App Management* (Ventura+) may still refuse the trash, and there is no
privileged helper (D3).

| # | Input | Verdict | Reason code (T36, `CleanupBlocker`) |
|---|---|---|---|
| 1 | `/Applications/Foo.app` (real dir, user-owned, Developer ID, not running) | **allowed for `trashApplication` only** | — |
| 2 | `~/Applications/Foo.app` (same conditions) | allowed for `trashApplication` only | — |
| 3 | `/Applications/Utilities/Foo.app` | denied | `appBundleRefused(notTopLevel)` |
| 4 | `/Applications/Vendor/Foo.app` | denied | `appBundleRefused(notTopLevel)` |
| 5 | `/Applications/Foo.app/Contents/…` or any path inside a bundle | denied | `appBundleRefused(insideBundle)` |
| 6 | `/Applications/Foo.app` that is a symlink (e.g. Safari → cryptex) | denied | `appBundleRefused(symlink)` |
| 7 | resolved path differs from lexical (symlinked parent, firmlink games) | denied | `appBundleRefused(resolvedElsewhere)` (+ `symlinkInParentChain`) |
| 8 | Apple-signed (anchor apple) or under `/System`, or on a sealed volume | denied | `appBundleRefused(appleOrSystem)`; an unreadable signature is `signatureUnreadable` (fail closed) |
| 9 | owned by root/another user (typical App Store install) | denied; UI shows "Move to Trash in Finder" guidance | `requiresAdmin` |
| 10 | running (`RunningAppChecking` true) or unknown (nil) | denied (fail closed); also any process running from inside the bundle | `appRunning` / `appStateUnknown` |
| 11 | name not ending in `.app` (case-insensitive), or `.app` with no `Contents/Info.plist` | denied | `appBundleRefused(notAnAppBundle)` / `missingInfoPlist` |
| 12 | `CFBundleIdentifier` differs from the item's `trashApplication(bundleID:)` | denied | `appBundleRefused(bundleIDMismatch)`; changed between plan and execute: `identityChanged` |
| 13 | any action other than Trash (permanent delete requested) | denied, whatever the Settings say | `appBundleRefused(permanentDelete)` |
| 14 | `/Applications` or `~/Applications` itself | denied | `appBundleRefused(rootItself)` (and the guard's `systemLocation` / `protectedLocation`) |
| 15 | `trashItem` fails with `EPERM` (macOS App Management TCC) | skipped; UI deep-links to Privacy & Security › App Management (`Privacy_AppBundles`) | `needsAppManagementPermission` (`EACCES` → `requiresAdmin`) |

Implementation notes (T36):

- The guard is called for app entries too. Its `systemLocation` verdict is waived only when the lexical parent is
  exactly `/Applications` and every lexical check passed (`ApplicationBundlePolicy.waives`). Every other reason
  (`outsideAllowedRoots`, `protectedPath`, `protectedName`, ...) still blocks as `protectedPath`.
- Checked at plan time and again at execute time: the policy runs, then the bundle + `Info.plist` fingerprint
  (dev/ino, size, mtime, bundle id, owner) is compared with the plan's, then the Trash move happens. The bundle is
  not re-sized at execute time.
- Sealed volume: `statfs` with `MNT_SNAPSHOT`/`MNT_RDONLY` or mount point `/`; unknown = refused. Measured on
  macOS 27.2: `/Applications` is on `/System/Volumes/Data` (rw); `/System/Applications` and `/` are on `/`
  (snapshot, read-only).
