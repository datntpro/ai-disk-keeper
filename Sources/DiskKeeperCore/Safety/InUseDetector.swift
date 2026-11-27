import Darwin
import Foundation

/// A process of the current user and the paths it keeps busy: its working directory and its open files.
public struct ProcessHold: Sendable, Hashable {
    public let pid: pid_t
    public let name: String
    public let uid: uid_t
    public let cwd: String?
    public let openPaths: [String]

    public init(pid: pid_t, name: String, uid: uid_t, cwd: String? = nil, openPaths: [String] = []) {
        self.pid = pid; self.name = name; self.uid = uid; self.cwd = cwd
        self.openPaths = openPaths
    }
}

public protocol ProcessUsageSource: Sendable {
    /// One fresh snapshot of the user's processes. nil = unreadable (callers fail closed).
    func snapshot(userID: uid_t) -> [ProcessHold]?
}

/// Built on `ProcessTable` (cwd) plus ``LibprocOpenFiles`` (open fds). Own uid only; pid <= 1 and this process are skipped. Every path is kept (not only under `$HOME`): a filter would let an
/// item on another volume look free.
public struct LibprocUsageSource: ProcessUsageSource {
    private let table: any ProcessTableReading
    private let files: any OpenFileReading
    private let selfPID: pid_t

    public init(table: any ProcessTableReading = LibprocProcessTable(), files: any OpenFileReading = LibprocOpenFiles(),
                selfPID: pid_t = getpid()) {
        self.table = table
        self.files = files
        self.selfPID = selfPID
    }

    public func snapshot(userID: uid_t) -> [ProcessHold]? {
        guard let snap = table.snapshot() else { return nil }
        var out: [ProcessHold] = []
        for r in snap.records where r.pid > 1 && r.pid != selfPID && r.uid == userID {
            out.append(ProcessHold(pid: r.pid, name: r.name, uid: r.uid, cwd: r.cwd,
                                   openPaths: files.openPaths(of: r.pid) ?? []))
        }
        return out
    }
}

/// Which process holds a path. Trie of path components: a lookup walks the item's own components, so a held path
/// that is equal to or inside the item is found, a sibling that merely shares a name prefix (`/a/bc` vs `/a/b`) is not.
public struct InUseIndex: Sendable {
    private final class Node: @unchecked Sendable {
        var children: [String: Node] = [:]
        var holder: ProcessHold?
    }
    private let root = Node()
    public init(_ snapshot: [ProcessHold], currentUID: uid_t? = nil) {
        for p in snapshot {
            if let currentUID, p.uid != currentUID { continue }
            for path in ([p.cwd].compactMap { $0 } + p.openPaths) { insert(path, p) }
        }
    }

    private func insert(_ path: String, _ p: ProcessHold) {
        var node = root
        for c in PathCanonicalizer.key(path).components {
            if let n = node.children[c] { node = n } else { let n = Node(); node.children[c] = n; node = n }
            if node.holder == nil { node.holder = p }
        }
    }

    /// Any held path equal to or under `itemPath` (lexical spelling, and the `realpath` spelling when it differs).
    public func holder(of itemPath: String) -> ProcessHold? {
        var spellings = [itemPath]
        if let r = realpath(itemPath, nil) {
            let s = String(cString: r); free(r)
            if PathCanonicalizer.key(s) != PathCanonicalizer.key(itemPath) { spellings.append(s) }
        }
        for s in spellings {
            var node: Node? = root
            for c in PathCanonicalizer.key(s).components {
                node = node?.children[c]
                if node == nil { break }
            }
            if let n = node, n !== root, let h = n.holder { return h }
        }
        return nil
    }
}
