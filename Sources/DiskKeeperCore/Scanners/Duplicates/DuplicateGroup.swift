import Foundation

public struct DuplicateMember: Sendable, Hashable, Codable {
    public let path: String
    public let device: Int32
    public let inode: UInt64
    /// Other names of the same inode found in the tree (hard links). Never survivors for each other.
    public let otherLinkPaths: [String]
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    /// APFS `privatesize`: bytes freed if this file alone is deleted. nil = unknown (fallback).
    public let reclaimableBytes: Int64?
    /// Clone or hard link: deleting frees less than `allocatedBytes` (or nothing).
    public let sharesStorage: Bool
    /// Deleting frees ~nothing: every block is shared with another file.
    public let sharesAllStorage: Bool
    public let created: Date
    public let modified: Date
    /// The nearest ancestor (up to the scope root) holds a `.git` entry.
    public let isInGitRepo: Bool

    public init(path: String, device: Int32, inode: UInt64, otherLinkPaths: [String], logicalBytes: Int64,
                allocatedBytes: Int64, reclaimableBytes: Int64?, sharesStorage: Bool, sharesAllStorage: Bool,
                created: Date, modified: Date, isInGitRepo: Bool) {
        self.path = path; self.device = device; self.inode = inode; self.otherLinkPaths = otherLinkPaths
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes
        self.reclaimableBytes = reclaimableBytes; self.sharesStorage = sharesStorage
        self.sharesAllStorage = sharesAllStorage; self.created = created; self.modified = modified
        self.isInGitRepo = isInGitRepo
    }
}

public struct DuplicateGroup: Sendable, Hashable, Codable, Identifiable {
    /// `"dup:<first 32 hex of SHA-256>:<logicalBytes>"`.
    public let id: String
    public let logicalBytes: Int64
    /// Full SHA-256, hex.
    public let digest: String
    /// `SHA-256(size ‖ head ‖ tail)`, hex. Re-checked by the cleanup engine at plan and execute time.
    public let partialDigest: String
    /// At least 2 distinct inodes, keeper first.
    public let members: [DuplicateMember]

    public init(digest: String, partialDigest: String, logicalBytes: Int64, members: [DuplicateMember]) {
        precondition(members.count >= 2, "a duplicate group needs at least two members")
        self.id = "dup:\(digest.prefix(32)):\(logicalBytes)"
        self.digest = digest
        self.partialDigest = partialDigest
        self.logicalBytes = logicalBytes
        self.members = members
    }

    public var keeper: DuplicateMember { members[0] }

    /// Σ reclaimable bytes of the non-keeper members that share nothing (certain bytes only).
    public var reclaimableBytes: Int64 {
        members.dropFirst().reduce(0) { sum, m in
            guard !m.sharesStorage, let r = m.reclaimableBytes else { return sum }
            return sum + r
        }
    }
}

public struct DuplicateStats: Sendable, Hashable {
    public var candidates = 0
    public var sizeBuckets = 0
    public var partialHashed = 0
    public var fullHashed = 0
    public var skippedDataless = 0
    public var skippedChanged = 0
    public var skippedUnreadable = 0
    /// Groups left out because every non-keeper is a full clone/link of the same storage (they free ~0 bytes).
    public var groupsDroppedAllShared = 0
    public var bytesRead: Int64 = 0
    public var duration: Duration = .zero

    public init() {}
}

public struct DuplicateReport: Sendable {
    public let groups: [DuplicateGroup]
    public let stats: DuplicateStats
    public let warnings: [ScanWarning]

    public init(groups: [DuplicateGroup], stats: DuplicateStats, warnings: [ScanWarning]) {
        self.groups = groups; self.stats = stats; self.warnings = warnings
    }
}
