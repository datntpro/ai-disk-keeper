# Cleanup engine

`CleanupEngine` (in `DiskKeeperCore/Cleanup`) turns a user-confirmed selection into Trash moves and an audit log. It is the only code that mutates the filesystem.

## Flow

1. **`plan(items)`** is a dry run. It changes nothing (no Trash move, no audit file). Each item gets an action, any blockers, and a fingerprint (device, inode, kind, owner). The plan id is recorded as issued.
2. The UI shows the plan. The user confirms.
3. **`execute(plan)`** runs an issued, unexpired plan **exactly once** (default lifetime 15 minutes). A plan is single-use even if the run fails part-way. Execution is sequential, so audit order is deterministic.

**Plan binding.** The engine keeps the full plan it issued. `execute` requires the passed plan to be equal to it (id, timestamps, every entry, blocker and fingerprint) and otherwise throws `planModified` before touching anything. So a caller cannot add, remove or edit entries, or clear plan-time blockers; only exactly what was shown and confirmed can run. Pass the `CleanupPlan` value returned by `plan()`: a plan re-decoded from JSON loses sub-millisecond date precision and will be refused. (This tightens the original issue text, where a tampered plan was caught per item by re-validation.)

**Serialized runs.** `execute` calls are serialized per engine (a second call waits for the first), because runs share one audit log and an actor is reentrant across `await`. `AuditLog` open/close is also reference-counted. No item is acted on unless the log is open for that run.

**Expiry.** A plan expires after its lifetime on the wall clock *and* on a monotonic clock, and a plan whose age is negative (clock set back) is treated as expired.

Per-item failures never abort the batch. Cancellation is honoured between items, never mid-item.

## Blockers

| Code | Meaning |
|---|---|
| `keepTier` | Tier is Keep. |
| `notActionable` | Cleanup method is `none` (report only). |
| `methodNotSupported` | `trashWorktree` has no performer yet. |
| `toolCommandUnavailable` | A `.toolCommand` item but no performer is installed (fail closed). |
| `toolCommandNotAllowed` | The command is not on the compiled-in allowlist, or its arguments are not the ones bound to the item. Every JSON-rule `toolCommand` lands here. |
| `toolUnavailable` | The tool's executable is missing, failed the owner/mode checks, or differs from the one shown in the dry run. |
| `toolNotRunning` | The tool's service (for example a container runtime) is not running. |
| `inUseByTool` | The tool reports the object is in use right now. |
| `protectedPath` | The protected-path guard (T04) denied the path. |
| `missing` | Item no longer exists. |
| `isSymlink` | Item is a symlink. |
| `notOwnedByUser` | Owner differs from the current user. |
| `symlinkInParentChain` | The parent directory resolves somewhere else (a swapped parent). |
| `identityChanged` | Device, inode or kind differs from the plan-time fingerprint. |
| `changedSinceScan` | Newest mtime later than scanned (+2 s), or allocated bytes differ by more than max(1 MiB, 5 %). A missing scanned mtime fails closed. |
| `appRunning` / `appStateUnknown` | `requiresAppQuit` app is running, or the checker could not tell (fail closed). |
| `nestedInAnotherItem` | Overlaps an earlier executable item (avoids trashing a parent then failing on its child, and double-counted bytes). |
| `duplicate` | Same item id selected twice. |
| `permanentDeleteDisabled` | Permanent delete requested but the Settings switch is off. |
| `sizingFailed` | Re-measuring failed. |
| `wouldRemoveAllCopies` | No copy would be left: every copy of a duplicate group is selected (or lies under another selected item, of any category, e.g. a folder), or none of the unselected copies still holds the group's content. Keep at least one. |
| `survivorChanged` | Execute time: none of the copies that were to stay passes the survivor check any more (deleted, replaced, edited, or already trashed in this run). |
| `duplicateGroupUnknown` | A duplicate item without its group (`plan(_:)`, or an unknown `groupID`, or a path that is not a member of the group). Fails closed. |

## Duplicate groups (keep-one)

