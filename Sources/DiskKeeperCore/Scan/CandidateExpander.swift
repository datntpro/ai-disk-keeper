import Darwin
import Foundation

struct RuleCandidate: Sendable, Hashable {
    /// Absolute, lexical; joined with "/" (never URL.appendingPathComponent).
    let path: String
    /// The expanded rule path it came from.
    let containerPath: String
    let isDirectory: Bool
    let ownerUID: uid_t
    /// The candidate itself lives on another device than its container (it is a mount point).
    var onOtherVolume = false
}

struct ExpansionResult: Sendable {
    var candidates: [RuleCandidate] = []
    var warnings: [ScanWarning] = []
    /// Candidates dropped silently because the guard denied them (stats only, never a warning).
    var guardDropped = 0
    /// Candidates dropped silently because another user owns them.
    var ownerDropped = 0
}

/// Executes a rule's `match`. Read-only syscalls only (`lstat`, directory listing).
enum CandidateExpander {
    static let maxCandidatesPerRule = 20_000

    static func defaultDeviceOf(_ path: String) -> dev_t {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_dev : 0
    }

    /// Throws only `CancellationError` (checked once per directory entry via `Task.checkCancellation()`).
    /// `cap` and `deviceOf` are injectable for tests.
    static func expand(_ rule: ResolvedRule, userID: uid_t, pathGuard: ScanGuard,
                       cap: Int = maxCandidatesPerRule,
                       deviceOf: @escaping (String) -> dev_t = defaultDeviceOf) throws -> ExpansionResult {
        var run = Run(rule: rule, userID: userID, pathGuard: pathGuard, cap: cap, deviceOf: deviceOf)
        var seen = Set<PathKey>()
        for container in rule.expandedPaths {
            try Task.checkCancellation()
            guard seen.insert(PathCanonicalizer.key(container)).inserted else { continue }
            try run.expandContainer(container)
            if run.capped { break }
        }
        if run.capped {
            run.result.warnings.append(ScanWarning(
                kind: .other, ruleID: rule.rule.id,
                message: "rule \(rule.rule.id) produced more than \(cap) items; the rest were skipped"))
        }
        return run.result
    }

    private struct Run {
        let rule: ResolvedRule
        let userID: uid_t
        let pathGuard: ScanGuard
        let cap: Int
        let deviceOf: (String) -> dev_t
        var result = ExpansionResult()
        var capped = false
        var containerDevice: dev_t = 0

        init(rule: ResolvedRule, userID: uid_t, pathGuard: ScanGuard, cap: Int, deviceOf: @escaping (String) -> dev_t) {
            self.rule = rule
            self.userID = userID
            self.pathGuard = pathGuard
            self.cap = cap
            self.deviceOf = deviceOf
        }

        var match: RuleMatch { rule.rule.match }
        var ruleID: String { rule.rule.id }

        mutating func warn(_ kind: ScanWarning.Kind, _ path: String, _ message: String) {
            result.warnings.append(ScanWarning(kind: kind, path: path, ruleID: ruleID, message: message))
        }

        /// Reports an errno from touching `path`; ENOENT/ENOTDIR are silent (vanished or tool not installed).
        mutating func report(errno code: Int32, path: String, what: String) {
            switch code {
            case ENOENT, ENOTDIR: break
            case EACCES: warn(.permissionDenied, path, "cannot read \(path): permission denied")
            case EPERM: warn(.needsFullDiskAccess, path, "cannot read \(path): not permitted (Full Disk Access?)")
            default: warn(.other, path, "cannot \(what) \(path): \(String(cString: strerror(code)))")
            }
        }

        mutating func expandContainer(_ container: String) throws {
            var st = stat()
            guard lstat(container, &st) == 0 else {
                report(errno: errno, path: container, what: "read")
                return
            }
            let isLink = (st.st_mode & S_IFMT) == S_IFLNK
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            switch match.kind {
            case .self:
                guard !isLink else { return }
                offer(container, container: container, st: st)
            case .children, .find:
                guard isDir else {
                    warn(.other, container, "\(container) is not a directory or is a symlink")
                    return
                }
                containerDevice = deviceOf(container)
                if match.kind == .children {
                    try children(dir: container, level: 1, container: container)
                } else {
                    try find(dir: container, level: 1, container: container, device: deviceOf(container))
                }
            }
        }

