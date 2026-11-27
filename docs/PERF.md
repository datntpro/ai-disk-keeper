# Scan performance (T25)

## What is cached

`SizeCache` (`Persistence/SizeCache.swift`) remembers the `SizeReport` of an **item root** between scans and reuses
it only while the file system journal can vouch that nothing changed. It is used by the Care Scan rule stage
(`ScanContext.size`, so `RuleScanner`). It is **not** used by `CleanupEngine` / `ItemValidator` (their execute-time
re-size always walks the disk; `ItemValidatorNoCacheTests` pins this) or by `DiskIndexer` (follow-up).

File: `~/Library/Application Support/AIDiskKeeper/size-cache.json` (mode 0600). It holds sizes and the paths of the
user's own scan items, nothing else. Cap: 50,000 entries (least recently used are evicted). Settings → General has
"Speed up rescans with a cache" (on by default) and "Clear scan cache".

## Why the journal and not directory mtimes

Appending to a file in place changes neither its directory's nor any ancestor's mtime. A directory-mtime cache would
keep an old `newestModification`, and a "newer than 1 day → keep" rule could come out **Safe for data being written
right now**. FSEvents reports the path of every content write, so it is the invalidation source.

## Invalidation rules (conservative: when in doubt, re-walk)

At the start of each scan (`beginScan`), **before any walk**:

1. The current event id is captured first (`FSEventsGetCurrentEventId`), then the journal is asked for everything
   since the id saved by the previous scan. Nothing between the two can be lost; the new id is what gets saved.
2. The whole cache is dropped when: the app build, the volume's FSEvents UUID, the schema version or the sizer
   options (`crossVolumes`, `maxRecordedIssues`) differ; the journal reports `MustScanSubDirs`, `UserDropped`,
   `KernelDropped`, `EventIdsWrapped`, `RootChanged`, `Mount` or `Unmount`; more than 1M events; or the journal does
   not answer within 5 s.
3. Otherwise an entry is dropped if any changed path is **equal to, inside, or an ancestor of** its root.
4. A second FSEvents stream stays open from the captured id until `endScan`. Every lookup and store first flushes it:
   an entry touched by any event during the scan is dropped and never served, and a root written between its
   stamp and its store is not stored. A watch that cannot open, or that reports a drop, ends caching for the scan.
   Stamps carry the scan generation, so a store from a superseded scan is rejected.
5. A saved event id ahead of the journal's current id, or a cache file that is not a regular file of ours with mode
   0600, is not trusted.
6. On every lookup the root's `lstat` device / inode / mtime must still equal what was recorded **before** its walk
   (a root replaced by a new directory, or touched during the walk, misses).

Only complete reports (no sizing issues, no skipped mount points) on the Data volume are stored. Keys are physical
paths (parent resolved with `realpath`), because the journal reports physical paths. The journal only reads history;
nothing is written to the volume.

## Method

`Tests/DiskKeeperCoreTests/Perf/IncrementalScanBenchmarkTests.swift`: a generated tree of 200,000 files (50 items ×
40 leaf directories × 100 files, directory depth ≤ 8, sizes 0–64 KiB written sparse; the walk cost is what is
measured, not disk writes), generated once into a temp dir. Opt-in: `ADK_BENCH=1 swift test --filter Benchmark`
(`ADK_BENCH_OUT=<file>` also appends the `BENCH` lines to a file). The normal `test` job skips every benchmark; the
non-blocking `bench` CI job (pushes to `main` and manual runs) runs them and uploads the results as an artifact.
The ≥ 3× second-scan assertion only runs under `ADK_BENCH=1`.

## Numbers

Machine: Apple M1 Pro, 10 cores, 32 GB, macOS 27.2, APFS, warm page cache. **The machine was shared and loaded**
(load average 6.5–9 on 10 cores, everything run under `taskpolicy -b`), so treat these as indicative.

| Run | Time |
|---|---|
| First scan (cold cache, 200k files) | 3.17 s |
| Second scan (warm cache, real journal, 50/50 items from cache) | 1.05 s |
| Speed-up | 3.0× |

The first scan here walks a page-cached tree, which is the best case for the walker; on a real home with a cold page
cache the first scan is much slower while the second scan stays dominated by the journal query, so the ratio grows.
A real-home measurement is not included: tests and benchmarks only ever touch fixture/temp directories.

### Sizing concurrency (`maxConcurrentSizing`, cold, no cache, best of 3)

| n | best | median |
|---|---|---|
| 2 | 2.93 s | 3.22 s |
| 4 | 2.68 s | 2.73 s |
| 8 | 2.04 s | 2.24 s |
| 10 (ncpu) | 2.18 s | 2.84 s |

The default is `min(8, ncpu)` (`ScanContext.defaultConcurrentSizing`): 8 was fastest and steadier than ncpu on this
machine; more walkers than that only contended on the shared load.

## Developer check

`swift run adk-scan --cache` runs the bundled rules with the same cache and prints the time and hit/miss counts to
stderr; run it twice on seeded data (`scripts/vm/seed-fake-ai-data.sh`) to see the second scan.
