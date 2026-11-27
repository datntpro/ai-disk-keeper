# Process control: run in background, pause, resume (H5)

Disk Activity (Activity section) lists the processes writing to the disk. Each row has a `…` menu:

- **Run in background** lowers the process's priority with `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`:
  less CPU and disk time under contention. Session only: it ends when the process exits or you choose **Restore priority**,
  and it is never remembered across launches.
- **Pause…** sends `SIGSTOP`. The process freezes; **Resume** (or the timer) sends `SIGCONT`.

Both open a confirmation sheet first: the tree (the process and its children, unless you untick "Include child processes"),
a per-row refusal when a process may not be touched, the auto-resume time and the warnings. **Cancel is the default button for
pause.** Resume and Restore priority are one click: they only undo what this app did.

## Safety

| Rule | Detail |
|---|---|
| Signals | `SIGSTOP` and `SIGCONT` only. `LiveProcessSignaling.signal` returns `EINVAL` for any other signal and for pid ≤ 1 (so `kill(-1, …)` and process-group forms are impossible). No `SIGKILL`/`SIGTERM`, no `renice`, no `task_for_pid`, no root, no `taskpolicy`/`kill` subprocess. |
| Who | Own uid only; never pid ≤ 1, this app or any of its ancestors; never an executable under `/System`, `/usr` (except `/usr/local`), `/sbin`, `/bin`, `/Library/Apple`; never `WindowServer, loginwindow, Finder, Dock, SystemUIServer, ControlCenter, coreaudiod, launchservicesd`; a process whose path can't be read is refused. |
| GUI apps | `NSRunningApplication.activationPolicy == .regular` (Orca included): background allowed, pause refused. |
| Trees | `descendants(of:)` from a fresh table; each member runs through the policy on its own. Pause parent first, then children (BFS); resume children first (deepest first). |
| Identity | `(pid, startID)` is re-read from a fresh table right before every signal; a mismatch sends nothing (`identityChanged`). A resumed entry whose process was replaced is dropped without a signal. |
| Resume is never blocked | Resume and restore apply only the own-user / pid ≤ 1 check, so a process this app stopped can always be continued. |
| Auto-resume | Every pause stores `resumeAt` (default 15 min, setting 1–60, never "forever") in `paused.json` (mode 0600) **before** the signal. A 5 s timer runs only while something is paused or watched. |
| Quit | `applicationShouldTerminate` answers `.terminateLater`, resumes everything, then replies. |
| Crash | At launch, entries still `SSTOP` with the same `startID` are offered: **Resume all** (default) or **Leave paused** (the clock restarts). Others are dropped. |
| Audit | One `processControl` line per process in `audit.jsonl` (`action`, `pid`, `name`, `root`, `result`, `errno`). History shows them (filter **Processes**); they never count toward bytes. |

## Keep new child processes in background

Ticking the option on the background sheet remembers the picked roots (in memory only). Every 5 s every new descendant is
backgrounded too (through the policy, audited once per pid); a root that exits drops out. Whether `PRIO_DARWIN_BG` is
inherited across fork/exec is not assumed: the VM QA records the answer below.

QA result (fill in after `scripts/qa/H5.sh`): _not yet recorded_.

## Pieces

`Process/ProcessControl.swift` (policy, `ProcessController` actor, `LiveProcessSignaling`), `Process/PausedProcessStore.swift`,
`Cleanup/AuditLog.swift` (`ProcessControlAuditRecord`), `Cleanup/AuditHistory.swift` (`.process` entries),
`AppSettings.autoResumeMinutes`; UI in `Modules/Activity/ProcessControl*.swift`, Disk Activity, the popover's
"N paused – Resume all" row, History and Settings → General.