        // MARK: children

        private func startsWithDot(_ s: String) -> Bool { s.unicodeScalars.first == "." }

        mutating func children(dir: String, level: Int, container: String) throws {
            let names: [String]
            switch listNames(dir) {
            case .success(let n): names = n.sorted()
            case .failure(let e): report(errno: e.code, path: dir, what: "list"); return
            }
            let showHidden = match.includeHidden || (match.glob.map { startsWithDot($0.pattern) } ?? false)
            for name in names {
                try Task.checkCancellation()
                if capped { return }
                if startsWithDot(name) && !showHidden { continue }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let fmt = st.st_mode & S_IFMT
                if level < match.depth {
                    guard fmt == S_IFDIR else { continue }   // never follow symlinks through intermediate levels
                    try children(dir: path, level: level + 1, container: container)
                    continue
                }
                guard fmt != S_IFLNK else { continue }
                guard match.glob?.matches(name) ?? true else { continue }
                guard !match.exclude.contains(where: { $0.matchesEither(name) }) else { continue }
                guard typeMatches(fmt) else { continue }
                offer(path, container: container, st: st)
            }
        }

        // MARK: find

        mutating func find(dir: String, level: Int, container: String, device: dev_t) throws {
            let names: [String]
            switch listNames(dir) {
            case .success(let n): names = n.sorted()
            case .failure(let e): report(errno: e.code, path: dir, what: "list"); return
            }
            for name in names {
                try Task.checkCancellation()
                if capped { return }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let fmt = st.st_mode & S_IFMT
                guard fmt != S_IFLNK else { continue }
                if match.exclude.contains(where: { $0.matchesEither(name) }) { continue }
                var hit = false
                if match.name?.matches(name) ?? false, typeMatches(fmt), let marker = match.marker {
                    var m = stat()
                    hit = lstat(dir + "/" + marker, &m) == 0
                }
                if hit {
                    offer(path, container: container, st: st)
                    if match.prune { continue }
                }
                guard fmt == S_IFDIR, level < (match.maxDepth ?? 1) else { continue }
                if isSkippedName(name) || deviceOf(path) != device { continue }
                if let denial = pathGuard.check(path).denial, !denial.reason.isContainerReason { continue }
                try find(dir: path, level: level + 1, container: container, device: device)
            }
        }

        /// `.git` and `node_modules`, scalar-wise and ASCII case-insensitive.
        private func isSkippedName(_ name: String) -> Bool {
            func lower(_ s: String) -> [UInt32] {
                s.unicodeScalars.map { ($0.value >= 0x41 && $0.value <= 0x5A) ? $0.value + 32 : $0.value }
            }
            let n = lower(name)
            return n == lower(".git") || n == lower("node_modules")
        }

        // MARK: shared

        private func typeMatches(_ fmt: mode_t) -> Bool {
            switch match.type {
            case .directory: return fmt == S_IFDIR
            case .file: return fmt == S_IFREG
            case .any: return fmt != S_IFLNK
            }
        }

        /// Applies the guard, the owner check and the cap, then records the candidate.
        mutating func offer(_ path: String, container: String, st: stat) {
            guard !capped else { return }
            guard pathGuard.check(path).isAllowed else { result.guardDropped += 1; return }
            guard st.st_uid == userID else { result.ownerDropped += 1; return }
            if result.candidates.count >= cap { capped = true; return }
            result.candidates.append(RuleCandidate(
                path: path, containerPath: container,
                isDirectory: (st.st_mode & S_IFMT) == S_IFDIR, ownerUID: st.st_uid,
                onOtherVolume: match.kind != .self && deviceOf(path) != containerDevice))
        }

        struct ListError: Error { let code: Int32 }

        func listNames(_ path: String) -> Result<[String], ListError> {
            guard let dp = opendir(path) else { return .failure(ListError(code: errno)) }
            defer { closedir(dp) }
            var names: [String] = []
            while let entry = readdir(dp) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
                }
                guard let name, name != ".", name != ".." else { continue }
                names.append(name)
            }
            return .success(names)
        }
    }
}
