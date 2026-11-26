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

    /// A process whose image path could not be resolved (`proc_pidpath` failed, e.g. the app file was replaced
    /// or trashed while it runs). Kept so uninstall can fail closed instead of silently ignoring it.
    public struct UnresolvedProcess: Sendable, Hashable {
        public let pid: pid_t
        public let uid: uid_t?
        /// Kernel process name (`pbi_comm`: at most 15 bytes, `MAXCOMLEN` - 1), case-folded.
        public let comm: String
        /// Longer kernel name (`pbi_name`: at most 31 bytes), case-folded; `""` when unavailable.
        public let name: String

        public init(pid: pid_t, uid: uid_t?, comm: String, name: String = "") {
            self.pid = pid
            self.uid = uid
            self.comm = comm
            self.name = name
        }
    }

    /// One walk of the process table: readable images plus the processes whose image could not be read.
    public struct Snapshot: Sendable {
        public let entries: [ProcessEntry]
        public let unresolved: [UnresolvedProcess]

        public init(entries: [ProcessEntry], unresolved: [UnresolvedProcess]) {
            self.entries = entries
            self.unresolved = unresolved
        }
    }

    /// Conservative mode: any unresolved process of the current user blocks, whatever its name. Off by
    /// default (match on the bundle's executable name only).
    public static let blockOnAnyUnresolvedUserProcess = false

    /// Byte limits the kernel applies to `pbi_comm` (`MAXCOMLEN` - 1) and `pbi_name` (`2 * MAXCOMLEN` - 1).
    static let commBytes = Int(MAXCOMLEN) - 1
    static let nameBytes = 2 * Int(MAXCOMLEN) - 1

    /// `true` if any process image lives under `bundlePath` (compared resolved and case-folded).
    /// `nil` = the process list could not be read (fail closed). Processes that vanish mid-scan are
    /// ignored; processes whose path can't be read (other users' daemons) can't live in a user-owned bundle.
    /// Also `true` when an unresolved process of the current user looks like one of this bundle's executables
    /// (see ``unresolvedMatches(executableNames:currentUID:in:conservative:)``).
    public static func isAnyProcessRunning(insideBundleAt bundlePath: String) -> Bool? {
        isAnyProcessRunning(insideBundleAt: bundlePath, in: fullSnapshot(), currentUID: getuid())
    }

    /// Same decision against an already-taken (or injected) snapshot. `nil` snapshot = unreadable (fail closed).
    public static func isAnyProcessRunning(insideBundleAt bundlePath: String, in snapshot: Snapshot?,
                                           currentUID: uid_t) -> Bool? {
        guard let snap = snapshot else { return nil }
        if !entries(insideBundleAt: bundlePath, in: snap.entries).isEmpty { return true }
        return !unresolvedMatches(for: bundlePath, currentUID: currentUID, in: snap.unresolved).isEmpty
    }

    /// ``unresolvedMatches(executableNames:currentUID:in:conservative:)`` for the bundle at `path`. Skips the
    /// bundle walk when the current user has no unresolved process at all (the usual case).
    public static func unresolvedMatches(for bundlePath: String, currentUID: uid_t,
                                         in unresolved: [UnresolvedProcess]) -> [UnresolvedProcess] {
        guard unresolved.contains(where: { $0.uid == currentUID }) else { return [] }
        return unresolvedMatches(executableNames: bundleExecutableNames(at: bundlePath), currentUID: currentUID,
                                 in: unresolved)
    }

    /// Unresolved processes owned by `currentUID` that may belong to the bundle: the kernel name (`comm`,
    /// 15 bytes, or the longer `name`, 31 bytes) equals the same-length byte prefix of one of the bundle's
    /// executable names (or, in conservative mode, any of them). Other users' processes and processes with
    /// unknown owner are ignored. Pure.
    public static func unresolvedMatches(executableNames: [String], currentUID: uid_t, in unresolved: [UnresolvedProcess],
                                         conservative: Bool = blockOnAnyUnresolvedUserProcess) -> [UnresolvedProcess] {
        let mine = unresolved.filter { $0.uid == currentUID }
        if conservative { return mine }
        let names = executableNames.filter { !$0.isEmpty }
        guard !names.isEmpty else { return [] }
        let commKeys = Set(names.map { truncated($0, bytes: commBytes) })
        let nameKeys = Set(names.map { truncated($0, bytes: nameBytes) })
        return mine.filter { commKeys.contains($0.comm) || (!$0.name.isEmpty && nameKeys.contains($0.name)) }
    }

    /// Cut at a byte count like the kernel does (possibly mid-character), then decode and case-fold; the
    /// process side is decoded the same way, so a split multibyte character compares equal on both sides.
    static func truncated(_ s: String, bytes: Int) -> String {
        PathCanonicalizer.fold(String(decoding: Array(s.utf8.prefix(bytes)), as: UTF8.self))
    }

    /// `CFBundleExecutable` of the bundle at `path`, `nil` if unreadable.
    public static func bundleExecutableName(at path: String) -> String? {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        return d["CFBundleExecutable"] as? String
    }

    /// Executable names of the bundle and everything nested in it that can run on its own: the main
    /// `CFBundleExecutable`, files in `Contents/MacOS` and `Contents/Helpers`, and the executables of nested
    /// `.app` / `.xpc` bundles (LoginItems, XPCServices, helper apps). Bounded walk; read-only.
    public static func bundleExecutableNames(at path: String, maxVisited: Int = 20_000) -> [String] {
        var names: [String] = []
        func addExecutable(ofBundle b: String) {
            for plist in ["Contents/Info.plist", "Info.plist"] {
                if let d = NSDictionary(contentsOfFile: (b as NSString).appendingPathComponent(plist)),
                   let e = d["CFBundleExecutable"] as? String { names.append(e); break }
            }
        }
        func addFiles(in dir: String) {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for i in items {
                var isDir: ObjCBool = false
                let full = (dir as NSString).appendingPathComponent(i)
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { names.append(i) }
            }
        }
        addExecutable(ofBundle: path)
        guard let walker = FileManager.default.enumerator(atPath: path) else { return Array(Set(names)) }
        var visited = 0
        while let rel = walker.nextObject() as? String {
            visited += 1
            if visited > maxVisited || walker.level > 8 { break }
            let name = (rel as NSString).lastPathComponent
            let full = (path as NSString).appendingPathComponent(rel)
            switch (name as NSString).pathExtension.lowercased() {
            case "app", "xpc": addExecutable(ofBundle: full); addFiles(in: full + "/Contents/MacOS")
            default:
                if name == "MacOS" || name == "Helpers" { addFiles(in: full) }
            }
        }
        return Array(Set(names))
    }

    /// Every process whose image path can be read, in one walk. `nil` = the list couldn't be read (fail closed).
    public static func snapshot() -> [ProcessEntry]? { fullSnapshot()?.entries }

    /// Like ``snapshot()`` but also keeps the pids whose image path could not be read. `nil` = list unreadable.
    public static func fullSnapshot() -> Snapshot? {
        let capacityHint = proc_listallpids(nil, 0)
        guard capacityHint > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacityHint) * 2 + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }

        var result: [ProcessEntry] = []
        var unresolved: [UnresolvedProcess] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if len > 0 {
                result.append(ProcessEntry(pid: pid, path: fold(String(cString: buffer)), uid: owner(of: pid)))
                continue
            }
            // Image unresolvable: keep it (fail closed) when the kernel still knows who it is.
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue } // vanished mid-scan
            let comm = withUnsafeBytes(of: info.pbi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let longName = withUnsafeBytes(of: info.pbi_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            unresolved.append(UnresolvedProcess(pid: pid, uid: info.pbi_uid, comm: PathCanonicalizer.fold(comm),
                                                name: PathCanonicalizer.fold(longName)))
        }
        return Snapshot(entries: result, unresolved: unresolved)
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
