import Foundation

/// Single-thread mutable builder. Confined to the walker thread; only the frozen `DiskTree` escapes.
final class DiskTreeBuilder {
    var parents: [Int32] = []
    var allocated: [Int64] = []
    var logical: [Int64] = []
    var mtimes: [Double] = []
    var fileCounts: [UInt32] = []
    var flagBits: [UInt32] = []
    var nameStart: [UInt32] = []
    var nameLen: [UInt16] = []
    var arena: [UInt8] = []
    var records: [FileRecord] = []

    var nodeCount: Int { parents.count }

    @discardableResult
    func addNode(parent: Int32, name: UnsafeRawBufferPointer?, flags: NodeFlags,
                 allocated a: Int64 = 0, logical l: Int64 = 0, fileCount: UInt32 = 0, mtime: Double = DiskTree.noMtime) -> Int32 {
        let id = Int32(parents.count)
        parents.append(parent)
        allocated.append(a)
        logical.append(l)
        mtimes.append(mtime)
        fileCounts.append(fileCount)
        var f = flags
        nameStart.append(UInt32(truncatingIfNeeded: arena.count))
        if let name, name.count > 0 {
            let n = min(name.count, Int(UInt16.max))
            arena.append(contentsOf: name.prefix(n))
            nameLen.append(UInt16(n))
            if !Self.isValidUTF8(name.prefix(n)) {
                f.insert(.nonUTF8Name)
            }
        } else {
            nameLen.append(0)
        }
        flagBits.append(f.rawValue)
        return id
    }

    @discardableResult
    func addNode(parent: Int32, name: String, flags: NodeFlags, allocated a: Int64 = 0, logical l: Int64 = 0,
                 fileCount: UInt32 = 0, mtime: Double = DiskTree.noMtime) -> Int32 {
        var s = name
        return s.withUTF8 { addNode(parent: parent, name: UnsafeRawBufferPointer($0), flags: flags, allocated: a,
                                    logical: l, fileCount: fileCount, mtime: mtime) }
    }

    private static func isValidUTF8(_ bytes: Slice<UnsafeRawBufferPointer>) -> Bool {
        var it = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&it) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    func touch(_ node: Int32, _ t: Double) {
        if t > mtimes[Int(node)] { mtimes[Int(node)] = t }
    }

    func addTotals(_ node: Int32, allocated a: Int64, logical l: Int64, files: UInt32, mtime: Double) {
        let i = Int(node)
        allocated[i] += a
        logical[i] += l
        fileCounts[i] &+= files
        if mtime > mtimes[i] { mtimes[i] = mtime }
    }

    func addFlags(_ node: Int32, _ f: NodeFlags) { flagBits[Int(node)] |= f.rawValue }

    /// Builds child lists (counting sort over `parents`), sorts each, sorts records.
    func freeze(rootPath: String, physicalRootPath: String, scope: DiskIndexer.Scope, createdAt: Date,
                stats: IndexStats, firmlinks: FirmlinkMap) -> DiskTree {
        let n = parents.count
        var counts = [UInt32](repeating: 0, count: n + 1)
        for p in parents where p >= 0 { counts[Int(p) + 1] += 1 }
        for i in 0..<n { counts[i + 1] += counts[i] }
        let start = counts
        var fill = counts
        var index = [DiskNodeID](repeating: DiskNodeID(raw: 0), count: Int(start[n]))
        for i in 0..<n where parents[i] >= 0 {
            let p = Int(parents[i])
            index[Int(fill[p])] = DiskNodeID(raw: Int32(i))
            fill[p] += 1
        }
        let allocatedCopy = allocated
        let arenaCopy = arena
        let nameStartCopy = nameStart, nameLenCopy = nameLen
        func nameBytes(_ id: DiskNodeID) -> ArraySlice<UInt8> {
            let s = Int(nameStartCopy[Int(id.raw)])
            return arenaCopy[s..<(s + Int(nameLenCopy[Int(id.raw)]))]
        }
        func canonical(_ id: DiskNodeID) -> String {
            PathCanonicalizer.fold(String(decoding: nameBytes(id), as: UTF8.self))
        }
        for i in 0..<n {
            let lo = Int(start[i]), hi = Int(start[i + 1])
            if hi - lo < 2 { continue }
            index[lo..<hi].sort { a, b in
                let x = allocatedCopy[Int(a.raw)], y = allocatedCopy[Int(b.raw)]
                if x != y { return x > y }
                let ca = canonical(a), cb = canonical(b)
                if ca != cb { return ca < cb }
                return a.raw < b.raw
            }
        }
        let core = DiskTree(rootPath: rootPath, physicalRootPath: physicalRootPath, scope: scope, createdAt: createdAt,
                            stats: stats, fileRecords: [], parents: parents, allocated: allocated, logical: logical,
                            mtimes: mtimes, fileCounts: fileCounts, flagBits: flagBits, nameStart: nameStart,
                            nameLen: nameLen, childStart: start, childIndex: index, arena: arena, firmlinks: firmlinks)
        let sorted = records.sorted { a, b in
            if a.allocatedBytes != b.allocatedBytes { return a.allocatedBytes > b.allocatedBytes }
            if a.node != b.node {
                let pa = core.path(of: a.node), pb = core.path(of: b.node)
                if pa != pb { return pa < pb }
            }
            if a.device != b.device { return a.device < b.device }
            if a.inode != b.inode { return a.inode < b.inode }
            return a.flags.rawValue < b.flags.rawValue
        }
        return core.withRecords(sorted)
    }
}
