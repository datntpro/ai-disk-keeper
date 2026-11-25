import Foundation

/// Annotations on a scan item. Stored as `Set<ItemFlag>`; see ``ScanItem``.
public enum ItemFlag: String, Codable, Sendable, Hashable, CaseIterable {
    /// Sizing hit permission/IO errors: size is a lower bound.
    case sizeIncomplete
    /// Held open / owned by a running process.
    case inUse
    /// The item path itself is a symlink (size reported as 0).
    case symlink
    /// Contains mount points that were not crossed.
    case otherVolume
    /// Some content was blocked by TCC (EPERM).
    case needsFullDiskAccess
    /// Bytes may be shared with other items (hardlinks, APFS clones, shared model blobs).
    case sharedStorage
}
