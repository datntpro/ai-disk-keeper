# Large & Old Files

`LargeFileScanner` (`Sources/DiskKeeperCore/Scanners/LargeFiles/`) lists big files you haven't opened in a while. It is
read-only and works from the disk index (`DiskTree.fileRecords`): it never walks the disk again, never reads or hashes
content, and never downloads iCloud files.

## Pipeline (`report(tree:now:)`)

1. Records with `logicalBytes ≥ minimumBytes` (collect floor 100 MB; the UI filters up, default 500 MB). The index keeps
   records only for files ≥ 1 MiB outside packages, so packages are never listed.
2. Dropped: `.dataless` (iCloud-only), `.protected` / `.outsideCleanableRoots` (media libraries, credentials),
   `.hardlinkRepeat`, `.nonUTF8Name`, records folded into a directory by the node budget, paths outside `scopeRoot` or
   under `excludedRoots` (default `~/Library`), and any component below the scope root starting with `.`.
3. Per survivor: `lstat` (still a regular file with the recorded device and inode, else dropped as `changed`), dates from
   `LastOpenedProviding`, APFS clone info from `CloneProbe` (`reclaimableBytes` = private size).
4. `lastOpened = max(Spotlight last-used, atime, mtime)`; the source that produced the max is kept. A file counts as old
   only if every signal says so.
5. Installer hint: for disk images/installers and `.zip` files in `~/Downloads`, the normalized stem (lowercase, no
   diacritics, no version tokens, no `installer|setup|universal|arm64|x64|intel|mac|macos|osx|dmg`) is compared with the
   top-level apps in `/Applications` and `~/Applications`. Equal, or the app name (≥ 4 characters) is a prefix of the
   stem → `installedAppMatch`. A hint only; it never changes the tier.
6. Sorted by allocated bytes, then path.

## Kinds (last extension, case-insensitive)

| Kind | Extensions |
| --- | --- |
| archive | zip tar gz tgz bz2 tbz xz txz 7z rar zst lz4 cpio |
| diskImageOrInstaller | dmg pkg mpkg xip iso img toast cdr sparseimage |
| video | mov mp4 m4v mkv avi webm mts m2ts mpg mpeg wmv flv hevc braw r3d |
| vmImage | vmdk vdi vhd vhdx qcow2 hdd ipsw ova ovf utmdisk |
| other | everything else |

## Items

`makeItem`: category `largeFile`, tool `files`, tier **Review always**, rule `large.<kind>`, method `trash`; `none`
(report-only) when `linkCount > 1` or every block is shared. `sharedStorage` is flagged when blocks are shared.
`scan(context:sink:)` (Care Scan) also applies the path guard and the owner check.

## Not included

`~/Library`, hidden folders (`.ollama`, `.docker`… belong to AI Workspace / System Junk), packages, Photos and Music
libraries, iCloud-only files.
