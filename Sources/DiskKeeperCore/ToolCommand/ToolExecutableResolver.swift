import Darwin
import Foundation

public enum ToolUnavailable: Error, Sendable, Hashable {
    case notFound
    case notRegularFile(String)
    case notExecutable(String)
    case unsafeOwnerOrMode(String)
    case nameMismatch(expected: String, actual: String)
}

/// Finds a tool's executable from compiled-in absolute candidates. No `PATH`, no `which`, no `/usr/bin/env`.
public struct ToolExecutableResolver: Sendable {
    public let userID: uid_t
    public init(userID: uid_t = getuid()) { self.userID = userID }

    /// The first candidate that exists. Its `realpath` must be a regular, executable file, and both the file and
    /// its parent directory must be owned by root or the user and not group- or world-writable.
    /// With `toolName`, the realpath basename must equal it (or a known alias), and every symlink hop's directory
    /// must be owned by root or the user and not group- or world-writable.
    public func resolve(candidates: [String], toolName: String? = nil) -> Result<URL, ToolUnavailable> {
        for candidate in candidates where candidate.hasPrefix("/") {
            guard let resolved = realpath(candidate, nil) else { continue }
            defer { free(resolved) }
            let real = String(cString: resolved)
            if let unsafe = unsafeHopDirectory(candidate) { return .failure(.unsafeOwnerOrMode(unsafe)) }
            if let toolName {
                let base = (real as NSString).lastPathComponent
                guard base == toolName || Self.aliases[toolName, default: []].contains(base) else {
                    return .failure(.nameMismatch(expected: toolName, actual: base))
                }
            }
            var st = stat()
            guard stat(real, &st) == 0 else { continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile(real)) }
            guard access(real, X_OK) == 0 else { return .failure(.notExecutable(real)) }
            guard isSafe(st) else { return .failure(.unsafeOwnerOrMode(real)) }
            var parent = stat()
            let parentPath = (real as NSString).deletingLastPathComponent
            guard stat(parentPath, &parent) == 0, isSafe(parent) else { return .failure(.unsafeOwnerOrMode(parentPath)) }
            return .success(URL(fileURLWithPath: real))
        }
        return .failure(.notFound)
    }

    /// Real executable names a vendor ships behind the tool's name (Docker Desktop's CLI).
    static let aliases: [String: Set<String>] = ["docker": ["com.docker.cli"]]

    /// Walks the symlink chain from `candidate`; returns the first hop whose containing directory is unsafe.
    private func unsafeHopDirectory(_ candidate: String) -> String? {
        var current = candidate
        for _ in 0..<32 {
            var st = stat()
            guard lstat(current, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return nil }
            let dir = (current as NSString).deletingLastPathComponent
            var d = stat()
            guard stat(dir, &d) == 0, isSafe(d) else { return dir }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(current, &buf, Int(PATH_MAX))
            guard n > 0 else { return nil }
            let target = String(cString: buf.prefix(n).map { $0 } + [0])
            current = target.hasPrefix("/") ? target : (dir as NSString).appendingPathComponent(target)
            current = (current as NSString).standardizingPath
        }
        return current
    }

    private func isSafe(_ st: stat) -> Bool {
        (st.st_uid == 0 || st.st_uid == userID) && (st.st_mode & 0o022) == 0
    }
}
