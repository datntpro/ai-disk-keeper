import XCTest
@testable import DiskKeeperCore

final class ProjectKeyResolverTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adk-pk-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func dir(_ p: String) throws -> URL {
        let u = root.appendingPathComponent(p)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func resolve(_ u: URL) -> String {
        ProjectKeyResolver(cacheLifetime: 0).repoRoot(for: ProjectRef(rootURL: u)).id
    }
    private func id(_ u: URL) -> String { ProjectRef(rootURL: u).id }

    func testPlainRepoAndNestedSubdir() throws {
        let repo = try dir("repo"); _ = try dir("repo/.git")
        let sub = try dir("repo/src/deep")
        XCTAssertEqual(resolve(repo), id(repo))
        XCTAssertEqual(resolve(sub), id(repo))
    }

    func testLinkedWorktreeMapsToMainRepo() throws {
        let main = try dir("main"); _ = try dir("main/.git/worktrees/wt")
        try "../..\n".write(to: main.appendingPathComponent(".git/worktrees/wt/commondir"), atomically: true, encoding: .utf8)
        let wt = try dir("wt")
        try "gitdir: \(main.path)/.git/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(resolve(wt), id(main))
        XCTAssertEqual(resolve(try dir("wt/sub")), id(main))
    }

    func testWorktreeWithoutCommondirUsesPathShape() throws {
        let main = try dir("m2"); _ = try dir("m2/.git/worktrees/w")
        let wt = try dir("w2")
        try "gitdir: \(main.path)/.git/worktrees/w".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(resolve(wt), id(main))
    }

    func testNoRepoUnchanged() throws {
        let d = try dir("plain/x")
        // The temp dir itself could sit inside a repo on a dev machine only if /tmp had .git; assert same-or-ancestor-free.
        XCTAssertEqual(resolve(d), id(d))
    }

    func testNamePassthrough() {
        let ref = ProjectRef(id: "name:my-proj", displayName: "my-proj")
        XCTAssertEqual(ProjectKeyResolver(cacheLifetime: 0).repoRoot(for: ref).id, "name:my-proj")
    }

    func testMalformedGitFileUnchanged() throws {
        let wt = try dir("bad")
        try "garbage".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(resolve(wt), id(wt))
        let wt2 = try dir("bad2")
        try "gitdir: /nowhere/else".write(to: wt2.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(resolve(wt2), id(wt2))
    }
}
