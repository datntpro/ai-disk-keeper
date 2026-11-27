# Host monitor: disk I/O per agent and worktree, free-space trend

H1. Read-only. No subprocess (`lsof`, `ps`, `iostat`, `top` are never run), no root, no `task_for_pid`.

## What it shows

- **Disk activity** (Activity section): whole-disk read/write rate and an approximate busy %, then three tables: by
  worktree, by agent, and the top processes by write rate (name, agent, worktree, rates, bytes written since start).
  Spotlight and Defender rows add a hint to exclude build folders.
- **Menu bar popover**: the three worktrees writing the most (click opens the screen), and a trend row: "Full in about
  2 days at the current rate" or "Free space is stable".
- **Menu bar item**: a badge (circle = low, triangle = critical) and an accessibility label ("Low disk space: 13 % free")
  when free space is under the threshold.

## Sampling

Host load is sampled every **5 s** (the floor) and **only while** the popover or the Disk Activity screen is visible
(and the display and system are awake). There is no background sampling in H1. `MonitorScheduler` starts and stops it
on demand changes; the loop lives in `DiskActivityModel`.

## Pieces (`DiskKeeperCore`)

| File | Role |
|---|---|
| `Process/ProcessTable.swift` | `ProcessRecord`, `ProcessTableSnapshot`, `LibprocProcessTable`: own-uid processes through libproc (`PROC_PIDTBSDINFO`, `PROC_PIDVNODEPATHINFO` for the cwd, `proc_pid_rusage` for `ri_diskio_*`). About 20 to 30 ms for 600 processes. |
| `Process/IORateTracker.swift` | Bytes/s per `(pid, startID)`. A reused pid, a first sighting or a counter that went down gives no rate (never negative). |
| `Process/AgentClassifier.swift` | Name/path table; a child is attributed to the nearest agent CLI ancestor (`node` under `claude` counts for claude). |
| `Process/WorktreeAttribution.swift` | cwd → nearest `.git` below `$HOME` (directory, or a file pointing into `<main>/.git/worktrees/…`). Reads at most 4 KiB of a `.git` file. `$HOME` itself is never a worktree. |
| `SystemMonitor/DiskActivitySampler.swift` | IOKit `IOBlockStorageDriver` `Statistics` (internal drivers; the one with the most traffic). Busy ≈ Δ(read+write request time)/Δt, clamped, labelled approximate: it is queue time. |
| `SystemMonitor/HostLoad.swift` | `HostLoadSampler.tick()` → `HostLoadSnapshot` (processes, by worktree, by agent, unattributed writes = disk − attributed, load average). |
| `Volume/DataVolume.swift` | `/System/Volumes/Data` (fallback `/` only if missing). Free space is measured here. |
| `Volume/FreeSpaceHistory.swift` | 10-minute buckets (minimum free in the bucket), 7 days = 1008 points, `free-space-history.json` (0600, atomic). Written at most once per bucket. |
| `Volume/FreeSpaceTrend.swift` | Linear fit, per D6. |

A process that is born and dies between two ticks (a 25 ms `dd`, most compiler invocations) is never in a snapshot, and
the kernel keeps no child disk-io counter, so its bytes show up only as "Other processes". One born since the previous
tick and still alive counts its whole counter in that interval. A gap longer than 60 s (popover closed) starts a new baseline.

The whole-disk counters count the physical device, the per-process ones count what the kernel attributes to a process, so
"Other processes" is the remainder (short-lived processes, other users, the kernel).

## Free-space rules

- Threshold: default **15 %** for new installs, saved values are kept, range 5–30 %. Critical: under 5 % or under 10 GB.
- Time to full is shown only with at least 6 h of history, a downward slope and r² ≥ 0.5, using the window after the last
  upward jump of more than 1 GB (a cleanup resets it). More than 30 days away is hidden ("stable").
- The notification itself (`LowSpaceMonitor`) is unchanged.

## Privacy

Names, executable paths and cwd only. Command lines are never read or stored. Only the current user's processes are read.

## API for later PRs

`ProcessTable` (§3 of the host-features plan) is frozen: `ProcessRecord`, `ProcessTableSnapshot`, `ProcessTableReading`,
`LibprocProcessTable`, `children/descendants/ancestors(of:)` (ancestors nearest first).
