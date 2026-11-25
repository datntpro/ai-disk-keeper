import Foundation

/// Locates DiskKeeperCore's SwiftPM resource bundle in every runtime layout we ship:
/// .app (Contents/Resources), `swift run` (next to the executable), and `swift test` (next to the .xctest).
/// Never uses SwiftPM's generated `Bundle.module` (its fallback differs per toolchain and can point at
/// an absolute build path, or fatalError).
public enum CoreResources {
    /// "<PackageName>_<TargetName>"; Package name is "AIDiskKeeper".
    public static let bundleName = "AIDiskKeeper_DiskKeeperCore"

    private static let _bundleURL: URL? =
        locateBundle(in: defaultCandidateDirectories())?.bundleURL

    /// nil only if the bundle is genuinely missing (packaging bug). Resolved once.
    public static var bundle: Bundle? {
        guard let url = _bundleURL else { return nil }
        return Bundle(url: url)
    }

    /// `<bundle>/…/Rules` directory, or nil if missing. Works for both the
    /// `Contents/Resources` layout and a flat bundle.
    public static var rulesDirectoryURL: URL? {
        bundle?.url(forResource: "Rules", withExtension: nil)
    }

    /// Ordered, de-duplicated candidate *parent directories*.
    static func defaultCandidateDirectories() -> [URL] {
        let marker = Bundle(for: CoreResourcesBundleMarker.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            marker.bundleURL.deletingLastPathComponent(),
            marker.resourceURL,
        ]
        var seen = Set<String>()
        var result: [URL] = []
        for url in candidates.compactMap({ $0 }) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { result.append(url) }
        }
        return result
    }

    /// First `<dir>/<bundleName>.bundle` that `Bundle(url:)` opens. Internal for tests.
    static func locateBundle(in directories: [URL]) -> Bundle? {
        for dir in directories {
            let url = dir.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }
}

/// Private marker class used only for `Bundle(for:)`.
final class CoreResourcesBundleMarker {}
