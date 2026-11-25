import Foundation

/// Pure parsers for git plumbing/porcelain output. No process spawning, no filesystem access.
enum GitPorcelain {
    // MARK: worktree list --porcelain -z

    static func parseWorktreeList(_ data: Data) -> [GitWorktreeEntry] {
        let fields = splitNUL(data)
        var entries: [GitWorktreeEntry] = []
        var current: GitWorktreeEntry?
        func flush() {
            if var c = current {
                c.isMain = entries.isEmpty
                entries.append(c)
            }
            current = nil
        }
        for f in fields {
            if f.isEmpty {
                flush()
                continue
            }
            let (key, value) = splitFirstSpace(f)
            if key == "worktree" {
                flush()
                current = GitWorktreeEntry(path: value ?? "")
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch": current?.branch = value
            case "detached": current?.isDetached = true
            case "bare": current?.isBare = true
            case "locked":
                current?.isLocked = true
                current?.lockReason = value
            case "prunable":
                current?.isPrunable = true
                current?.prunableReason = value
            default: break  // forward compatibility
            }
        }
        flush()
        return entries
    }

    // MARK: status --porcelain=v2 --branch --show-stash -z

    struct StatusResult: Equatable {
        var oid: String?
        var headName: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var stashTotal: Int?
        var workingTree = GitState.WorkingTree()
    }

    static func parseStatus(_ data: Data, truncated: Bool) -> StatusResult {
        var fields = splitNUL(data)
        if truncated, !fields.isEmpty { fields.removeLast() }  // last record may be partial
        var r = StatusResult()
        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            if f.hasPrefix("# ") {
                let parts = f.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let value = String(parts[1])
                switch parts[0] {
                case "branch.oid": r.oid = value
                case "branch.head": r.headName = value
                case "branch.upstream": r.upstream = value
                case "branch.ab":
                    let ab = value.split(separator: " ")
                    if ab.count == 2, let a = Int(ab[0].dropFirst()), let b = Int(ab[1].dropFirst()) {
                        r.ahead = a
                        r.behind = b
                    }
                case "stash": r.stashTotal = Int(value)
                default: break
                }
                continue
            }
            guard let kind = f.first else { continue }
            switch kind {
            case "1", "2":
                let splits = kind == "1" ? 8 : 9
                let p = f.split(separator: " ", maxSplits: splits, omittingEmptySubsequences: false)
                if kind == "2" { i += 1 }  // consume the origPath field
                guard p.count >= 3 else { continue }
                let xy = Array(p[1])
                let sub = Array(p[2])
                guard xy.count == 2, sub.count == 4 else { continue }
                if xy[0] != "." { r.workingTree.staged += 1 }
                if xy[1] != "." {
                    let subDirty = sub[0] == "S" && (sub[1] != "." || sub[2] != "." || sub[3] != ".")
                    if subDirty { r.workingTree.submodulesDirty += 1 } else { r.workingTree.unstaged += 1 }
                }
            case "u": r.workingTree.conflicted += 1
            case "?": r.workingTree.untracked += 1
            default: break
            }
        }
        r.workingTree.isLowerBound = truncated
        return r
    }

    // MARK: stash list -z --format=%gd%x1f%ct%x1f%gs

    struct StashRecord: Equatable {
        var ref: String
        var date: Date?
        var subject: String
    }

    static func parseStashList(_ data: Data) -> [StashRecord] {
        splitNUL(data).compactMap { rec in
            let p = rec.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard p.count == 3 else { return nil }
            return StashRecord(
                ref: String(p[0]), date: TimeInterval(p[1]).map { Date(timeIntervalSince1970: $0) },
                subject: String(p[2]))
        }
    }

    static func stashSummary(_ records: [StashRecord], branch: String?) -> GitState.Stash {
        var mentioning = 0
        if let branch {
            mentioning = records.filter {
                $0.subject.hasPrefix("WIP on \(branch):") || $0.subject.hasPrefix("On \(branch):")
            }.count
        }
        return GitState.Stash(
            total: records.count, mentioningBranch: mentioning, newestDate: records.compactMap(\.date).max())
    }

    // MARK: rev-parse discovery (`--is-bare-repository --is-shallow-repository [--show-superproject-working-tree]`)

    struct Discovery: Equatable {
        var isBare: Bool
        var isShallow: Bool
        var superproject: String?
    }

    static func parseDiscovery(_ output: String) -> Discovery? {
        var lines = output.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2, let bare = Bool(lines[0]), let shallow = Bool(lines[1]) else { return nil }
        let sup = lines.dropFirst(2).joined(separator: "\n")
        return Discovery(isBare: bare, isShallow: shallow, superproject: sup.isEmpty ? nil : sup)
    }

    // MARK: git version

    static func parseGitVersion(_ s: String) -> (major: Int, minor: Int, patch: Int)? {
        let prefix = "git version "
        guard s.hasPrefix(prefix) else { return nil }
        let token = s.dropFirst(prefix.count).split(whereSeparator: { $0 == " " || $0 == "\n" }).first ?? ""
        let nums = token.split(separator: ".", omittingEmptySubsequences: false)
        guard nums.count >= 2, let ma = Int(nums[0]), let mi = Int(nums[1]) else { return nil }
        let pa = nums.count > 2 ? Int(nums[2]) ?? 0 : 0
        return (ma, mi, pa)
    }

    /// `worktree list -z` needs git 2.36.
    static func isVersionSupported(_ v: (major: Int, minor: Int, patch: Int)) -> Bool {
        (v.major, v.minor) >= (2, 36)
    }

    // MARK: helpers

    static func splitNUL(_ data: Data) -> [String] {
        var out: [String] = []
        var start = data.startIndex
        for i in data.indices where data[i] == 0 {
            out.append(String(decoding: data[start..<i], as: UTF8.self))
            start = data.index(after: i)
        }
        if start < data.endIndex { out.append(String(decoding: data[start...], as: UTF8.self)) }
        return out
    }

    private static func splitFirstSpace(_ s: String) -> (String, String?) {
        guard let idx = s.firstIndex(of: " ") else { return (s, nil) }
        return (String(s[..<idx]), String(s[s.index(after: idx)...]))
    }
}
