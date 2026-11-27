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
            let real: String
            switch walk(candidate) {
            case .missing: continue
            case .unsafe(let dir): return .failure(.unsafeOwnerOrMode(dir))
            case .resolved(let r): real = r
            }
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

    private enum Walk { case missing, unsafe(String), resolved(String) }

    /// `realpath` by hand, one component at a time and purely lexical on the already-resolved prefix. Every symlink
    /// met, file or directory, absolute or relative, makes the directory that holds it subject to `isSafe`.
    private func walk(_ path: String) -> Walk {
        var resolved = "/"
        var pending = path.split(separator: "/").map(String.init).reversed().map { $0 }   // used as a stack
        var hops = 0
        while let comp = pending.popLast() {
            if comp == "." { continue }
            if comp == ".." {
                resolved = resolved == "/" ? "/" : (resolved as NSString).deletingLastPathComponent
                if resolved.isEmpty { resolved = "/" }
                continue
            }
            let next = resolved == "/" ? "/" + comp : resolved + "/" + comp
            var st = stat()
            guard lstat(next, &st) == 0 else { return .missing }
            guard (st.st_mode & S_IFMT) == S_IFLNK else { resolved = next; continue }
            hops += 1
            guard hops <= 40 else { return .missing }
            var holder = stat()
            guard stat(resolved, &holder) == 0, isSafe(holder) else { return .unsafe(resolved) }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(next, &buf, Int(PATH_MAX))
            guard n > 0 else { return .missing }
            let target = String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if target.hasPrefix("/") { resolved = "/" }
            pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        }
        return .resolved(resolved)
    }

    private func isSafe(_ st: stat) -> Bool {
        (st.st_uid == 0 || st.st_uid == userID) && (st.st_mode & 0o022) == 0
    }
}
