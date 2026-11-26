import Darwin
import Foundation
@testable import DiskKeeperCore

/// A fake `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons` inside a temp dir.
final class StartupFixture {
    let home: FixtureHome
    let roots: StartupRoots

    init() throws {
        home = try FixtureHome()
        roots = StartupRoots(userAgents: home.abs("Library/LaunchAgents"), systemAgents: home.abs("$TMP/sys/LaunchAgents"),
                             systemDaemons: home.abs("$TMP/sys/LaunchDaemons"))
        for r in [roots.userAgents, roots.systemAgents, roots.systemDaemons] {
            try FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func plist(_ root: String, _ name: String, _ dict: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let path = root + "/" + name
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func scanner(loaded: LaunchctlLoadedState? = nil, userID: uid_t = getuid(),
                 signatures: any CodeSignatureReading = FakeSignatures()) -> StartupItemScanner {
        StartupItemScanner(roots: roots, signatures: signatures, loaded: loaded, userID: userID)
    }

    /// An executable script in the temp dir that records argv, then runs `body`.
    func script(_ body: String, name: String = "launchctl") throws -> URL {
        let url = URL(fileURLWithPath: home.abs("$TMP/\(name)"))
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }

    static var launchctlSample: String { LaunchctlPrintSample.text }
}
