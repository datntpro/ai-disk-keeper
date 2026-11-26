import Foundation
import XCTest
@testable import DiskKeeperCore

/// The index fast path must give exactly the verdict of the full guard for every node of a top-down walk.
final class IndexGuardDifferentialTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    }

    private let vocab = [
        ".ssh", "id_rsa", "id_rsa.pub", ".env", ".env.local", ".claude", "projects", "memory", "settings.json", "skills",
        "Library", "LIBRARY", "library", "Keychains", "Application Support", "Cursor", "User", "snippets", "Cafe\u{301}",
        "Café", "x.photoslibrary", "Photos Library.photoslibrary", ".git", "node_modules", "src", "a", "b", "build",
        ".aws", "credentials", ".gnupg", "Documents", "Desktop", "Downloads", "Mail", "Safari", "Containers",
        "settings.JSON", ".CLAUDE", "CLAUDE.md", ".codex", "auth.json", "😀", "name with space", ".npmrc", "secret.pem",
    ]

    private func differential(_ pg: ProtectedPaths, lexRoot: String, physRoot: String, seed: UInt64, count: Int, expectDeepProtected: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
        let ig = IndexGuard(pathGuard: pg, rootPath: lexRoot, physicalRoot: physRoot)
        var rng = RNG(s: seed)
        var checked = 0, deepProtected = 0
        for _ in 0..<count {
            let depth = Int.random(in: 6...16, using: &rng)
            var lex = lexRoot, name = ""
            var state: IndexGuard.State? = IndexGuard.State()  // root: assume clean-state parent only when level>0
            // classify the root first (always the full path)
            var parent = ig.full(path: lexRoot).state  // root: full evaluation, cursors from keys
            for level in 1...depth {
                name = vocab.randomElement(using: &rng)!
                lex = (lex == "/" ? "" : lex) + "/" + name
                let fast = ig.classify(path: lex, name: name, level: level, parent: parent)
                let full = ig.full(path: lex)
                // Expected: the full guard's verdict, with inheritance of protected/system as the walker defines.
                var expectedFlags = full.flags
                if parent.protected { expectedFlags = [.protected] }
                else if parent.system { expectedFlags = [.outsideCleanableRoots] }
                XCTAssertEqual(fast.flags, expectedFlags, "\(lex)", file: file, line: line)
                if fast.flags.contains(.protected) && level > 8 { deepProtected += 1 }
                parent = fast.state
                state = fast.state
                checked += 1
            }
            _ = state
        }
        XCTAssertGreaterThan(checked, count)
        if expectDeepProtected { XCTAssertGreaterThan(deepProtected, 0, "generator never reached deep protected nodes", file: file, line: line) }
    }

    func testFastPathEqualsFullGuardUnderHome() throws {
        let fx = try FixtureHome()
        let pg = try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir)
        differential(pg, lexRoot: fx.home, physRoot: fx.home, seed: 0x9E3779B97F4A7C15, count: 100, expectDeepProtected: true)
        // Roots below home and a deeper folder scope.
        differential(pg, lexRoot: fx.home + "/Library", physRoot: fx.home + "/Library", seed: 42, count: 80)
    }

    func testFastPathEqualsFullGuardWithAdditionalPatternsAndTemp() throws {
        let fx = try FixtureHome()
        let extra = [ProtectedPaths.escapeGlob(fx.home) + "/*/deep/*/pattern/**", ProtectedPaths.escapeGlob(fx.home) + "/a/b/a/b/a/b/exact"]
        let pg = try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir, additionalPatterns: extra)
        differential(pg, lexRoot: fx.home, physRoot: fx.home, seed: 7, count: 100, expectDeepProtected: true)
        differential(pg, lexRoot: fx.tempDir, physRoot: fx.tempDir, seed: 8, count: 80)
    }

    func testFastPathWithAliasedRoot() throws {
        let fx = try FixtureHome()
        let alias = fx.tmp.path("alias-to-home")
        XCTAssertEqual(symlink(fx.home, alias), 0)
        let pg = try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir)
        differential(pg, lexRoot: alias, physRoot: fx.home, seed: 99, count: 80)
    }

    func testFastPathOutsideRootsAndSystemRoots() throws {
        let fx = try FixtureHome()
        let pg = try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir)
        for root in ["/usr/local", "/Applications", "/Users", "/System/Volumes/Data", "/System/Volumes/Data/Users", "/private/var", "/"] {
            differential(pg, lexRoot: root, physRoot: root, seed: 123, count: 40)
        }
    }

    func testBoundIsAtLeastEveryBuiltInPattern() throws {
        let fx = try FixtureHome()
        let pg = try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir)
        let homeDepth = PathCanonicalizer.key(fx.home).components.count
        XCTAssertGreaterThan(pg.anchoredCursor(forKey: []).live.count, 50)
        XCTAssertEqual(pg.anchoredCursor(forKey: PathCanonicalizer.key(fx.home + "/zz").components).live.count, 0)
        _ = homeDepth
        XCTAssertTrue(pg.matchesBasename(".env"))
        XCTAssertFalse(pg.matchesBasename("report.txt"))
    }
}
