import DiskKeeperCore
import Foundation

/// Synthetic members and groups for the Duplicates UI tests. Nothing here touches the filesystem.
enum DupUI {
    static let home = "/Users/tester"

    static func member(_ path: String, inode: UInt64, bytes: Int64 = 1_000_000, reclaimable: Int64? = -1,
                       shares: Bool = false, all: Bool = false, links: [String] = [], git: Bool = false,
                       created: TimeInterval? = nil) -> DuplicateMember {
        let r: Int64? = reclaimable == -1 ? (all ? 0 : bytes) : reclaimable
        return DuplicateMember(path: path, device: 1, inode: inode, otherLinkPaths: links, logicalBytes: bytes,
                               allocatedBytes: bytes, reclaimableBytes: r, sharesStorage: shares || all,
                               sharesAllStorage: all, created: Date(timeIntervalSince1970: created ?? Double(inode) * 1000 + 1000),
                               modified: Date(timeIntervalSince1970: 5), isInGitRepo: git)
    }

    static func group(_ tag: String, _ members: [DuplicateMember], bytes: Int64 = 1_000_000) -> DuplicateGroup {
        DuplicateGroup(digest: String(repeating: tag, count: 64 / tag.count), partialDigest: "p\(tag)", logicalBytes: bytes,
                       members: members)
    }

    /// n real copies "/Users/tester/<tag>/f<i>", oldest first.
    static func plain(_ tag: String, count n: Int, bytes: Int64 = 1_000_000, base: UInt64 = 1) -> DuplicateGroup {
        group(tag, (0..<n).map { member("\(home)/\(tag)/f\($0).bin", inode: base + UInt64($0), bytes: bytes) }, bytes: bytes)
    }

    static func report(_ groups: [DuplicateGroup]) -> DuplicateReport {
        DuplicateReport(groups: groups, stats: DuplicateStats(), warnings: [])
    }
}
