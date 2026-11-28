# Real reclaimable space on APFS (H6)

The size we show everywhere is `sizeAllocated` (`st_blocks × 512`). On APFS that is an upper bound on what deleting
frees: blocks shared with clones (a VM disk cloned from an image, `cp -c`, a copied project), hard links whose other
name lives outside the item (pnpm store → `node_modules`), and local snapshots all keep space in use. H6 adds a second,
honest number, **frees about**, and never makes an item look more reclaimable than it is: when unsure it reports less.

It is information only. It changes no tier, `sizeAllocated`, selection or Duplicates' keep-one logic, and it never adds
the volume's purgeable space to a selection.

## How it is measured
- `FileSizer.Options.measurePrivateBytes` (default off). In the fts walk, per regular file:
  - `st_nlink > 1`: the existing per-walk inode dedupe counts it once. If fewer links were seen than `st_nlink`, other
    names exist outside the tree: its bytes go to `SizeReport.sharedOutsideBytes` and count 0.
  - size ≥ 1 MiB (`privateProbeMinFileSize`): one `getattrlist` (`CloneProbe`, `ATTR_CMNEXT_PRIVATESIZE`): `.known` adds
    the private bytes (capped at the file's allocated bytes), `.unknown` (non-APFS, error) adds allocated and sets
    `privateIsEstimate`.
  - smaller files and directories count as private (allocated).
  - Metadata only: no content is read; dataless files are fine.
- `SizeReport.privateBytes` = that sum (nil = not measured); `probedBytes` = bytes of the probed files.
- `ScanContext` (D11) walks first without the probe; only items ≥ 100 MB (`reclaimProbeMinItemBytes`) are walked again
  with it. **The cache never holds the probe numbers**: clones and hard links made later *outside* an item write
  nothing inside it, so FSEvents cannot invalidate them. `SizeCache` stores the plain report plus a `ReclaimPlan`
  (the probed and multi-link files, with the links seen inside, and the fixed bytes of everything else). On a cache
  hit the numbers are refreshed from the plan with one `lstat` (+ `getattrlist` for probed files) per entry: no tree
  walk (a 20k-file tree: warm hit ≈ 2 ms, cold probe walk ≈ 0.5 s). A changed inode or a plan over 4000 entries falls
  back to a probe walk. A hard link added outside to a small single-link file is not seen (small files count as
  private, D11). If the probe walk fails, the item falls back to its allocated size flagged "may free less".
- Compressed files (`UF_COMPRESSED`, or PRIVATESIZE 0 with clone refcount 0) report no private bytes: they count at
  allocated and mark the item an estimate. A fully shared clone (refcount ≥ 2) really frees 0.
- Items that no probe measured (other scanners, anything ≥ 100 MB with `reclaimableBytes == nil`) are "unknown": the
  UI shows only "May free less", never a "Frees about" number. DerivedData and Tart tmp go through the probe.
- `ScanItem.reclaimableBytes` (nil = unknown / not measured) and `reclaimIsEstimate`.

## What the UI says
`ReclaimEstimate.make(items:trashSameVolume:localSnapshotsPresent:)` → `shownBytes`, `freesAboutBytes`, caveats:
`trashSameVolume` (space returns when the Trash is emptied), `localSnapshotsPresent` (macOS may keep the blocks until
it thins snapshots), `clonesShared(bytes)`, `unknownForSome(count)` ("May free less"). The item detail and the cleanup
review sheet show "Shown X · Frees about Y"; the line is highlighted when frees-about is under half of shown.
Module badges keep the shown size; the table row and the module header add a compact "Frees about" line only when it
is under half of shown. Caveats: the Trash one applies to any item that goes to a Trash (home or an external volume's)
and not to permanent deletes or tool commands; the snapshot one comes from `LocalSnapshotLister` on the Data volume
(cached for 5 minutes; an unreadable listing counts as "may hold space"). "May free less" is listed once.

## Limits
Snapshots and clones whose other side is in a different volume are invisible to `getattrlist`; the estimate is
per-item, so two items sharing blocks with each other are each shown as if the other stayed.
Items below 100 MB are not probed and show their allocated size without a "frees about" line; files under 1 MiB
are never probed, so a tree of many small cloned files (for example `cp -c -R` of a project) can be overclaimed.
