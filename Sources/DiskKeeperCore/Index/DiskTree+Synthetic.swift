import Foundation

/// Nested spec for building a `DiskTree` without touching the filesystem (layout tests in T30).
struct SyntheticNode {
    var name: String
    var flags: NodeFlags
    /// Own allocated bytes (files); directories' subtree totals are summed from children.
    var allocatedBytes: Int64
    var logicalBytes: Int64
    var modified: Double?
    var children: [SyntheticNode]

    static func dir(_ name: String, flags: NodeFlags = [], modified: Double? = nil, _ children: [SyntheticNode] = []) -> SyntheticNode {
        SyntheticNode(name: name, flags: flags.union(.directory), allocatedBytes: 0, logicalBytes: 0, modified: modified, children: children)
    }

    static func file(_ name: String, bytes: Int64, logical: Int64? = nil, flags: NodeFlags = [], modified: Double? = nil) -> SyntheticNode {
        SyntheticNode(name: name, flags: flags.union(.file), allocatedBytes: bytes, logicalBytes: logical ?? bytes, modified: modified, children: [])
    }
}

extension DiskTree {
    /// TEST-ONLY: build a tree from a nested spec. The spec's own name is the root's (ignored; root is unnamed).
    static func _synthetic(_ spec: SyntheticNode, rootPath: String) -> DiskTree {
        let b = DiskTreeBuilder()
        @discardableResult
        func add(_ s: SyntheticNode, parent: Int32, isRoot: Bool) -> Int32 {
            let isFile = !s.flags.contains(.directory)
            let id = b.addNode(parent: parent, name: isRoot ? "" : s.name, flags: s.flags, allocated: s.allocatedBytes,
                               logical: s.logicalBytes, fileCount: isFile ? 1 : 0, mtime: s.modified ?? DiskTree.noMtime)
            for c in s.children {
                let cid = add(c, parent: id, isRoot: false)
                let i = Int(cid)
                b.addTotals(id, allocated: b.allocated[i], logical: b.logical[i], files: b.fileCounts[i], mtime: b.mtimes[i])
            }
            return id
        }
        add(spec, parent: -1, isRoot: true)
        return b.freeze(rootPath: rootPath, physicalRootPath: rootPath, scope: .folder(rootPath), createdAt: Date(),
                        stats: IndexStats(), firmlinks: .empty)
    }
}
