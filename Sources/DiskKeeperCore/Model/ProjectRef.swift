import Foundation

/// The project/repo an item belongs to.
///
/// Equality and hashing use `id` ONLY, so a different `displayName` never splits a project bucket.
public struct ProjectRef: Codable, Sendable, Hashable {
    /// Canonical key: standardized absolute repo path, or "name:<decoded name>" when unknown.
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// id = standardized path, displayName = last path component.
    public init(rootURL: URL) {
        let std = rootURL.standardizedFileURL
        self.id = std.path
        self.displayName = std.lastPathComponent
    }

    public static func == (l: ProjectRef, r: ProjectRef) -> Bool { l.id == r.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
