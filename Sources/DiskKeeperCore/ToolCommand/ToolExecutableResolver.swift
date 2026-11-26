import Darwin
import Foundation

public enum ToolUnavailable: Error, Sendable, Hashable {
    case notFound
    case notRegularFile(String)
    case notExecutable(String)
    case unsafeOwnerOrMode(String)
}

/// Finds a tool's executable from compiled-in absolute candidates. No `PATH`, no `which`, no `/usr/bin/env`.
public struct ToolExecutableResolver: Sendable {
    public let userID: uid_t
    public init(userID: uid_t = getuid()) { self.userID = userID }

    /// The first candidate that exists. Its `realpath` must be a regular, executable file, and both the file and
    /// its parent directory must be owned by root or the user and not group- or world-writable.
    public func resolve(candidates: [String]) -> Result<URL, ToolUnavailable> {
        for candidate in candidates where candidate.hasPrefix("/") {
            guard let resolved = realpath(candidate, nil) else { continue }
            defer { free(resolved) }
            let real = String(cString: resolved)
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

    private func isSafe(_ st: stat) -> Bool {
        (st.st_uid == 0 || st.st_uid == userID) && (st.st_mode & 0o022) == 0
    }
}
