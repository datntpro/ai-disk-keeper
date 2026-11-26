import Foundation

public struct DiskNodeID: Hashable, Sendable, Comparable, Codable {
    public let raw: Int32
    public init(raw: Int32) { self.raw = raw }
    public static func < (l: DiskNodeID, r: DiskNodeID) -> Bool { l.raw < r.raw }
}

public struct DiskNode: Sendable, Hashable {
    public let id: DiskNodeID
    /// nil only for the root.
    public let parent: DiskNodeID?
    /// Decoded lazily from the arena. For `.smallItems` nodes this is the English default "N small items";
    /// UI code should localize it from the flag and `fileCount` (key `index.smallItems`).
    public let name: String
    /// Subtree `st_blocks * 512`, hardlinks once (equals `FileSizer`).
    public let allocatedBytes: Int64
    /// Subtree `st_size` of unique regular/other files.
    public let logicalBytes: Int64
    /// Subtree unique files (for `.smallItems`: the number folded).
    public let fileCount: Int
    /// Subtree max mtime (directories included), like `FileSizer`.
    public let newestModification: Date?
    public let flags: NodeFlags
    public let childCount: Int
}

/// Every regular file at least `IndexOptions.fileRecordThreshold` large, outside packages.
public struct FileRecord: Sendable, Hashable {
    /// The file's node, or its directory's node when the file was folded by the node budget.
    public let node: DiskNodeID
    public let device: Int32
    public let inode: UInt64
    public let linkCount: UInt16
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modified: Date
    public let created: Date
    public let flags: NodeFlags
}

/// Immutable, `Sendable` snapshot of a walked directory tree (struct of arrays; ~54 bytes per node plus names).
public struct DiskTree: Sendable {
    public let rootPath: String
    public let physicalRootPath: String
    public let scope: DiskIndexer.Scope
    public let createdAt: Date
    public let stats: IndexStats
    public let fileRecords: [FileRecord]

    let parents: [Int32]
    let allocated: [Int64]
    let logical: [Int64]
    let mtimes: [Double]
    let fileCounts: [UInt32]
    let flagBits: [UInt32]
    let nameStart: [UInt32]
    let nameLen: [UInt16]
    let childStart: [UInt32]       // count + 1 entries
    let childIndex: [DiskNodeID]
    let arena: [UInt8]
    let firmlinks: FirmlinkMap

    static let noMtime = -1e300

    var root: DiskNodeID { DiskNodeID(raw: 0) }
    public var rootNodeID: DiskNodeID { root }
    public var nodeCount: Int { parents.count }

    init(rootPath: String, physicalRootPath: String, scope: DiskIndexer.Scope, createdAt: Date, stats: IndexStats,
         fileRecords: [FileRecord], parents: [Int32], allocated: [Int64], logical: [Int64], mtimes: [Double],
         fileCounts: [UInt32], flagBits: [UInt32], nameStart: [UInt32], nameLen: [UInt16], childStart: [UInt32],
         childIndex: [DiskNodeID], arena: [UInt8], firmlinks: FirmlinkMap) {
        self.rootPath = rootPath; self.physicalRootPath = physicalRootPath; self.scope = scope
        self.createdAt = createdAt; self.stats = stats; self.fileRecords = fileRecords
        self.parents = parents; self.allocated = allocated; self.logical = logical; self.mtimes = mtimes
        self.fileCounts = fileCounts; self.flagBits = flagBits; self.nameStart = nameStart; self.nameLen = nameLen
        self.childStart = childStart; self.childIndex = childIndex; self.arena = arena; self.firmlinks = firmlinks
    }

    func withRecords(_ r: [FileRecord]) -> DiskTree {
        DiskTree(rootPath: rootPath, physicalRootPath: physicalRootPath, scope: scope, createdAt: createdAt,
                 stats: stats, fileRecords: r, parents: parents, allocated: allocated, logical: logical,
                 mtimes: mtimes, fileCounts: fileCounts, flagBits: flagBits, nameStart: nameStart, nameLen: nameLen,
                 childStart: childStart, childIndex: childIndex, arena: arena, firmlinks: firmlinks)
    }

    // MARK: Read API

