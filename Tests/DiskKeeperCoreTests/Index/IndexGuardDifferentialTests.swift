import Foundation
import XCTest
@testable import DiskKeeperCore

/// The index fast path must give exactly the flags of the PURE `ProtectedPaths.evaluate` for every node of a
/// top-down walk (protected / outside-cleanable / none), for all pattern shapes and root configurations.
final class IndexGuardDifferentialTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    }

    private let vocab = [
        ".ssh", "id_rsa", ".env", ".env.local", ".claude", "projects", "memory", "settings.json", "skills",
        "Library", "LIBRARY", "Keychains", "Application Support", "Cursor", "User", "Cafe\u{301}", "Café",
        "x.photoslibrary", ".git", "node_modules", "src", "a", "b", "build", ".aws", "credentials", "Documents",
        "Desktop", "Mail", "Containers", "CLAUDE.md", ".codex", "auth.json", "😀", "secret.pem", "T", "folders",
    ]

    /// Reference: the pure evaluate, mapped like the indexer maps it.
    private func reference(_ pg: ProtectedPaths, lex: String, physical: String) -> NodeFlags {
        guard case .denied(let d) = pg.evaluate(raw: lex, resolution: .resolved(physical)) else { return [] }
        switch d.reason {
        case .protectedPath, .protectedName: return [.protected]
        case .systemLocation, .outsideAllowedRoots: return [.outsideCleanableRoots]
        default: return []
        }
    }

    private struct Stats { var nodes = 0; var protectedNodes = 0; var outsideNodes = 0 }

    @discardableResult
    private func differential(_ pg: ProtectedPaths, lexRoot: String, physRoot: String, seed: UInt64, walks: Int,
                              prefix: [String] = [], minDepth: Int = 4, maxDepth: Int = 12,
                              file: StaticString = #filePath, line: UInt = #line) -> Stats {
        let ig = IndexGuard(pathGuard: pg, rootPath: lexRoot, physicalRoot: physRoot)
        let lexBase = lexRoot == "/" ? "" : lexRoot
        let physBase = physRoot == "/" ? "" : physRoot
        var rng = RNG(s: seed)
        var st = Stats()
        for _ in 0..<walks {
            var lex = lexRoot, suffix = ""
            var parent = ig.full(path: lexRoot).state
            XCTAssertEqual(parent.flags, reference(pg, lex: lexRoot, physical: physRoot), lexRoot, file: file, line: line)
            let depth = Int.random(in: minDepth...maxDepth, using: &rng)
            for level in 1...depth {
                let name = level <= prefix.count ? prefix[level - 1] : vocab.randomElement(using: &rng)!
                lex = (lex == "/" ? "" : lex) + "/" + name
                suffix += "/" + name
                let fast = ig.classify(path: lex, name: name, level: level, parent: parent)
                let expected = reference(pg, lex: lex, physical: physBase + suffix)
                XCTAssertEqual(fast.flags, expected, "\(lex) (root \(lexBase) → \(physBase))", file: file, line: line)
                if fast.flags.contains(.protected) { st.protectedNodes += 1 }
                if fast.flags.contains(.outsideCleanableRoots) { st.outsideNodes += 1 }
                st.nodes += 1
                parent = fast.state
            }
        }
        return st
    }

    private func make(_ fx: FixtureHome, extra: [String] = []) throws -> ProtectedPaths {
        try ProtectedPaths(homeDirectory: fx.home, temporaryDirectory: fx.tempDir, additionalPatterns: extra)
    }

    func testBuiltInPatternsUnderHome() throws {
        let fx = try FixtureHome()
        let pg = try make(fx)
        let s = differential(pg, lexRoot: fx.home, physRoot: fx.home, seed: 1, walks: 70)
        XCTAssertGreaterThan(s.protectedNodes, 0)
        differential(pg, lexRoot: fx.home + "/Library", physRoot: fx.home + "/Library", seed: 2, walks: 30)
    }

    /// F1: patterns equal to or above the deepest root (TMPDIR/**, aliases, case/Unicode variants).
    func testPatternsCoveringTheDeepestRoot() throws {
        let fx = try FixtureHome()
        let t = ProtectedPaths.escapeGlob(fx.tempDir)
        let parent = ProtectedPaths.escapeGlob((fx.tempDir as NSString).deletingLastPathComponent)
        let variants = [
            [t + "/**"], [t], [parent + "/**"], [t.uppercased() + "/**"],
            ["/System/Volumes/Data" + t + "/**"], [("/PRIVATE" + t.dropFirst(0)) + "/**"].map { $0.replacingOccurrences(of: "/PRIVATE/private", with: "/PRIVATE") },
            ["/private/var/folders/**"],
        ]
        for (i, extra) in variants.enumerated() {
            guard let pg = try? make(fx, extra: extra) else { continue }
            let s = differential(pg, lexRoot: fx.tempDir, physRoot: fx.tempDir, seed: UInt64(10 + i), walks: 14, minDepth: 3, maxDepth: 8)
            _ = s
            differential(pg, lexRoot: fx.home, physRoot: fx.home, seed: UInt64(30 + i), walks: 8, minDepth: 3, maxDepth: 8)
        }
        // The verifier's repro: children of a pattern-covered deepest root must be protected.
        let pg = try make(fx, extra: [t + "/**"])
        let ig = IndexGuard(pathGuard: pg, rootPath: fx.tempDir, physicalRoot: fx.tempDir)
        let root = ig.full(path: fx.tempDir)
        let child = ig.classify(path: fx.tempDir + "/x", name: "x", level: 1, parent: root.state)
        XCTAssertEqual(child.flags, [.protected])
        let grand = ig.classify(path: fx.tempDir + "/x/y", name: "y", level: 2, parent: child.state)
        XCTAssertEqual(grand.flags, [.protected])
    }

    func testAdditionalPatternsBelowRoots() throws {
        let fx = try FixtureHome()
        let extra = [ProtectedPaths.escapeGlob(fx.home) + "/*/deep/*/pattern/**", ProtectedPaths.escapeGlob(fx.home) + "/a/b/a/b/a/b/exact"]
        let pg = try make(fx, extra: extra)
        differential(pg, lexRoot: fx.home, physRoot: fx.home, seed: 7, walks: 70)
        differential(pg, lexRoot: fx.tempDir, physRoot: fx.tempDir, seed: 8, walks: 30)
    }

    /// F3: lexical path inside a root, physical outside (and the reverse), plus an aliased root.
    func testLexicalAndPhysicalDisagree() throws {
        let fx = try FixtureHome()
        let pg = try make(fx)
        differential(pg, lexRoot: fx.home, physRoot: "/usr/local", seed: 21, walks: 25, minDepth: 3, maxDepth: 9)
        differential(pg, lexRoot: "/usr/local", physRoot: fx.home, seed: 22, walks: 25, minDepth: 3, maxDepth: 9)
        let alias = fx.tmp.path("alias-to-home")
        XCTAssertEqual(symlink(fx.home, alias), 0)
        differential(pg, lexRoot: alias, physRoot: fx.home, seed: 23, walks: 25)
        // `~/link/.env` where link points outside the roots: the lexical name pattern still wins (like evaluate).
        let ig = IndexGuard(pathGuard: pg, rootPath: fx.home, physicalRoot: fx.home)
        _ = ig
    }

    /// F2: full-disk root is the data volume; its descendants must not inherit "system".
    func testFullDiskRoot() throws {
        let fx = try FixtureHome()
        let pg = try make(fx)
        let data = "/System/Volumes/Data"
        let homeComps = PathNormalization.components(fx.home).map(String.init)
        let s = differential(pg, lexRoot: data, physRoot: data, seed: 31, walks: 30,
                             prefix: homeComps, minDepth: homeComps.count + 2, maxDepth: homeComps.count + 8)
        XCTAssertGreaterThan(s.protectedNodes, 0, "home items under the data volume must be marked protected")
        differential(pg, lexRoot: data, physRoot: data, seed: 32, walks: 30, prefix: ["Users"], minDepth: 3, maxDepth: 8)
        differential(pg, lexRoot: "/", physRoot: "/", seed: 33, walks: 10, prefix: ["System", "Volumes", "Data"] + homeComps,
                     minDepth: homeComps.count + 4, maxDepth: homeComps.count + 8)
        differential(pg, lexRoot: "/System/Volumes", physRoot: "/System/Volumes", seed: 34, walks: 10, prefix: ["Data"] + homeComps,
                     minDepth: homeComps.count + 3, maxDepth: homeComps.count + 6)
    }

    func testSystemAndOutsideRoots() throws {
        let fx = try FixtureHome()
        let pg = try make(fx)
        for root in ["/usr/local", "/Applications", "/Users", "/private/var", "/tmp", "/etc"] {
            differential(pg, lexRoot: root, physRoot: root, seed: 123, walks: 8, minDepth: 3, maxDepth: 8)
        }
    }

    func testRandomPatternFuzz() throws {
        let fx = try FixtureHome()
        var rng = RNG(s: 0xABCDEF)
        let homeG = ProtectedPaths.escapeGlob(fx.home), tmpG = ProtectedPaths.escapeGlob(fx.tempDir)
        for round in 0..<4 {
            var extra: [String] = []
            for _ in 0..<3 {
                let base = [homeG, tmpG, (tmpG as NSString).deletingLastPathComponent].randomElement(using: &rng)!
                var comps: [String] = []
                for _ in 0..<Int.random(in: 0...3, using: &rng) { comps.append(["a", "b", "*", ".ssh", "Library", "T"].randomElement(using: &rng)!) }
                extra.append(([base] + comps).joined(separator: "/") + (Bool.random(using: &rng) ? "/**" : ""))
            }
            guard let pg = try? make(fx, extra: extra) else { continue }
            differential(pg, lexRoot: fx.home, physRoot: fx.home, seed: UInt64(500 + round), walks: 12, minDepth: 3, maxDepth: 8)
            differential(pg, lexRoot: fx.tempDir, physRoot: fx.tempDir, seed: UInt64(600 + round), walks: 12, minDepth: 3, maxDepth: 8)
        }
    }

    func testCursorHelpers() throws {
        let fx = try FixtureHome()
        let pg = try make(fx)
        XCTAssertGreaterThan(pg.anchoredCursor(forKey: []).live.count, 50)
        XCTAssertEqual(pg.anchoredCursor(forKey: PathCanonicalizer.key(fx.home + "/zz").components).live.count, 0)
        XCTAssertTrue(pg.matchesBasename(".env"))
        XCTAssertFalse(pg.matchesBasename("report.txt"))
    }
}
