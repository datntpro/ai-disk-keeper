import Foundation

/// Result of ``ProtectedPaths/check(_:)-7pncs``.
public enum PathVerdict: Sendable, Hashable {
    case allowed
    case denied(PathDenial)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var denial: PathDenial? {
        if case .denied(let d) = self { return d }
        return nil
    }
}

/// Why a path may not be offered, sized into an item, or acted on.
public struct PathDenial: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Reason: String, Sendable, Hashable, Codable, CaseIterable {
        /// Empty, relative, or contains NUL.
        case invalidPath
        /// The raw path has a ".." component.
        case parentTraversal
        /// The resolver failed (EACCES, ELOOP, dangling symlink, ...).
        case unresolvable
        /// "/" or under a system root.
        case systemLocation
        /// Not strictly under home, `$TMPDIR` or `/private/tmp`.
        case outsideAllowedRoots
        /// Equals an allowed root or an exact-only entry (home, ~/Documents, ...).
        case protectedLocation
        /// Equals or is inside an anchored protected pattern.
        case protectedPath
        /// Is an ancestor of an anchored protected pattern (e.g. ~/.claude).
        case containsProtectedPath
        /// A component below the allowed root matches a basename pattern.
        case protectedName

        /// Container reasons: the path itself must never be an item, but it may be scanned inside.
        public var isContainerReason: Bool {
            self == .protectedLocation || self == .containsProtectedPath
        }
    }

    /// The raw input.
    public let path: String
    public let reason: Reason
    /// Template as written in the table (e.g. "~/.ssh"); nil if not applicable.
    public let matchedPattern: String?
    /// Short reason from the table (e.g. "credentials"); nil if not applicable.
    public let why: String?
    /// True if only the resolved form was denied.
    public let viaSymlink: Bool
    /// Physical path when available.
    public let resolvedPath: String?

    public init(path: String, reason: Reason, matchedPattern: String? = nil, why: String? = nil,
                viaSymlink: Bool = false, resolvedPath: String? = nil) {
        self.path = path
        self.reason = reason
        self.matchedPattern = matchedPattern
        self.why = why
        self.viaSymlink = viaSymlink
        self.resolvedPath = resolvedPath
    }

    /// User-facing English.
    public var message: String {
        var s: String
        switch reason {
        case .invalidPath:
            s = "Not a valid absolute path: \(path)."
        case .parentTraversal:
            s = "Paths containing \"..\" are never accepted: \(path)."
        case .unresolvable:
            s = "Cannot safely resolve \(path) (unresolvable path)."
        case .systemLocation:
            s = "System location\(matched): \(path) is never touched."
        case .outsideAllowedRoots:
            s = "Outside your home folder and temporary folders: \(path)."
        case .protectedLocation:
            s = "Protected location\(matched): \(path) is a container, never an item."
        case .protectedPath:
            s = "Protected\(matched). \(path) is protected."
        case .containsProtectedPath:
            s = "Contains protected data\(matched): \(path) cannot be an item."
        case .protectedName:
            s = "Protected name\(matched): \(path) may hold secrets or instructions."
        }
        if viaSymlink, let r = resolvedPath {
            s += " \(path) resolves to \(r)."
        }
        return s
    }

    /// Stable identifier of `why` (see ``ProtectedPattern/id``) for localized reason text; nil without a reason.
    public var whyID: String? { why.map(ProtectedPattern.slug) }

    private var matched: String {
        guard let p = matchedPattern else { return "" }
        if let w = why { return ": \(p) (\(w))" }
        return ": \(p)"
    }

    public var description: String { message }
}

public enum ProtectedPathsError: Error, Sendable, Equatable {
    /// home/tmp not absolute or contain "..".
    case invalidRoot(String)
    case invalidPattern(pattern: String, reason: String)
}
