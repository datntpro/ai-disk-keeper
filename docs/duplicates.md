# Duplicate finder (T33)

`Scanners/Duplicates/` finds byte-identical files in a `DiskTree` (T29) and tells apart *real* copies from APFS clones and hard links, so the app never promises space it cannot free. The keep-one rule is enforced in the cleanup engine: see [cleanup.md](cleanup.md#duplicate-groups-keep-one).

Defaults are PLAN D7: files of at least 1 MB (decimal) in Home, excluding `~/Library` and the media libraries, keeper rule "oldest". Never Safe: every item is tier Review, and nothing is pre-selected in Core.

## Spike: what APFS tells us

Verified on macOS 27.2 (SDK 27.2, APFS, arm64) with a C probe: `getattrlist(path, {commonattr: ATTR_CMN_RETURNED_ATTRS, forkattr: ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT}, FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)`. The kernel packs the attributes in bit order: `PRIVATESIZE` (off_t), `CLONEID` (u64), `EXT_FLAGS` (u64), `CLONE_REFCNT` (u32). `returned.forkattr` is read before any field is trusted.

| File (2 MiB) | privatesize | cloneid | ext_flags | refcnt |
|---|---|---|---|---|
| `a` original, after `clonefile(a,b)` | 0 | X | `0x41` (`EF_MAY_SHARE_BLOCKS\|EF_SHARES_ALL_BLOCKS`) | 2 |
| `b` clone | 0 | X | `0x41` | 2 |
| `c` hard link to `a` | same inode as `a` | X | `0x41` | 2 |
| `d` real copy (`dd`) | 2 097 152 | Y | 0 | 1 |
| `a` after 2 bytes written to `b` | 16 384 | X | `0x01` | 1 |
| `b` after that write | 16 384 | Z (new) | `0x01` | 1 |

- `privatesize` is the bytes freed if this file alone is deleted: it is the reclaimable estimate.
- `EF_SHARES_ALL_BLOCKS` (`0x40`) or `privatesize == 0` means deleting the file frees about nothing.
- A partial clone has `EF_MAY_SHARE_BLOCKS` and `privatesize < allocated`.
- Hard links share an inode, so candidates are de-duplicated by `(dev, ino)` first.
- `VOL_CAP_FMT_CLONE_MAPPING` (volume capabilities) says whether clone ids are tracked (`CloneProbe.volumeTracksClones`).
- **Fallback:** when the attributes are not returned (non-APFS, old volume, error) the file has `CloneInfo.unknown`: it stays actionable and gets `sharedStorage`, its reclaimable bytes are `nil`, and it never counts toward a certain "will free" number.

## Pipeline

1. **Candidates** from the index: `FileRecord`s (regular files ≥ 1 MiB outside packages) of at least `minimumLogicalBytes`. Dropped: records flagged `dataless`, `protected` or `outsideCleanableRoots`; records outside `scopeRoot` or under an excluded root (`PathCanonicalizer.key` prefixes); any path component below the scope root that starts with "." or is `node_modules`, `Pods`, `DerivedData`, `site-packages`. Records folded into a directory by the node budget have no path and are ignored. Then de-duplicated by `(device, inode)`: the first path in sorted order is the member and the other names (any record of that inode, in scope or not) go into `otherLinkPaths`. Rebucketed by size; buckets with fewer than two inodes are dropped.
2. **Partial hash** `SHA-256(UInt64 size BE ‖ first 64 KiB ‖ last 64 KiB)`; groups of one are dropped.
3. **Full hash**, streamed over the whole file in 1 MiB `pread`s; groups of one are dropped.
4. **Clone info** per surviving member: `reclaimableBytes = privatesize`, `sharesStorage = sharesAllBlocks || privatesize < allocated || has other link names || unknown`.
5. **Keeper order**, a stable sort. `.oldest`: birth time ascending (birth time 0 falls back to mtime). `.insideGitRepo`: members whose nearest ancestor (up to the scope root) has `.git` first, then oldest. `.shortestPath`: fewer path components first, then oldest. Ties: oldest, then shortest path, then the canonical path key.
6. **Drop groups that waste nothing:** when every non-keeper shares all its blocks (full clones of one storage) the group frees about 0 bytes and is not emitted (`stats.groupsDroppedAllShared`).

## Hashing I/O

Each job runs on `DispatchQueue.global(qos: .utility)` (a continuation plus `withTaskCancellationHandler`, like `FileSizer`), bounded by an `AsyncLimiter` of `maxConcurrentHashes` (4), so it never blocks the cooperative pool. Per job: switch `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` off for the thread and restore it on exit; `open(O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)`; `fstat` and compare device, inode and size with the record (else `skippedChanged`) and refuse `SF_DATALESS` (else `skippedDataless`); `F_NOCACHE` and `F_RDAHEAD`; `pread` in 1 MiB chunks with one reusable buffer, checking the cancellation flag every chunk; `EINTR` retries; other read errors count as `skippedUnreadable` with one `ScanWarning` per 50 files at most. Never `mmap` (a truncated file would SIGBUS), never `Data(contentsOf:)`.

Complexity: bucketing is O(R log R) for R records. Bytes read are at most the sum of full sizes over partial-colliding groups plus 128 KiB per candidate. Memory is O(candidates) small structs plus 1 MiB per concurrent job.

## Items and the keep-one invariant

`DuplicateScanner` (id `duplicates`) emits one item per member, the keeper included (flag `suggestedKeeper`), so a UI can swap the keeper. Category `duplicate`, tool `files`, tier Review, rule `duplicates.copy`, group id `dup:<first 32 hex of SHA-256>:<bytes>`. A member that shares all its blocks is report-only (`cleanupMethod .none`, flag `sharedStorage`); other sharing members are trashable with `sharedStorage`. The scanner checks every member with the scan guard and file ownership, and skips a group that is left with fewer than two members. The explanations are English defaults; a UI that wants them in the user's language builds them from the group (T34).

**Care Scan (T44, N15):** run `DuplicateScanner` in its own `ScanEngine` run, or call `report(tree:)` directly. Mixed with rule scanners, `PathClaimSet` drops members that sit inside claimed items, such as a worktree. Dropping is safe (survivors are counted only from what the UI holds) but confusing.

The engine side (`plan(_:duplicateGroups:)`, `DuplicateSurvivorSet`, three new blockers) is described in [cleanup.md](cleanup.md#duplicate-groups-keep-one). Core never pre-selects non-keepers and never replaces duplicates with clones (M5).

## Duplicates screen (T34)

`Modules/Duplicates/` shows the finder's groups. Nothing is deleted there: the selection goes to `CleanupCoordinator.review(_:duplicateGroups:)`, so the engine's keep-one check still runs (`wouldRemoveAllCopies`, `survivorChanged`, `duplicateGroupUnknown` show in the cleanup sheet).

- **Keep-one in the UI** (`DuplicateSelection`): every group always shows its kept copy ("Keeps" pill, disabled checkbox). The keeper and report-only copies (full APFS clones) can't be selected, and after any change at least one member of a group stays unselected. There is no select-all. A new keeper (rule change or "Keep this one instead") drops itself from the selection.
- **Keep rule** (Oldest / In a git repo / Shortest path) re-orders the cached groups with `DuplicateGroup.reordered(by:)`, which uses the finder's own comparator (`DuplicateFinder.keeperOrder`). It never hashes again. `reordered(keeper:)` is the manual "Keep this one instead".
- **Honest savings:** a group header shows `group.reclaimableBytes`. The action bar sums only copies that own their storage ("up to"); shared copies count 0, and unknown sizes count 0 with the caption "Some copies may free less".
- **Threshold** 1 / 10 / 100 MB (D7 default 1 MB); a change re-runs the finder. The scan guard and owner filter run through `DuplicateScanner.items(for:rule:pathGuard:userID:)`, the same code the scanner uses, so a member the guard denies is not shown.
- Core's English explanations are not shown; the screen builds localized ones. No "Similar photos" tab until M5.

## Edge cases

| Case | Behaviour |
|---|---|
| APFS full clone | report-only + `sharedStorage`; group dropped if all non-keepers are full clones |
| partial clone | actionable, `sharedStorage`, reclaimable = `privatesize` |
| hard links | one member; other names in `otherLinkPaths`; never survivors for each other |
| same size, different content | split by partial or full hash |
| same head and tail, different middle | split by the full hash |
| dataless (iCloud) | skipped by index flag and by `fstat`; never opened with materialization |
| changed between index and hash | `skippedChanged` |
| sparse files | hashed by content; allocated bytes from the record |
| packages, media libraries, `~/Library`, hidden dirs, `node_modules`… | excluded before hashing |
| case or Unicode variants of a path | compared with `PathCanonicalizer.key` |
| file > 4 GiB | streamed; `Int64` everywhere |
| unreadable (EACCES, TCC EPERM) | skipped + capped warnings |
| zero-length or below 1 MB | never candidates |

## Tests and benchmark

Fixtures live in a `FixtureHome` on the same APFS volume; clone tests skip when `clonefile` returns `ENOTSUP`. `DuplicateFinderCancellationTests` cancels during the full-hash phase and requires `CancellationError` within 200 ms and no leaked descriptors; by default it uses 60 files × 8 MB, and `ADK_BENCH=1` uses the plan's 200 × 20 MB. `ADK_BENCH=1 swift test --filter DuplicateBenchmarkTests` prints the throughput table below (10 000 candidates, about 30 % copies, 1.0–1.5 MB each).

| Measured on an M-series internal SSD (APFS), 4 concurrent hashes | |
|---|---|
| Files written | about 10 000 (7 000 unique + about 3 000 copies), 12.5 GB |
| Candidates after the size buckets | 5 448 in 2 702 buckets |
| Partial / full hashes | 5 448 / 5 406 |
| Groups found | 2 703 |
| Bytes read | 7 611 MB |
| Wall time | 3.43 s |
| Full + partial throughput | **2 222 MB/s** (target ≥ 1 GB/s) |

Files were written just before the run, so some reads may come from the page cache even though hashing uses `F_NOCACHE`; treat the number as an upper bound for a cold disk.
