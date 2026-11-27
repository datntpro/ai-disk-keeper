import Darwin
import Foundation

public struct WorktreeRef: Sendable, Hashable {
    /// The directory holding `.git` (a main checkout or a linked worktree).
    public let root: String
    /// The main checkout this worktree belongs to (== `root` when it is not a linked worktree).
    public let repoRoot: String
    public let isLinkedWorktree: Bool
    public let displayName: String

    public init(root: String, repoRoot: String, isLinkedWorktree: Bool) {
        self.root = root
        self.repoRoot = repoRoot
        self.isLinkedWorktree = isLinkedWorktree
        self.displayName = (root as NSString).lastPathComponent
    }
}

/// Maps a process's cwd to the git checkout that holds it. Walks up from the cwd to the first directory with `.git`
/// (a directory, or a file for a linked worktree), never above `home` and never `home` itself. Reads at most 4 KiB
/// of a `.git` file and nothing else. The result is cached per directory until `resetCache()`.
public struct WorktreeAttribution: Sendable {
    private let homes: [String]
    private var cache: [String: WorktreeRef?] = [:]

    public init(home: String) {
        var list = [Self.trimmed(home)]
        let real = realpathString(home)
        if let real, Self.trimmed(real) != list[0] { list.append(Self.trimmed(real)) }
        self.homes = list
    }

    public mutating func resetCache() { cache.removeAll(keepingCapacity: true) }

    public mutating func root(forCWD cwd: String) -> WorktreeRef? {
        guard cwd.hasPrefix("/") else { return nil }
        let start = Self.trimmed(cwd)
        guard homes.contains(where: { start.hasPrefix($0 + "/") }) else { return nil }   // strictly below home
        var visited: [String] = []
        var dir = start
        var result: WorktreeRef?
        while homes.contains(where: { dir.hasPrefix($0 + "/") }) {
            if let hit = cache[dir] { result = hit; break }
            visited.append(dir)
            if let found = inspect(dir) {
                result = found.ref
                if found.stop { break }
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        for d in visited { cache[d] = .some(result) }
        return result
    }

    /// `ref == nil, stop == true`: a malformed `.git` file, so the walk ends with no attribution.
    private func inspect(_ dir: String) -> (ref: WorktreeRef?, stop: Bool)? {
        let gitPath = dir + "/.git"
        var st = stat()
        guard lstat(gitPath, &st) == 0 else { return nil }
        if (st.st_mode & S_IFMT) == S_IFDIR { return (WorktreeRef(root: dir, repoRoot: dir, isLinkedWorktree: false), true) }
        guard (st.st_mode & S_IFMT) == S_IFREG, let gitdir = Self.gitdir(fromFile: gitPath, in: dir) else { return (nil, true) }
        if let range = gitdir.range(of: "/.git/worktrees/") {
            let main = String(gitdir[gitdir.startIndex..<range.lowerBound])
            return (WorktreeRef(root: dir, repoRoot: main.isEmpty ? dir : main, isLinkedWorktree: true), true)
        }
        // A submodule (`.git/modules/…`) or a separate git dir: its own checkout.
        return (WorktreeRef(root: dir, repoRoot: dir, isLinkedWorktree: false), true)
    }

    /// "gitdir: <path>" from the first line of a `.git` file; relative paths resolve against `dir`.
    static func gitdir(fromFile path: String, in dir: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let text = String(bytes: buf.prefix(n), encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("gitdir:") else { return nil }
        let value = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let absolute = value.hasPrefix("/") ? value : dir + "/" + value
        return URL(fileURLWithPath: absolute).standardized.path   // not NSString.standardizingPath: it rewrites /private/var
    }

    private static func trimmed(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
}

private func realpathString(_ path: String) -> String? {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(path, &buf) == nil ? nil : String(cString: buf)
}