    public func node(_ id: DiskNodeID) -> DiskNode {
        let i = Int(id.raw)
        let flags = NodeFlags(rawValue: flagBits[i])
        let name: String
        if flags.contains(.smallItems) {
            name = DiskTree.smallItemsName(count: Int(fileCounts[i]))
        } else {
            name = nameString(i)
        }
        let m = mtimes[i]
        return DiskNode(
            id: id, parent: parents[i] < 0 ? nil : DiskNodeID(raw: parents[i]), name: name,
            allocatedBytes: allocated[i], logicalBytes: logical[i], fileCount: Int(fileCounts[i]),
            newestModification: m == Self.noMtime ? nil : Date(timeIntervalSince1970: m),
            flags: flags, childCount: Int(childStart[i + 1] - childStart[i]))
    }

    /// English default for the synthetic node name (the loc key `index.smallItems` lives in the UI target).
    static func smallItemsName(count: Int) -> String { count == 1 ? "1 small item" : "\(count) small items" }

    func nameString(_ i: Int) -> String {
        let s = Int(nameStart[i]), n = Int(nameLen[i])
        return String(decoding: arena[s..<(s + n)], as: UTF8.self)
    }

    /// Sorted: allocated bytes descending, then canonical name ascending.
    public func children(of id: DiskNodeID) -> ArraySlice<DiskNodeID> {
        let i = Int(id.raw)
        return childIndex[Int(childStart[i])..<Int(childStart[i + 1])]
    }

    /// Absolute lexical path. O(depth).
    public func path(of id: DiskNodeID) -> String {
        var names: [String] = []
        var i = Int(id.raw)
        while parents[i] >= 0 {
            names.append(NodeFlags(rawValue: flagBits[i]).contains(.smallItems) ? "" : nameString(i))
            i = Int(parents[i])
        }
        if names.isEmpty { return rootPath }
        let base = rootPath == "/" ? "" : rootPath
        return base + "/" + names.reversed().joined(separator: "/")
    }

    /// Like `path(of:)`, but firmlink-mapped for full-disk scope (`/System/Volumes/Data/Users` → `/Users`).
    public func displayPath(of id: DiskNodeID) -> String {
        let p = path(of: id)
        if case .fullDisk = scope { return firmlinks.displayPath(p) }
        return p
    }

    /// Root … parent.
    public func ancestors(of id: DiskNodeID) -> [DiskNodeID] {
        var out: [DiskNodeID] = []
        var p = parents[Int(id.raw)]
        while p >= 0 { out.append(DiskNodeID(raw: p)); p = parents[Int(p)] }
        return out.reversed()
    }

    /// Deepest materialized node for `path` (case/Unicode-insensitive via `PathCanonicalizer.key`), or nil
    /// when `path` is not under the root. A path inside a collapsed package returns the package node.
    public func lookup(path: String) -> DiskNodeID? {
        guard PathNormalization.isAbsolute(path), !PathNormalization.containsNUL(path) else { return nil }
        let rootKey = PathCanonicalizer.key(rootPath).components
        let key = PathCanonicalizer.key(path).components
        guard key.count >= rootKey.count, Array(key[0..<rootKey.count]) == rootKey else { return nil }
        var current = root
        for comp in key[rootKey.count...] {
            var next: DiskNodeID?
            for c in children(of: current) {
                let i = Int(c.raw)
                if flagBits[i] & NodeFlags.smallItems.rawValue != 0 { continue }
                if PathCanonicalizer.fold(nameString(i)) == comp { next = c; break }
            }
            guard let n = next else { break }
            current = n
        }
        return current
    }

    /// Buckets of records (regular files ≥ `minimumLogicalBytes`) with identical logical size; only buckets
    /// holding at least two records.
    public func sizeBuckets(minimumLogicalBytes: Int64) -> [Int64: [FileRecord]] {
        var out: [Int64: [FileRecord]] = [:]
        for r in fileRecords where r.logicalBytes >= minimumLogicalBytes { out[r.logicalBytes, default: []].append(r) }
        return out.filter { $0.value.count >= 2 }
    }

    /// Σ array capacities × stride + arena + records.
    public var estimatedMemoryBytes: Int {
        parents.count * MemoryLayout<Int32>.stride + allocated.count * 8 + logical.count * 8 + mtimes.count * 8
            + fileCounts.count * 4 + flagBits.count * 4 + nameStart.count * 4 + nameLen.count * 2
            + childStart.count * 4 + childIndex.count * 4 + arena.count
            + fileRecords.count * MemoryLayout<FileRecord>.stride
    }

    var arenaBytes: Int { arena.count }
}
