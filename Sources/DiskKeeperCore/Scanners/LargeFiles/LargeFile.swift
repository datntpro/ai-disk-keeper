import Foundation

public struct LargeFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    /// What the Trash really frees (APFS private size); `nil` when the volume did not say.
    public let reclaimableBytes: Int64?
    public let kind: LargeFileKind
    public let dates: FileDates
    public let lastOpened: Date
    public let lastOpenedSource: LastOpenedSource
    /// Name of the installed app this installer is for. A hint; it never changes the tier.
    public let installedAppMatch: String?
    public let sharesStorage: Bool
    /// Deleting frees nothing: every block is shared with another file (clone or hard link).
    public let sharesAllStorage: Bool
    public let linkCount: UInt16
    /// The file backs a disk image that is attached right now: eject it before anything else. Keep tier, not selectable.
    public let isMountedImage: Bool

    /// The "shares storage" pill is worth showing: all of it, a link, an unknown amount, or at least 1% of the file.
    /// A sliver of shared blocks (< 1%) is noise and stays hidden.
    public var showsSharedStoragePill: Bool {
        guard sharesStorage else { return false }
        if sharesAllStorage || linkCount > 1 { return true }
        guard let reclaimable = reclaimableBytes, allocatedBytes > 0 else { return true }
        return Double(allocatedBytes - reclaimable) / Double(allocatedBytes) >= 0.01
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, logicalBytes: Int64, allocatedBytes: Int64, reclaimableBytes: Int64?, kind: LargeFileKind,
                dates: FileDates, lastOpened: Date, lastOpenedSource: LastOpenedSource, installedAppMatch: String?,
                sharesStorage: Bool, sharesAllStorage: Bool = false, linkCount: UInt16, isMountedImage: Bool = false) {
        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.reclaimableBytes = reclaimableBytes
        self.kind = kind
        self.dates = dates
        self.lastOpened = lastOpened
        self.lastOpenedSource = lastOpenedSource
        self.installedAppMatch = installedAppMatch
        self.sharesStorage = sharesStorage
        self.sharesAllStorage = sharesAllStorage
        self.linkCount = linkCount
        self.isMountedImage = isMountedImage
    }
}

/// Why records were left out (stats only).
public struct LargeFileSkipStats: Sendable, Hashable {
    public var dataless = 0
    public var protected = 0
    public var hardLinkRepeat = 0
    public var folded = 0
    public var outOfScope = 0
    public var changed = 0
    public var guardDropped = 0
    public var ownerDropped = 0
    public init() {}
}

public struct LargeFileReport: Sendable {
    public var files: [LargeFile]
    public var skipped: LargeFileSkipStats
    public var warnings: [ScanWarning]
    public init(files: [LargeFile], skipped: LargeFileSkipStats = .init(), warnings: [ScanWarning] = []) {
        self.files = files
        self.skipped = skipped
        self.warnings = warnings
    }
}
