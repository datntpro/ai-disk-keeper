import Darwin
import Foundation

/// Safe items must come from the folder they are named for. A scan root counts only when it resolves to itself:
/// `realpath(root)` equals `realpath(home)` plus the root's path below home. If `~/.tart` or `~/Library/Developer/Xcode`
/// is a symlink to, say, `~/Documents/stuff`, the content there is not necessarily a cache, so nothing is offered.
enum BuildCacheRoot {
    static func resolvesToItself(_ root: String, home: String) -> Bool {
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard root.hasPrefix(homePrefix), let realHome = realpath(of: home), let real = realpath(of: root) else { return false }
        let below = String(root.dropFirst(homePrefix.count))
        return real == (realHome == "/" ? "" : realHome) + "/" + below
    }

    private static func realpath(of path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
