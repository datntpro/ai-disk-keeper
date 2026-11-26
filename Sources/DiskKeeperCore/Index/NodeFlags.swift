import Foundation

/// Flags on a ``DiskNode`` or ``FileRecord``. Exactly one of `directory`, `file`, `symlink`, `smallItems`
/// describes the kind of a node.
public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let file = NodeFlags(rawValue: 1 << 1)
    public static let symlink = NodeFlags(rawValue: 1 << 2)
    /// Synthetic "N small items" node: the files below `IndexOptions.fileNodeThreshold` of one directory.
    public static let smallItems = NodeFlags(rawValue: 1 << 3)
    /// Children are not materialized (package, node budget). Sizes are still exact.
    public static let collapsed = NodeFlags(rawValue: 1 << 4)
    /// Directory whose extension is in ``PackageDetector``.
    public static let package = NodeFlags(rawValue: 1 << 5)
    /// Mount point that was not crossed (0 bytes).
    public static let otherVolume = NodeFlags(rawValue: 1 << 6)
    /// SF_DATALESS directory (not descended) or file (never read).
    public static let dataless = NodeFlags(rawValue: 1 << 7)
    /// The safety guard hard-denies this path (`protectedPath` / `protectedName`); inherited by children.
    public static let protected = NodeFlags(rawValue: 1 << 8)
    /// `systemLocation` / `outsideAllowedRoots` (full-disk mode). Never offered for cleanup.
    public static let outsideCleanableRoots = NodeFlags(rawValue: 1 << 9)
    /// EPERM while reading this directory (TCC / Full Disk Access).
    public static let needsFullDiskAccess = NodeFlags(rawValue: 1 << 10)
    /// Any other read error (EACCES, EIO, vanished, …).
    public static let unreadable = NodeFlags(rawValue: 1 << 11)
    /// Another link to an inode already counted (0 bytes here).
    public static let hardlinkRepeat = NodeFlags(rawValue: 1 << 12)
    /// Allocated < logical / 2 and logical ≥ 1 MiB.
    public static let sparse = NodeFlags(rawValue: 1 << 13)
    /// UF_COMPRESSED.
    public static let compressed = NodeFlags(rawValue: 1 << 14)
    /// Name bytes are not valid UTF-8 (display only, never actionable).
    public static let nonUTF8Name = NodeFlags(rawValue: 1 << 15)
}
