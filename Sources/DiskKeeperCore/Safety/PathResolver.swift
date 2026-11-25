import Darwin
import Foundation

public enum PathResolution: Sendable, Hashable {
    /// Absolute physical path; may include trailing not-yet-existing components.
    case resolved(String)
    case failed(errno: Int32)
}

public protocol PathResolving: Sendable {
    func resolve(_ absolutePath: String) -> PathResolution
}

/// Read-only resolver: only `realpath` and `lstat`.
public struct SystemPathResolver: PathResolving {
    public init() {}

    public func resolve(_ absolutePath: String) -> PathResolution {
        if let r = Self.realpathString(absolutePath) { return .resolved(r) }
        let err = errno
        guard err == ENOENT || err == ENOTDIR else { return .failed(errno: err) }

        // Walk up to the deepest existing prefix.
        var comps = PathNormalization.components(absolutePath).map(String.init)
        var dropped: [String] = []
        while true {
            let prefix = "/" + comps.joined(separator: "/")
            var st = stat()
            if lstat(prefix, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFLNK {
                    // Dangling only if the target is missing; otherwise resolve through it.
                    var target = stat()
                    if stat(prefix, &target) != 0 {
                        let e = errno
                        return .failed(errno: (e == ENOENT || e == ENOTDIR) ? ENOENT : e)
                    }
                }
                guard let real = Self.realpathString(prefix) else { return .failed(errno: errno) }
                let tail = dropped.reversed().joined(separator: "/")
                if tail.isEmpty { return .resolved(real) }
                return .resolved(real == "/" ? "/" + tail : real + "/" + tail)
            }
            let e = errno
            guard e == ENOENT || e == ENOTDIR else { return .failed(errno: e) }
            guard let last = comps.popLast() else { return .failed(errno: ENOENT) }
            dropped.append(last)
        }
    }

    private static func realpathString(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
