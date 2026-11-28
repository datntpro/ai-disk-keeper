# Machine status for coding agents (`status.json`, `adk status`)

AI Disk Keeper writes a small JSON file every 30 seconds **while the app runs**, so coding agents (Claude Code,
Codex, Orca) can ask "is this Mac running out of disk or overloaded?" before starting heavy work. The `adk`
command reads that file. There is no daemon, no socket and no network: when the app is not running, the file says so.

Settings → General → *Publish machine status for coding agents* (on by default). Turning it off deletes the file.

## Where

| What | Path |
|---|---|
| Status file | `~/Library/Application Support/AIDiskKeeper/status.json` (directory 0700, file 0600, replaced atomically) |
| `adk` in the app | `AI Disk Keeper.app/Contents/MacOS/adk` |
| Optional symlink | `~/.local/bin/adk`, created only by *Install command-line tool…* in Settings; *Remove* deletes it only if it points at an app's `adk` |

## Schema v1

```json
{ "schemaVersion": 1, "generatedAt": "2026-11-27T10:00:00Z", "intervalSeconds": 30, "running": true,
  "generator": { "app": "AI Disk Keeper", "version": "x.y", "pid": 123 },
  "level": "ok|warn|critical",
  "reasons": [ { "code": "lowFreeSpace|fullSoon|highDiskWrites|highLoad|memoryPressure", "message": "Free space 13% (< 15%)" } ],
  "disk": { "volume": "/System/Volumes/Data", "totalBytes": 0, "freeBytes": 0, "freePercent": 13.1,
            "thresholdPercent": 15, "trendBytesPerHour": -1.2e9, "timeToFullHours": 41.0 },
  "io":   { "readBytesPerSec": 0, "writeBytesPerSec": 0, "busyPercent": 12.0, "sampleSeconds": 30 },
  "load": { "loadAverage1": 6.2, "cpuCount": 10, "memoryPressure": "normal" },
  "topWriters": [ { "pid": 1, "name": "claude", "agent": "claude", "worktree": "/path/to/worktree", "writeBytesPerSec": 2.0e6 } ],
  "worktrees":  [ { "path": "…", "repo": "…", "writeBytesPerSec": 0, "processCount": 3, "agents": ["claude"] } ],
  "inventory": null }
```

- Unknown values are `null`, never omitted. At most 10 `topWriters` and 20 `worktrees`. Messages are English.
- `inventory` is `null` until the worktree inventory ships, then `{ "count", "safeToClean", "safeBytes" }`.
- Only your own processes appear, by name, agent and worktree. No command lines, file contents or other users' data.
- `schemaVersion` changes only for breaking changes; readers must ignore unknown keys.
- On a clean quit the app rewrites the file with `"running": false`.

## Levels

| Level | When |
|---|---|
| `critical` | free space < 5 % or < 10 GB, or the disk is full in < 6 h |
| `warn` | free space below the menu bar threshold (default 15 %), disk full in < 48 h, writes > 200 MB/s *sustained*, load average > 0.8 × cores *sustained*, or memory pressure warning/critical |
| `ok` | otherwise |

*Sustained* = two consecutive samples (about a minute). Time-to-full needs six hours of free-space history and a clear downward trend.

## `adk status`

```
adk status [--json] [--worktree PATH] [--max-age SEC] [--quiet]
```

| Exit | Meaning |
|---|---|
| 0 | ok |
| 10 | warn |
| 20 | critical |
| 3 | status missing, older than `--max-age` (default 120 s), or the app is not running |
| 2 | usage error |
| 4 | file unreadable, or a schema version this `adk` does not know |

`--json` prints the file as is. `--worktree PATH` adds that worktree's write rate and processes (PATH may be any folder inside it).
`--quiet` prints nothing; use the exit code. Output is English. `adk` only reads the file: it never starts or wakes the app.

## Example hook (documentation only; AI Disk Keeper installs no hooks)

A coding-agent pre-task hook could refuse heavy work when the disk is critical:

```sh
adk status --quiet --max-age 300
case $? in
  20) echo "disk critical: free space first" >&2; exit 1 ;;
  *)  exit 0 ;;   # ok, warn, or no status (app not running)
esac
```
