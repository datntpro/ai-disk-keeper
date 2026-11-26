# Storage overview (Core, T40)

Read-only. `Volume/*` in `DiskKeeperCore` gathers the numbers for the storage card, sidebar gauge and menu bar. It never deletes or thins snapshots, empties the Trash, runs `purge` or `diskutil`, or asks for admin rights. The only `tmutil` subcommand used is `listlocalsnapshots`; `VolumeReadOnlyTests` scans `Sources/` to keep it that way.

`StorageOverviewService.overview()` runs the three parts concurrently and is cancellable. There are no timers: callers decide when to refresh, and should poll no more than once every 60 s.

| Number | Source | Limits |
|---|---|---|
| Total / available | URL keys `volumeTotalCapacity`, `volumeAvailableCapacity` | On APFS, total is the whole container, shared by every volume in it. |
| Available for important usage | `volumeAvailableCapacityForImportantUsage` | Counts space macOS can reclaim. |
| Purgeable (estimate) | `max(0, important − available)` | An estimate. It changes minute to minute and can be 0 while Finder shows some. |
| Used by this volume | `getattrlist` `ATTR_VOL_SPACEUSED` (matches `df` and `diskutil apfs list`) | Per volume. `statfs` free counts are container-wide on APFS, so `statfs` can't be used for this. |
| Other volumes and snapshots | container total − data used − system used − available | Preboot, VM, Recovery, Update and snapshots lumped together. nil if usage is unknown. |
| Local snapshots | `tmutil listlocalsnapshots /` (10 s timeout, 1 MiB output cap) | **No sizes**: tmutil doesn't report them. Time Machine names carry local wall-clock time. An empty list is valid. |
| Trash | `FileSizer` over `~/.Trash` | Needs Full Disk Access (EPERM maps to `needsFullDiskAccess`). Other volumes' `.Trashes` are not measured. |

**System Data** is computed by macOS and can't be reproduced exactly, so Core reports only the measurable parts and does not present one "System Data" number.

## Layouts
`/System/Volumes/Data` is the data volume; `/` is the sealed system volume. If the data path is missing, data falls back to `/` and `systemVolume` is nil. If both report the same `statfs` `f_fsid`, `systemVolume` is nil. (`st_dev` can't tell them apart: the sealed system volume and Data share it.)

Snapshot names are parsed in the local time zone; the date is ambiguous in a DST fall-back hour and shifts if the time zone changes. `isEncrypted` is not FileVault status; the Trash number covers `~/.Trash` only, not `/Volumes/*/.Trashes`.

## Text
Core exposes codes (`StorageExplanation`, `SnapshotUnavailableReason`, `TrashInfo.State`, `LocalSnapshot.Kind`). The UI words them in `Shared/StorageCopy.swift` with `storage.*` catalog keys in English and Vietnamese.
