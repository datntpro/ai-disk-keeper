# Startup Items (T38)

A viewer for launch agents and daemons. It is read-only, except that a user's **own** launch agent whose program no longer exists can be moved to the Trash (through the normal confirmed dry-run plan).

## What is scanned

| Folder | Domain | Actionable |
|---|---|---|
| `~/Library/LaunchAgents` | `userAgent` | only if broken (below) |
| `/Library/LaunchAgents` | `systemAgent` | never |
| `/Library/LaunchDaemons` | `systemDaemon` | never |

Each `*.plist` is read with `PropertyListSerialization` (1 MiB cap). From it: `Label`, `Program` / `ProgramArguments[0]`, `RunAtLoad`, `KeepAlive` (bool or dictionary), `StartInterval`, `StartCalendarInterval`. A plist that can't be parsed, isn't a dictionary or has no `Label` is still listed (`label == nil`, `parseError`), never actionable, never a crash.

## Program state

- `present` / `missing`: an absolute path that does / doesn't exist.
- `unresolvable`: no program, a relative path, or `BundleProgram` (SMAppService, managed by an app). **Not** "broken".

Only `missing` counts as Broken. The signature (`CodeSignatureReading`) is read from the enclosing `.app` if there is one, else from the program, and only when it exists.

## Loaded state

`LaunchctlLoadedState` runs exactly `launchctl print gui/<uid>` (5 s timeout) and parses the `services = { … }` block into running / loaded. `print` is the only subcommand ever used; a test inspects argv through a recording script, and another bans write subcommands and `launchctl` anywhere else in `Sources/`. System daemons are `unknown` (reading `system/` needs root). A timeout, failure or missing tool gives `unknown` for all items plus one warning.

## Removable

`StartupItem.isRemovable` is true only for: user agent, program `missing`, plist owned by the current user, not a symlink, valid label. Its `ScanItem` is `tier .safe`, `category .startupItem`, `ruleID startup.brokenAgent`, `cleanupMethod .trash`. Everything else gets `cleanupMethod .none` / `startup.viewOnly`. `scan()` (for Care Scan) emits only removable items the scan guard allows (fail closed).

Homebrew services (`homebrew.mxcl.*`) show a `brew services stop <name>` hint and a Copy command button; the app never runs it.

## Screen

`Sources/AIDiskKeeperUI/Modules/Startup/`: three filter cards (yours / system-wide / broken), a sortable table, an inspector, a footer with **Review removal…**, and an **Open Login Items settings** deep link (`SystemSettingsLinks.loginItems`).

## QA

`scripts/qa/T38.sh setup|teardown` creates and removes four `com.adkqa` / `homebrew.mxcl.adkqa` plists in `~/Library/LaunchAgents`. It never loads anything into launchd.
