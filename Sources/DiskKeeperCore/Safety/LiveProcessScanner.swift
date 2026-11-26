import Darwin
import Foundation

/// "Is any process executing from inside this bundle?" across ALL processes (daemons, XPC helpers, CLI
/// tools, login items), not just LaunchServices apps. Read-only (`proc_listallpids` + `proc_pidpath`).
public enum LiveProcessScanner {
    /// One process of a snapshot. `path` is the executable image, lexically normalized and case-folded.
    public struct ProcessEntry: Sendable, Hashable {
        public let pid: pid_t
        public let path: String
        /// Owner of the process; `nil` when it couldn't be read (callers treat that as "not ours").
        public let uid: uid_t?

        public init(pid: pid_t, path: String, uid: uid_t?) {
            self.pid = pid
            self.path = path
            self.uid = uid
        }
    }

    /// `true` if any process image lives under `bundlePath` (compared resolved and case-folded).
    /// `nil` = the process list could not be read (fail closed). Processes that vanish mid-scan are
    /// ignored; processes whose path can't be read (other users' daemons) can't live in a user-owned bundle.
    public static func isAnyProcessRunning(insideBundleAt bundlePath: String) -> Bool? {
        guard let snap = snapshot() else { return nil }
        return !entries(insideBundleAt: bundlePath, in: snap).isEmpty
    }

    /// Every process whose image path can be read, in one walk. `nil` = the list couldn't be read (fail closed).
    public static func snapshot() -> [ProcessEntry]? {
        let capacityHint = proc_listallpids(nil, 0)
        guard capacityHint > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacityHint) * 2 + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }

        var result: [ProcessEntry] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard len > 0 else { continue }
            result.append(ProcessEntry(pid: pid, path: fold(String(cString: buffer)), uid: owner(of: pid)))
        }
        return result
    }

    /// The entries of `snap` whose image lives inside the bundle at `path` (lexical and resolved spellings).
    public static func entries(insideBundleAt path: String, in snap: [ProcessEntry]) -> [ProcessEntry] {
        var prefixes: Set<String> = [fold(path)]
        if let r = realpath(path, nil) { prefixes.insert(fold(String(cString: r))); free(r) }
        return snap.filter { e in prefixes.contains { e.path.hasPrefix($0 + "/") } }
    }

    private static func owner(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    private static func fold(_ s: String) -> String {
        PathCanonicalizer.fold(PathNormalization.lexical(s))
    }
}
