# Disk index (`Index/`)

`DiskIndexer` walks one root (default `~`) once, read-only, and returns an immutable `DiskTree`: a struct-of-arrays
snapshot of sizes, flags and names that the disk map (T30), Large & Old and Duplicates (T33) read concurrently
without locks. It never reads file content, xattrs or Spotlight, never follows symlinks, never crosses volumes and
never descends dataless (iCloud / File Provider) directories. Protected paths are **marked, not hidden**.

## Scopes

| Scope | Root |
|---|---|
| `.home` | `environment.home` |
| `.fullDisk` | `/System/Volumes/Data` (the data volume; see Firmlinks) |
| `.folder(p)` | `p` (absolute, no `..`, else `rootNotFound`) |

The indexer does **not** check Full Disk Access; callers only offer `.fullDisk` once it is granted.
Without it, TCC-protected directories come back as `.needsFullDiskAccess` nodes and the walk continues.

## Byte semantics (identical to `FileSizer`)

* `allocatedBytes` = `st_blocks * 512` of unique inodes **plus every directory's own blocks**; `logicalBytes` = `st_size`
  of unique regular/other files. Hard links count once (first link seen); later links are `.hardlinkRepeat` with 0 bytes.
* Totals are subtree sums: the root equals `FileSizer.sizeBlocking(root)` for allocated, logical, file count and
  newest mtime; every directory node equals `FileSizer` of that directory (absent cross-directory hard links).
* APFS clones are counted at full size (overcount); sparse (`allocated < logical/2`, ≥ 1 MiB) and compressed files are flagged.
* Symlinks have no node and 0 bytes. Mount points are `.otherVolume` (0 bytes, listed in `stats.skippedMountPoints`).
  Dataless directories keep their own blocks and are flagged `.dataless`.
* fts reports an unreadable directory twice (`FTS_D`, then `FTS_DNR`); it is counted once. EPERM → `.needsFullDiskAccess`,
  anything else → `.unreadable`.

## Memory model

* Files below `fileNodeThreshold` (1 MiB) get no node: one synthetic `.smallItems` node per directory holds them
  ("N small items", English default; the UI localizes it from the flag and `fileCount`, key `index.smallItems`).
* Files ≥ 1 MiB get a node and a `FileRecord` (device, inode, link count, sizes, mtime, birthtime, flags), sorted by
  allocated size; `sizeBuckets` groups them by exact logical size for Duplicates. Hard-link repeats also get a record
  (0 allocated) so every name of an inode is known.
* Packages (`PackageDetector`: `.app`, `.photoslibrary`, `.xcarchive`, …) are sized exactly but not expanded
  (`.package | .collapsed`, no records inside).
* Node budget (`maxNodes`, default 5 M): once reached, deeper directories fold into their nearest materialized ancestor
  (`.collapsed`, `stats.nodeBudgetHit`). Sizes stay exact; only detail is lost. A directory whose small-items node
  cannot be created is also flagged `.collapsed`. File records of files that lost their node point at the directory node.
* ≈ 54 bytes per node plus the UTF-8 name arena; `estimatedMemoryBytes` reports it.

## Protected marking

Each materialized directory/file node is classified from the pure `ProtectedPaths.evaluate` (no syscall per node) using
the physical path (`realpath(root)` + relative part; fts never follows links). `protectedPath` / `protectedName` →
`.protected` (inherited by all descendants); `systemLocation` → `.outsideCleanableRoots` (inherited);
`outsideAllowedRoots` → `.outsideCleanableRoots` (not inherited, because home lies below it in full-disk mode);
container reasons set no flag. Protected directories **are descended** so sizes stay honest. Small files are not
evaluated: a protected small file (e.g. `.env`) sits inside an unflagged aggregate, so the map must never offer anything
for cleanup (invariant 12).

## Firmlinks

`/` is the sealed system snapshot and `/Users`, `/Applications`, … are firmlinks into the data volume. Walking `/` would
skip them (other `st_dev`) or double count. `.fullDisk` therefore indexes `/System/Volumes/Data`;
`displayPath(of:)` maps `/System/Volumes/Data/<firmlinked dir>/…` back to `/<dir>/…` using `/usr/share/firmlinks`.
`PathCanonicalizer.key` already folds the prefix, so guard evaluation and `lookup(path:)` accept either spelling.
The sealed system volume is not indexed.

## Concurrency and cancellation

One run at a time (`alreadyRunning`). The blocking fts loop runs on a GCD thread; `cancel()` and task cancellation set
a flag checked on every entry (cancel latency is far below 200 ms). The builder is confined to the walker thread;
only the frozen `DiskTree` crosses threads. `progress` is called on the walker thread.

## Edge cases

Vanished entries record an issue and never throw; paths over `PATH_MAX` record `nameTooLong`; names are stored as raw
bytes (`.nonUTF8Name` when not valid UTF-8, display only); `lookup` compares `PathCanonicalizer.key` components, so it
is case- and Unicode-form-insensitive and a path inside a collapsed package returns the package node.
TCC consent folders (Desktop, Documents, Downloads) may show the macOS consent prompt on first access; a denial is
`FTS_DNR` EPERM → `.needsFullDiskAccess`.

## Benchmarks

`ADK_BENCH=1 swift test --filter DiskIndexerBenchmarkTests` (synthetic 200 k files); add `ADK_BENCH_REAL_HOME=1` to index
the real home read-only. Results are in the PR description.

### Protected-marking fast path (indexing/display only)

`evaluate` costs ~1 ms per path, which made the index ~8x slower than `FileSizer`. The verdict is a function of the
lexical key and the physical key (lexical wins), so `IndexGuard` tracks one verdict class per key and the flags equal
`evaluate`'s. A key is *settled* when the node is deeper than every root/system-root key and no anchored or exact-only
pattern can still apply (an incremental cursor; a fully matched anchored pattern stays in the cursor, so patterns at or
above a root, whose node evaluates as a container, are never lost). A settled key inherits `protected`, `system` or
`outside` from its parent, otherwise it becomes `protected` only through a basename pattern on its own name. Everything
else is computed from the key with the guard itself. Roots at or above `/System/Volumes/Data` (`/`, `/System`,
`/System/Volumes`) use the full computation because descendant keys lose that prefix. `.fullDisk` (the data volume
itself) is fast-pathed and marks home items `protected` exactly like a `.home` index.
`IndexGuardDifferentialTests` compare it with the pure `evaluate` on generated walks: built-in shapes, patterns at,
above and below the deepest root (aliases, case and Unicode variants), random-pattern fuzz, lexical-inside/physical-outside
and the reverse, aliased roots, the data volume, system and outside roots. Cleanup and execution never use it: they keep
calling `ProtectedPaths.check`. Symlink entries get no node and are not classified (a `check` would resolve the target).

### Results (release build, this machine)

| Tree | Entries | FileSizer | DiskIndexer | Ratio | Peak RSS |
|---|---|---|---|---|---|
| synthetic 200 k files, full `evaluate` per dir | 204 k | 1.04 s | 9.3 s | 9.9× | 24 MB |
| synthetic 200 k files, fast path | 204 k | 1.04 s | 1.23 s | 1.19× | 23 MB |
| real `~` (read-only), fast path | 1.12 M | 41.96 s | 38.85 s | 0.93× | 63 MB (tree 12 MB, 231 k nodes, 4 009 records) |
