import Foundation

/// Paths for objects that are not files (a Docker image, a container, …). They live under a reserved root that
/// never exists on disk and sits outside every allowed root, so the guard denies them for every normal scanner.
/// Shape: `/.aidiskkeeper-virtual/<namespace>/<target>/<kind>/<id>`.
public enum VirtualItemPath {
    public static let root = "/.aidiskkeeper-virtual"

    public struct Parsed: Sendable, Hashable {
        public let namespace: String
        public let target: String
        public let kind: String
        public let id: String
    }

    /// nil when a component is empty, contains `/`, NUL or is `.`/`..`.
    public static func build(namespace: String, target: String, kind: String, id: String) -> String? {
        let parts = [namespace, target, kind, id]
        guard parts.allSatisfy(isValidComponent) else { return nil }
        return ([root] + parts).joined(separator: "/")
    }

    public static func parse(_ path: String) -> Parsed? {
        guard path.hasPrefix(root + "/") else { return nil }
        let parts = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts.allSatisfy(isValidComponent) else { return nil }
        return Parsed(namespace: parts[0], target: parts[1], kind: parts[2], id: parts[3])
    }

    private static func isValidComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0")
    }
}

extension ScanItem {
    /// True for items whose path is under the reserved virtual root (no file behind them).
    public var isVirtual: Bool { VirtualItemPath.parse(path) != nil }
}
