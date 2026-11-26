# Care Scan coordinator (T44)

`DiskKeeperCore/Care/` runs the Care Scan: one read-only pass over every module that produces an event stream and
per-module summaries. Core only; the live UI is T43. Nothing here can clean up anything.

## Stages

Stages run **sequentially**, always in `CareStage.allCases` order, whatever order they are given in:

| Stage | Modules | Notes |
|---|---|---|
| `rules` | aiTools, worktrees, modelsDocker, systemJunk | one `ScanEngine`, so `PathClaimSet` dedupe stays intact |
| `index` | — | `DiskIndexer` → `DiskTree`, emitted as `.artifact(.tree)` |
| `largeOld` | largeOld | needs the tree |
| `duplicates` | duplicates | needs the tree; its own finder, so the rule run never drops duplicate members (N15) |
| `apps` | apps | app bundles directly (N9) + leftovers in their own engine |
| `startup` | startup | no builder here: T43 composes `CareStages.scannerRun(.startup, …)` |

A stage that throws becomes one `.stageFailed` (`ScanWarning.Kind.scannerFailed`) and the rest continue. If `index`
fails, `largeOld` and `duplicates` get `.stageSkipped(.needsTree)`. `cancel()` ends the stream with `.cancelled(partial)`;
items already delivered are kept and later stages never start.

## Numbers

- **Module summary**: the items of that module's own stage, split by tier. Not deduplicated across stages.
- **Totals** (`CareReport.totals`): every physical byte once. First stage in order wins; an item equal to or inside an
  already-counted path is still delivered in `.item` but not added to totals; an item that *contains* already-counted
  paths (a leftover folder after a rule's log file) adds only its bytes minus what is counted below it.
- Duplicates: the suggested keeper is not counted (it frees nothing); a member with `sharedStorage` counts 0 bytes.
- Apps: only uninstallable bundles are listed; view-only ones (Apple, system) have nothing to reclaim.
- Tiers always come from the item. The coordinator never pre-selects: "Clean Safe only" is the UI's job, through the dry-run sheet.

## Growth

`CareHistoryStore` keeps the last 20 completed scans in `Application Support/AIDiskKeeper/care-history.json`
(dir 0700, file 0600, atomic): totals per tool and per module only, no paths. `CareReport.growth` compares against the
latest snapshot with the same `scopeFingerprint` (disabled tools, index scope, project roots; supplied by the UI); it is
nil on the first scan, after a scope change, and on a cancelled scan (which appends nothing). A corrupt file counts as empty.
Writing this file is the only write a Care Scan makes.
