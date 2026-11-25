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
| `methodNotSupported` | `trashWorktree` / `toolCommand` have no performer yet. |
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

## Re-validation order at execute time

Policy checks, then the slow re-size (`changeCheck`), then the fast filesystem checks (`lstat`, `realpath` of the parent, protected-path guard, owner, fingerprint, running app). Fast checks run **last** so the window between the final check and the action is as short as possible. Re-validation is defence in depth against changes to the *filesystem* after planning; changes to the *plan itself* are rejected earlier by plan binding.

## Residual TOCTOU window

Between the last `lstat`/`realpath` and the rename there is still a small gap. After a Trash move, the resulting item's `(device, inode)` is compared with the fingerprint; a mismatch is reported as `failed` and audited. We never "restore" automatically. Closing the gap fully would need acting through an `O_NOFOLLOW` parent fd, which `FileManager.trashItem` does not support. This is a known limitation. **Permanent delete has no such protection at all**: there is no post-check, and `FileManager.removeItem` follows a parent symlink swapped in after `realpath`. It is off by default and needs two switches; before the UI exposes it, delete through an `O_NOFOLLOW` parent fd (`openat`/`unlinkat` or `removefileat`). (Items moved across volumes get a new inode and will also be reported as a mismatch.)

## Permanent delete

Off by default. It needs both `requestPermanentDelete` (this run) and `permanentDeleteEnabled` (the Settings switch). The UI owns the second confirmation.

## Audit log

`~/Library/Application Support/AIDiskKeeper/audit.jsonl`, directory 0700, file 0600, opened `O_APPEND | O_NOFOLLOW`, one JSON line per record, `fsync` after each. If the log cannot be opened, `execute` throws `auditLogUnavailable` **before any action**. If a write fails mid-run, the remaining items are `notAttempted` and the report carries `auditFailure`. `notAttempted` items write no line.

Fields (schema version 1): `schemaVersion`, `timestamp`, `runID` (plan id), `itemID`, `path`, `bytes`, `action`, `result` (`trashed` | `deleted` | `skipped` | `failed`), `trashPath`, `ruleID`, `tool`, `reasons` (blocker codes for skipped), `error`.

## Known limits

- The guard checks path components only, not the *contents* of a tree. A planned directory that later gains `.git`, `.env` or keys is caught only by the mtime/size change check, which does not defend against deliberately forged mtimes.
- If the audit append fails after an action, that action is in the report but not in the log (remaining items are `notAttempted`). A future improvement is writing an "intent" line before each action.

## Integration notes

- `RunningAppChecking` must be injected by the app target (T10, via NSWorkspace). The core default reports "unknown", so items that require an app to be quit stay blocked until then.
- `CleanupReport.freedBytes` is an upper bound: hardlinks and APFS clones may free less (see `FileSizer`, T02).
