# System monitor (T50)

The menu bar item stays **one** `MenuBarExtra`. Besides free disk space it can show CPU, memory and network throughput,
and its popover has a System section with 1 / 5 minute sparklines. Everything is read-only and uses public APIs only
(`host_statistics`, `host_processor_info`, `host_statistics64`, `sysctl`, `getifaddrs`, `URLResourceValues`,
`proc_pid_rusage`): no root, no helper, no child process, no private framework.

## What shows where

| | Menu bar | Popover |
|---|---|---|
| Disk free | text next to the glyph (`menuBarShowsFreeSpace`, T47) | T47 disk block |
| CPU % | opt in | value, sparkline, per-core strip (P / E cores), user / system / peak |
| Memory | opt in | value, pressure pill, App / Wired / Compressed bar, swap |
| Network ↓↑ | opt in | both rates, mirrored chart, busiest interface |
| Top processes | – | opt in (Settings), own processes only, read-only, "Activity Monitor ↗" |

Default after an update: **nothing new in the bar** (glyph, optional free space, pixel-identical to T47) and zero extra wakeups.

## Styles and width

Settings → Menu bar → style: **Glyph** (T47), **Readout** (default once a metric is in the bar), **Ridge**, **Live strata**.
The whole item is one template `NSImage` drawn by `MenuBarLabelRenderer` (monochrome; the menu bar tints it). Width budget
**140 pt** including the 18 pt glyph; each cell reserves the width of its widest string, so digits never move the item.
When the chosen set doesn't fit, `MenuBarLayout` steps down: drop separators and the ↑ half of a quiet network cell →
Ridge without values → Live strata. The Settings width preview calls the same function. Network interfaces `lo, utun, ipsec,
awdl, llw, bridge, ap, gif, stf, anpi, vmenet` are excluded (VPN / virtual links would double-count).

## Sampling (one timer)

`MonitorScheduler` owns one `Task` loop; a demand change cancels the sleep, never adds a timer. `SamplingPolicy.plan` (pure):

| State | Sampled | Interval |
|---|---|---|
| Mac asleep | nothing | – |
| Item hidden, display asleep, or popover closed with nothing in the bar | disk only | 60 s |
| Popover closed, metrics in the bar | those metrics | 5 s (2 / 5 / 10 / 30) |
| Popover open | all enabled + per-core | 2 s; processes every 2nd tick, only while expanded |

Per tick: ≤ 4 cheap reads, one off-main task, one main-actor update; the label re-renders only when its content changed.
Never per tick: `StorageModel` refresh (once per popover open), file walks, child processes. History is in memory only
(150 samples / 5 min per metric).

## Tests and QA

`MonitorSchedulerTests`, `MonitorTickWorkTests` (fake samplers + virtual time), `LiveSamplerCostTests` (median tick < 2 ms;
`ADK_SKIP_PERF=1` skips), `SystemMonitorLintTests` (banned symbols), layout / renderer / render / settings tests.
VM QA: `scripts/qa/T50.sh` (`cpu`, `mem`, `net`, `energy`, `teardown`; refuses outside a VM).

See also [host-monitor.md](host-monitor.md): disk I/O per worktree and agent, and the free-space trend.
