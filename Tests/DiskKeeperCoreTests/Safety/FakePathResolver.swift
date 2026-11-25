@testable import DiskKeeperCore

/// Maps exact paths to resolutions; anything else resolves to itself.
struct FakePathResolver: PathResolving {
    var map: [String: PathResolution] = [:]
    var fallback: (@Sendable (String) -> PathResolution)?

    func resolve(_ absolutePath: String) -> PathResolution {
        if let r = map[absolutePath] { return r }
        if let f = fallback { return f(absolutePath) }
        return .resolved(absolutePath)
    }
}