PLAN invariant 13, decision N6. `plan(_:)` keeps its signature and treats every duplicate item (category `duplicate` or a `dup:` group id) as unknown, so it blocks them with `duplicateGroupUnknown`. A UI that offers duplicates calls `plan(_:duplicateGroups:)` with the `DuplicateGroup`s it got from `DuplicateFinder`, keyed by `ScanItem.groupID`. The check needs the whole selection, so it lives in the engine and not in `ItemValidator`, which sees one item.

At plan time, per group: the *unselected* members (compared with `PathCanonicalizer.key`) are verified with `lstat` (same device and inode, regular file, same size, mtime within 2 s) and a **partial digest** (SHA-256 of size ‖ first 64 KiB ‖ last 64 KiB, 128 KiB read) equal to the group's. A copy that equals, or lies below, the path of **any** item in the plan (any category, folders included) is not a survivor either, and neither is a copy sharing the inode of a selected one (forged groups); the same claim is re-checked at execute time, so the result does not depend on item order. A hard-link name of a selected member is the same inode and never counts as a survivor. If no member survives, every selected member of the group gets `wouldRemoveAllCopies`; otherwise each selected entry carries the same `DuplicateSurvivorSet` (`entry.survivors`).

At execute time, right before the move, at least one survivor must pass the same check and must not have been trashed earlier in this run. Otherwise the entry is skipped with `survivorChanged`. This closes the race where the keeper is deleted in Finder between plan and execute, and the one where two selected members name each other as survivors. There is **no full re-hash** at execute (cost): partial digest + identity + mtime is the documented trade-off. **Residual risks (accepted):** an edit in the middle of a survivor that keeps its size and mtime passes the execute gate (no full re-hash, see above); the engine trusts the `DuplicateGroup` it is given beyond the inode check; media files outside the protected library packages (e.g. `~/Music/Music/Media.localized`) are in scope for the finder. `survivors` is part of the plan, so tampering with it gives `planModified`. Design notes: [duplicates.md](duplicates.md).

## Re-validation order at execute time

Policy checks, then the slow re-size (`changeCheck`), then the fast filesystem checks (`lstat`, `realpath` of the parent, protected-path guard, owner, fingerprint, running app). Fast checks run **last** so the window between the final check and the action is as short as possible. Re-validation is defence in depth against changes to the *filesystem* after planning; changes to the *plan itself* are rejected earlier by plan binding.

## Residual TOCTOU window

Between the last `lstat`/`realpath` and the rename there is still a small gap. After a Trash move, the resulting item's `(device, inode)` is compared with the fingerprint; a mismatch is reported as `failed` and audited. We never "restore" automatically. Closing the gap fully would need acting through an `O_NOFOLLOW` parent fd, which `FileManager.trashItem` does not support. This is a known limitation. **Permanent delete has no such protection at all**: there is no post-check, and `FileManager.removeItem` follows a parent symlink swapped in after `realpath`. It is off by default and needs two switches; before the UI exposes it, delete through an `O_NOFOLLOW` parent fd (`openat`/`unlinkat` or `removefileat`). (Items moved across volumes get a new inode and will also be reported as a mismatch.)

## Permanent delete

Off by default. It needs both `requestPermanentDelete` (this run) and `permanentDeleteEnabled` (the Settings switch). The UI owns the second confirmation.

## Audit log

`~/Library/Application Support/AIDiskKeeper/audit.jsonl`, directory 0700, file 0600, opened `O_APPEND | O_NOFOLLOW`, one JSON line per record, `fsync` after each. If the log cannot be opened, `execute` throws `auditLogUnavailable` **before any action**. If a write fails mid-run, the remaining items are `notAttempted` and the report carries `auditFailure`. `notAttempted` items write no line.

Fields (schema version 1): `schemaVersion`, `timestamp`, `runID` (plan id), `itemID`, `path`, `bytes`, `action`, `result` (`trashed` | `deleted` | `skipped` | `failed`), `trashPath`, `ruleID`, `tool`, `reasons` (blocker codes for skipped; an app refusal is `appBundleRefused:<refusal>`), `error`, and `bundleID` (optional, present for every app uninstall entry; additive, schema stays 1).

