import XCTest
@testable import DiskKeeperCore

final class ProtectedPathsFSTests: XCTestCase {
    var tmp: TemporaryDirectory!
    var home: String { tmp.path("home") }

    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        try tmp.dir("home/.ssh")
        try tmp.file("home/.ssh/known_hosts", bytes: 4)
        try tmp.dir("home/.cache")
    }

    override func tearDown() { tmp = nil }

    func policy(tmpDir: String? = nil) throws -> ProtectedPaths {
        try ProtectedPaths(homeDirectory: home, temporaryDirectory: tmpDir ?? tmp.path("tmpdir"))
    }

    func testSymlinkIntoSSHIsDenied() throws {
        try tmp.symlink("home/.cache/link", to: home + "/.ssh")
        let p = try policy()
        for s in ["\(home)/.cache/link", "\(home)/.cache/link/known_hosts"] {
            let d = try XCTUnwrap(p.check(s).denial, s)
            XCTAssertTrue(d.viaSymlink, s)
        }
    }

    func testIntermediateSymlinkEscapingHomeIsDenied() throws {
        try tmp.symlink("home/.cache/out", to: "/usr")
        XCTAssertEqual(try policy().check("\(home)/.cache/out/bin").denial?.reason, .systemLocation)
    }

    func testDanglingSymlinkIsUnresolvable() throws {
        try tmp.symlink("home/.cache/dangling", to: "/nonexistent-target-xyz")
        let p = try policy()
        XCTAssertEqual(p.check("\(home)/.cache/dangling").denial?.reason, .unresolvable)
        XCTAssertEqual(p.check("\(home)/.cache/dangling/sub").denial?.reason, .unresolvable)
    }

    func testNonexistentPathUnderRealDirResolves() throws {
        XCTAssertTrue(try policy().check("\(home)/.cache/new/deeper").isAllowed)
    }

    func testPathUnderRegularFileResolves() throws {
        try tmp.file("home/.cache/f", bytes: 1)
        XCTAssertTrue(try policy().check("\(home)/.cache/f/child").isAllowed)
    }

    func testPrivateAliasOfTempRootWorks() throws {
        let base = FileManager.default.temporaryDirectory.path   // /var/folders/... spelling
        let p = try policy(tmpDir: base)
        XCTAssertTrue(tmp.url.path.hasPrefix("/private/"))
        XCTAssertTrue(p.check(tmp.path("scratch/x")).isAllowed)
    }

    func testGuardPerformsNoWrites() throws {
        try tmp.symlink("home/.cache/link", to: home + "/.ssh")
        let p = try policy()
        func snapshot() -> [String] {
            var out: [String] = []
            let e = FileManager.default.enumerator(atPath: tmp.url.path)
            while let rel = e?.nextObject() as? String {
                let a = try? FileManager.default.attributesOfItem(atPath: tmp.path(rel))
                out.append("\(rel)|\(a?[.size] ?? "")|\(a?[.modificationDate] ?? "")")
            }
            return out.sorted()
        }
        let before = snapshot()
        for i in 0..<1000 {
            _ = p.check(i % 2 == 0 ? "\(home)/.cache/link/known_hosts" : "\(home)/.cache/n\(i)/x")
        }
        XCTAssertEqual(before, snapshot())
    }

    func testRealResolverRootEqualsResolvedLocalOnly() {
        XCTAssertEqual(SystemPathResolver().resolve("/tmp"), .resolved("/private/tmp"))
        XCTAssertEqual(SystemPathResolver().resolve("/"), .resolved("/"))
        XCTAssertEqual(SystemPathResolver().resolve("/nonexistent-xyz/a"), .resolved("/nonexistent-xyz/a"))
    }

    func testResolverReportsLoopAsFailure() throws {
        try tmp.symlink("loopa", to: tmp.path("loopb"))
        try tmp.symlink("loopb", to: tmp.path("loopa"))
        XCTAssertEqual(SystemPathResolver().resolve(tmp.path("loopa")), .failed(errno: ELOOP))
    }

    func testSymlinkToExistingDirWithMissingChildResolvesThrough() throws {
        try tmp.dir("home/.cache/real")
        try tmp.symlink("home/.cache/mem", to: home + "/.cache/real")
        let r = SystemPathResolver().resolve("\(home)/.cache/mem/new/deeper")
        XCTAssertEqual(r, .resolved(tmp.path("home/.cache/real/new/deeper")))
        XCTAssertTrue(try policy().check("\(home)/.cache/mem/new").isAllowed)
        try tmp.symlink("home/.cache/tossh", to: home + "/.ssh")
        XCTAssertEqual(try policy().check("\(home)/.cache/tossh/newkey").denial?.reason, .protectedPath)
    }

    func testRealFilesNamedWithCombiningMarkInsideProtectedFoldersAreDenied() throws {
        let m = "\u{301}"
        try tmp.file("home/.ssh/\(m)", bytes: 1)
        try tmp.file("home/proj/.git/\(m)", bytes: 1)
        try tmp.file("home/Library/Keychains/\(m)", bytes: 1)
        try tmp.file("home/.claude/projects/-a/memory/\(m)", bytes: 1)
        try tmp.file("home/proj/id_rsa\(m)", bytes: 1)
        try tmp.file("home/.claude.json\(m)", bytes: 1)
        try tmp.file("home/.claude/settings\(m).json", bytes: 1)
        try tmp.file("home/proj/.env.\(m)", bytes: 1)
        let p = try policy()
        for rel in [".ssh/\(m)", "proj/.git/\(m)", "Library/Keychains/\(m)", ".claude/projects/-a/memory/\(m)",
                    "proj/id_rsa\(m)", ".claude.json\(m)", ".claude/settings\(m).json", "proj/.env.\(m)"] {
            XCTAssertFalse(p.check("\(home)/\(rel)").isAllowed, rel)
        }
        XCTAssertFalse(p.check("\(home)/.ssh/\(m)/x").isAllowed)
    }
}
