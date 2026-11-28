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
  with it. The probed report is what `SizeCache` stores (schema 2); small items stay unprobed.
- `ScanItem.reclaimableBytes` (nil = unknown / not measured) and `reclaimIsEstimate`.

## What the UI says
`ReclaimEstimate.make(items:trashSameVolume:localSnapshotsPresent:)` → `shownBytes`, `freesAboutBytes`, caveats:
`trashSameVolume` (space returns when the Trash is emptied), `localSnapshotsPresent` (macOS may keep the blocks until
it thins snapshots), `clonesShared(bytes)`, `unknownForSome(count)` ("May free less"). The item detail and the cleanup
review sheet show "Shown X · Frees about Y"; the line is highlighted when frees-about is under half of shown.
Module badges keep the shown size. The review sheet does not yet query snapshots (`localSnapshotsPresent` is wired in
the estimate for a later caller).

## Limits
Snapshots and clones whose other side is in a different volume are invisible to `getattrlist`; the estimate is
per-item, so two items sharing blocks with each other are each shown as if the other stayed.
Items below 100 MB are not probed and show their allocated size without a "frees about" line.