**Quit lines (T37b).** The Uninstaller also appends `{"kind":"appQuit", ...}` lines to the same file when it asks a running app to quit (`mode` `graceful` or `force`; `phase` `requested` then `result`; `result` `quit` | `stillRunning` | `refused`), with `flowID`, `bundleID`, `appPath`, `pids`, `instanceCount`, `reasons`, `error`. They are written by `AuditLog.appendQuitEvent` (a second `AuditLog` instance on the same file is fine: `O_APPEND`, one `write` per line, fsync). `AuditLog.read` decodes `AuditRecord` only and skips them. A force quit is fail-closed: if the `requested` line can't be written, nothing is force quit.

## Uninstalling an app (`trashApplication`, T36)

Handled by `ApplicationBundlePolicy`, not the generic path/owner checks: see `docs/protected-paths.md`. New blockers:
`appBundleRefused(<AppBundleRefusal>)`, `requiresAdmin(bundleID)` (root-owned, remove in Finder; `EACCES` from the
Trash maps here too) and `needsAppManagementPermission(bundleID)` (`EPERM`, macOS App Management; deep link
`SystemSettingsLinks.appManagement`). The action is always Trash: with `requestPermanentDelete` an app entry is
blocked (`appBundleRefused(permanentDelete)`) and the remover is never called. `CleanupEngine.init(appPolicy:)`
defaults to nil, which blocks every app entry. The size/mtime change check is replaced by the bundle + `Info.plist`
fingerprint, and `freedBytes` stays "up to".

## Known limits

- The guard checks path components only, not the *contents* of a tree. A planned directory that later gains `.git`, `.env` or keys is caught only by the mtime/size change check, which does not defend against deliberately forged mtimes.
- If the audit append fails after an action, that action is in the report but not in the log (remaining items are `notAttempted`). A future improvement is writing an "intent" line before each action.

## Integration notes

- `RunningAppChecking` must be injected by the app target (T10, via NSWorkspace). The core default reports "unknown", so items that require an app to be quit stay blocked until then.
- `CleanupReport.freedBytes` is an upper bound: hardlinks and APFS clones may free less (see `FileSizer`, T02).

## Tool commands (invariant 19)

Some objects are not files (a container image, a simulator). Their scanner reports a **virtual item** whose path is
`/.aidiskkeeper-virtual/<namespace>/<target>/<kind>/<id>`. That root never exists on disk and sits outside every
allowed root, so only a scanner whose `virtualNamespace` equals the item's namespace may report it, and only with a
`toolCommand` (or `none`) method. Virtual items have no file checks and no Reveal in Finder.

`ToolCommandPerformer` is the only way a `.toolCommand` item runs:

1. **Match.** Exactly one compiled-in, destructive `ToolCommandSpec` must name the command and the item's rule id, the
   target kind must match, the arguments must match the template token by token, and `spec.bind(item)` must equal the
   arguments. The argv that runs is `bind(item)`, never the method's arguments on trust. The built-in list is empty
   until a tool adds its specs.
2. **Resolve.** The executable comes from absolute candidates (no `PATH`, no `which`). Its `realpath` must be a regular,
   executable file; the file and its parent directory must be owned by root or the user and not group/world-writable.
3. **Re-validate** with the spec's own check (fresh at execute time, a per-plan cache at plan time).
4. **Run** with no shell, working directory `/`, and exactly the environment the spec returns (a fixed `PATH`, `LC_ALL`,
   `HOME` and tool keys). stdout is capped at 64 KiB, stderr keeps its last 64 KiB, and a timeout terminates the whole
   process group.
5. **Verify** with the spec's optional post-check.

The dry run stores a `ToolCommandSnapshot` (executable, argv, environment) in the plan entry and shows the command
verbatim, labelled "can't be undone": these items do not go to the Trash. At execute time the executable is resolved
again and must equal the snapshot, otherwise the entry is skipped (`toolUnavailable`) and the command is not run.

Each run appends one audit line with `command` (absolute executable + argv), `exitStatus`, `durationMs`, `stderrTail`
(≤ 2 KB) and `toolTarget`; `result` is `ran`. Skipped and failed entries carry `command` too. These fields are
additive (`schemaVersion` stays 1). A JSON rule that declares `toolCommand` still decodes, but is refused at plan time
with `toolCommandNotAllowed`.
