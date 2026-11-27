import Foundation

/// The project mapping utility: folds a linked git worktree into its main repository so a project is one bucket.
///
/// Pure file reads on paths the scan already produced: no `git` process, no directory listing (so no TCC prompts).
/// Results are cached for `cacheLifetime` seconds (one scan's worth).
public final class ProjectKeyResolver: @unchecked Sendable {
    public static let shared = ProjectKeyResolver()

    private let lock = NSLock()
    private var cache: [String: (ref: ProjectRef, at: Date)] = [:]
    private let cacheLifetime: TimeInterval
    private static let maxGitFileBytes = 4096

    public init(cacheLifetime: TimeInterval = 60) { self.cacheLifetime = cacheLifetime }

    /// The repo-root project for `ref`. `name:` ids, paths outside any repo and malformed `.git` files pass through.
    public func repoRoot(for ref: ProjectRef) -> ProjectRef {
        guard ref.id.hasPrefix("/") else { return ref }
        lock.lock()
        if let hit = cache[ref.id], Date().timeIntervalSince(hit.at) < cacheLifetime {
            lock.unlock()
            return hit.ref
        }
        lock.unlock()
        let resolved = Self.resolve(ref)
        lock.lock()
        cache[ref.id] = (resolved, Date())
        lock.unlock()
        return resolved
    }

    public func reset() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    static func resolve(_ ref: ProjectRef) -> ProjectRef {
        let fm = FileManager.default
        var dir = ref.id
        while true {
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return dir == ref.id ? ref : ProjectRef(rootURL: URL(fileURLWithPath: dir)) }
                guard let main = mainRepo(gitFile: git, in: dir) else { return ref }
                return ProjectRef(rootURL: URL(fileURLWithPath: main))
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return ref }
            dir = parent
        }
    }

    /// `.git` file → `gitdir: <main>/.git/worktrees/<name>` → (`commondir`) → `<main>`.
    private static func mainRepo(gitFile: String, in dir: String) -> String? {
        guard let text = readSmall(gitFile), text.hasPrefix("gitdir:") else { return nil }
        let raw = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let gitdir = PathNormalization.lexical(raw.hasPrefix("/") ? raw : (dir as NSString).appendingPathComponent(raw))
        var common = gitdir
        if let c = readSmall((gitdir as NSString).appendingPathComponent("commondir"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            common = PathNormalization.lexical(c.hasPrefix("/") ? c : (gitdir as NSString).appendingPathComponent(c))
        } else if let r = gitdir.range(of: "/.git/worktrees/") {
            common = String(gitdir[..<r.lowerBound]) + "/.git"
        }
        guard (common as NSString).lastPathComponent == ".git" else { return nil }
        let main = (common as NSString).deletingLastPathComponent
        return main.isEmpty ? nil : main
    }

    private static func readSmall(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxGitFileBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
