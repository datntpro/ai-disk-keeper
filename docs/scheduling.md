# Scheduled scans (T22)

A scheduled scan is the **read-only Care Scan** run in the background. It never calls `CleanupEngine`, never changes the selection and never auto-selects anything (invariant 18).

- **Settings → Schedule**: frequency Off / Daily / Weekly (off by default), the two alert thresholds (Safe ≥ 5 GB, AI-tool growth ≥ 2 GB by default), "Skip on battery and Low Power Mode" (on), and "Open at login" (off; `SMAppService.mainApp` only, no LaunchAgent or helper).
- **Timing**: `NSBackgroundActivityScheduler` (`io.github.datntpro.aidiskkeeper.scheduledScan`, 1 h check, utility QoS). `ScanSchedulePolicy` (pure) decides: due when one calendar day/week has passed since `ADK.scheduledLastRun` (UserDefaults). A run missed while the Mac slept fires once at the next check, never several. Turning the schedule on starts the clock; it does not scan immediately.
- **Gating**: a run is deferred while a user scan runs, on battery (if the toggle is on) and in Low Power Mode.
- **Notifications**: permission is requested when the user turns the schedule on, never at launch or at the first alert. At most one alert per run (Safe wins over growth). Clicking it opens Overview. T47's low-space alert is unchanged.
- **Menu bar**: the popover's "Next Care Scan" row shows the next due time while the schedule is on.
- **Deferral has no limit**: a scheduled run keeps deferring while items are selected or a cleanup is open (starting a scan would clear the selection); it runs at the first check after both are clear.
