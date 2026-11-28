import Foundation

/// Result of sizing a directory tree with ``FileSizer``.
public struct SizeReport: Sendable, Hashable, Codable {
    public enum RootKind: String, Sendable, Hashable, Codable { case directory, file, symlink, other }

    public var rootKind: RootKind
    /// Σ st_blocks*512 over unique inodes of files + "other" entries, PLUS every directory's own blocks
    /// (matches `du`). Symlinks contribute 0. Hardlinked files counted once per walk.
    public var allocatedBytes: Int64
    /// Σ st_size over unique-inode regular files + "other" entries. Directories and symlinks contribute 0.
    public var logicalBytes: Int64
    /// Unique-inode non-directory, non-symlink entries (regular files, fifos, sockets, devices).
    public var fileCount: Int
    /// Directories visited, including the root if it is a directory. Skipped mount points are NOT counted.
    public var directoryCount: Int
    public var symlinkCount: Int
    /// Extra links to an already-counted inode (st_nlink > 1) that were skipped.
    public var hardlinkDuplicateCount: Int
    /// Counted multi-link files that still have links not seen in this walk (st_nlink > links seen),
    /// i.e. other names exist outside the tree; deleting this tree frees nothing for them.
    public var externallyLinkedFileCount: Int
    /// Allocated bytes of those externally linked files (already included in `allocatedBytes`).
    public var externallyLinkedBytes: Int64
    /// Directories with SF_DATALESS (iCloud/File Provider placeholders) that were not descended.
    public var datalessSkippedCount: Int
    /// Max lstat mtime over every visited entry (root, dirs, files, symlinks). nil only if nothing could be stat'ed.
    public var newestModification: Date?
    /// Absolute paths of directories on another device that were not traversed (crossVolumes == false).
    public var skippedMountPoints: [String]
    /// First `Options.maxRecordedIssues` issues in walk order.
    public var issues: [SizingIssue]
    /// Total issues seen (>= issues.count).
    public var issueCount: Int
    /// Entries returned by fts (excluding post-order dir visits). Used for progress and benchmarks.
    public var entriesVisited: Int
    /// H6: bytes that deleting the tree would really free (nil = not measured). Allocated bytes minus blocks
    /// shared with clones elsewhere, and without files that have hard links outside the tree. Never above
    /// `allocatedBytes`.
    public var privateBytes: Int64?
    /// H6: allocated bytes of multi-link files that also have names outside the tree (they free nothing).
    public var sharedOutsideBytes: Int64
    /// H6: bytes of the files that were really probed (≥ the probe threshold).
    public var probedBytes: Int64
    /// H6: some files could not be probed (non-APFS volume, error); they count at their allocated size, so
    /// `privateBytes` is an upper bound for them: say "may free less".
    public var privateIsEstimate: Bool
    /// H6: what a cache hit needs to refresh the probe fields cheaply (see ``ReclaimPlan``). Holds nothing that
    /// depends on state outside the root; nil when the tree has too many probed or multi-link files.
    public var reclaimPlan: ReclaimPlan?

    public var isComplete: Bool { issueCount == 0 }

    public init(
        rootKind: RootKind = .directory,
        allocatedBytes: Int64 = 0,
        logicalBytes: Int64 = 0,
        fileCount: Int = 0,
        directoryCount: Int = 0,
        symlinkCount: Int = 0,
        hardlinkDuplicateCount: Int = 0,
        externallyLinkedFileCount: Int = 0,
        externallyLinkedBytes: Int64 = 0,
        datalessSkippedCount: Int = 0,
        newestModification: Date? = nil,
        skippedMountPoints: [String] = [],
        issues: [SizingIssue] = [],
        issueCount: Int = 0,
        entriesVisited: Int = 0,
        privateBytes: Int64? = nil,
        sharedOutsideBytes: Int64 = 0,
        probedBytes: Int64 = 0,
        privateIsEstimate: Bool = false,
        reclaimPlan: ReclaimPlan? = nil
    ) {
        self.rootKind = rootKind
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.symlinkCount = symlinkCount
        self.hardlinkDuplicateCount = hardlinkDuplicateCount
        self.externallyLinkedFileCount = externallyLinkedFileCount
        self.externallyLinkedBytes = externallyLinkedBytes
        self.datalessSkippedCount = datalessSkippedCount
        self.newestModification = newestModification
        self.skippedMountPoints = skippedMountPoints
        self.issues = issues
        self.issueCount = issueCount
        self.entriesVisited = entriesVisited
        self.privateBytes = privateBytes
        self.sharedOutsideBytes = sharedOutsideBytes
        self.probedBytes = probedBytes
        self.privateIsEstimate = privateIsEstimate
        self.reclaimPlan = reclaimPlan
    }

    public static let empty = SizeReport()
}

/// A non-fatal problem met while walking below the root.
public struct SizingIssue: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case permissionDenied   // EACCES
        case notPermitted       // EPERM: usually TCC / Full Disk Access
        case vanished           // ENOENT/ENOTDIR during walk (deleted concurrently)
        case nameTooLong        // ENAMETOOLONG (path > PATH_MAX with FTS_NOCHDIR)
        case dataless           // EDEADLK etc. when materialization is refused
        case ioError            // EIO
        case cycle              // FTS_DC (should not happen with FTS_PHYSICAL; recorded defensively)
        case other
    }

    public var path: String
    public var kind: Kind
    public var errno: Int32

    public init(path: String, kind: Kind, errno: Int32) {
        self.path = path
        self.kind = kind
        self.errno = errno
    }

    static func kind(forErrno code: Int32) -> Kind {
        switch code {
        case EACCES: return .permissionDenied
        case EPERM: return .notPermitted
        case ENOENT, ENOTDIR: return .vanished
        case ENAMETOOLONG: return .nameTooLong
        case EDEADLK, ENOTSUP: return .dataless
        case EIO: return .ioError
        default: return .other
        }
    }
}

public struct SizeProgress: Sendable, Hashable {
    public var entriesVisited: Int
    public var allocatedBytesSoFar: Int64

    public init(entriesVisited: Int, allocatedBytesSoFar: Int64) {
        self.entriesVisited = entriesVisited
        self.allocatedBytesSoFar = allocatedBytesSoFar
    }
}

/// H6: the files whose "private bytes" can change without anything changing inside the item: files probed for clone
/// sharing (>= 1 MiB) and files with more than one hard link. A cache hit re-checks only these (`lstat` +
/// `getattrlist`) instead of walking the tree again; everything else is the fixed `baseBytes`.
public struct ReclaimPlan: Sendable, Hashable, Codable {
    public struct Entry: Sendable, Hashable, Codable {
        public var path: String
        public var device: Int32
        public var inode: UInt64
        /// Links seen inside the tree.
        public var seenInside: Int
        public var allocated: Int64
        public var size: Int64
        /// Probed for clone sharing (otherwise only its link count matters).
        public var probed: Bool
    }
    /// Directories, small single-link files and other entries: private at their allocated size.
    public var baseBytes: Int64
    public var entries: [Entry]
    /// More entries than this: no plan, a hit walks again.
    public static let maxEntries = 4000
}
