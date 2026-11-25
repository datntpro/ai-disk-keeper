import AppKit

/// Bundle id → display name ("com.anthropic.claudefordesktop" → "Claude"); falls back to the bundle id.
/// Results are cached: this is called once per visible table row.
public enum AppNameResolver {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String: String] = [:]
        func get(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return names[id] }
        func set(_ id: String, _ name: String) { lock.lock(); names[id] = name; lock.unlock() }
    }
    private static let cache = Cache()

    public static func name(forBundleID bundleID: String) -> String {
        if let hit = cache.get(bundleID) { return hit }
        let name = resolve(bundleID)
        cache.set(bundleID, name)
        return name
    }

    private static func resolve(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        if let bundle = Bundle(url: url),
           let n = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !n.isEmpty {
            return n
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
