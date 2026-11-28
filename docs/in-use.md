# In-use detection (T20)

Items that something is using right now, or that changed in the last hour, are never offered as Safe or Review and
are refused again at cleanup time.

## Sources

One snapshot of the user's processes, libproc only (no `lsof`, no subprocess, no root, no `task_for_pid`):

| What | Call |
|---|---|
| Process list, uid, name, **working directory** | `LibprocProcessTable` (`PROC_PIDTBSDINFO`, `PROC_PIDVNODEPATHINFO`), the same walker the host monitor uses |
| **Open files** | `Safety/OpenFileIndex.swift`: `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO` (vnode descriptors only) |
| **Memory-mapped files** | `PROC_PIDREGIONPATHINFO` walk, file-backed regions only (a mapping outlives its closed fd; this also covers loaded dylibs) |
| **Running executable** | `ProcessRecord.executablePath` (`proc_pidpath`): a directory holding a live binary is in use |
| Newest modification time | the scan's `lastModified` / the execute-time re-size |

Scope: **own uid only**. Processes of other users fail with `EPERM` and are skipped, as are pid ≤ 1 and this app.
A path is "held" when a process's cwd or an open file is **equal to or inside** the item (compared as `PathKey`:
case-folded, `/tmp` = `/private/tmp`, and the item's lexical and `realpath` spellings). `/a/bc` does not hold `/a/b`;
an open parent does not hold its children. Every path is indexed, not only those under `$HOME`: filtering by root would
let an item on another volume look free.

## At scan time (`InUseAdjuster`)

An `ItemAdjuster` runs once over the finished list (`ScanEngine(adjusters:)`), then the engine emits
`ScanEvent.itemsAdjusted` and the terminal result already holds the adjusted items.

* held → `tier = .keep`, `flags ∋ .inUse`, `inUseBy` (process name) and `inUsePID`.
* newest mtime < 1 h before `context.now` → `.keep` + `.inUse`, no `inUseBy` ("Modified in the last hour").
* Left alone: Keep items, `.trashApplication` items (the Uninstaller has its own running check) and virtual items
  (their tool refuses in-use objects itself).
* Process list unreadable → nothing changes and one `.inUseUnknown` warning.
* An adjuster may only move a tier toward Keep and may not change an id, path, size or cleanup method or add items;
  `AdjusterValidation` discards the whole output of one that does and adds an `.adjusterRejected` warning.

The explanation text is never edited: the UI composes "In use by tail (process 123)" from `inUseBy`/`inUsePID`.

## At cleanup time (`ItemValidator`)

Never uses the scan's snapshot. `plan` takes one fresh snapshot; `execute` takes another right before the first
removal and replaces it when it is older than 5 s. For every file item (apps and virtual tool items excepted):

| Blocker | When |
|---|---|
| `inUse(process, pid)` | a process holds the item |
| `inUseUnknown` | the process list is unreadable: **fail closed**, nothing is removed |
| `modifiedRecently` | newest mtime in the tree (from the execute-time re-size) is under an hour old, or in the future |

`CleanupEngine.makeDefault` always wires the live source. The `CleanupEngine` initializer takes `inUse: nil` only for
tests that never read real processes.

## Timing

One snapshot is a `proc_listallpids` walk plus one fd-table read per process. Measure on your machine with
`ADK_BENCH=1 swift test --filter InUseDetectorBenchmarkTests` (budget: under 2 s).

## Limits

An fd or region table the kernel refuses to read (`EPERM`) makes the whole snapshot unreadable: scan time adds the
`.inUseUnknown` warning, cleanup time blocks with `inUseUnknown`. A process that exited meanwhile (`ESRCH`) is skipped.

A process that is not running yet cannot be seen, a file opened and closed between snapshots is invisible, and
processes of other users or system daemons are out of scope. The 1 h rule covers the usual "tool wrote to it a moment
ago" case; the Trash move itself is not atomic with the check.
