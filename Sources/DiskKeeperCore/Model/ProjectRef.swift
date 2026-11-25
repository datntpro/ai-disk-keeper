import Foundation

/// The project/repo an item belongs to.
///
/// Equality and hashing use `id` ONLY, so a different `displayName` never splits a project bucket.
public struct ProjectRef: Codable, Sendable, Hashable {
    /// Canonical key: lexically normalized absolute repo path (`/private` preserved), or "name:<decoded name>" when unknown.
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// id = lexically normalized path, displayName = last path component.
    public init(rootURL: URL) {
        let path = PathNormalization.lexical(rootURL.absoluteURL.path)
        self.id = path
        self.displayName = PathNormalization.components(path).last.map(String.init) ?? "/"
    }

    public static func == (l: ProjectRef, r: ProjectRef) -> Bool { l.id == r.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
