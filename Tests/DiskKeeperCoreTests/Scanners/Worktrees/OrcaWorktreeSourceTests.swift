import XCTest

@testable import DiskKeeperCore

final class OrcaWorktreeSourceTests: XCTestCase {
    /// Recorded shape of `orca worktree list --json` (anonymized, trimmed).
    static let fixture = """
    {"id":"x","ok":true,"result":{"worktrees":[
     {"id":"r1::/Users/me","instanceId":"i-main","repoId":"r1","path":"/Users/me/proj","head":"","branch":"","isBare":false,
      "isMainWorktree":true,"displayName":"proj","linkedPR":null,"lastActivityAt":1795532504120,"workspaceStatus":"in-progress",
      "git":{"path":"/Users/me/proj"},"someFutureKey":{"a":1}},
     {"id":"r1::/Users/me/orca/workspaces/proj/wt","instanceId":"i-wt","repoId":"r1","path":"/Users/me/orca/workspaces/proj/wt",
      "head":"38e260f97942cb9aa98351ef596a59cb548cf49b","branch":"refs/heads/feat/x","isBare":false,"isMainWorktree":false,
      "displayName":"Feature X","linkedPR":{"number":12,"state":"open"},"lastActivityAt":1795669942885,"workspaceStatus":"done"},
     {"path":"relative/ignored"}
    ],"hostScope":"local","totalCount":2,"truncated":false},"_meta":{}}
    """

    func testParsesEnvelope() {
        let r = OrcaWorktreeSource.parse(Data(Self.fixture.utf8))
        XCTAssertNil(r.warning)
        XCTAssertEqual(r.rows.count, 2)
        XCTAssertTrue(r.rows[0].isMain)
        XCTAssertNil(r.rows[0].branch)
        XCTAssertEqual(r.rows[1].branch, "feat/x")
        XCTAssertEqual(r.rows[1].linkedPR, 12)
        XCTAssertEqual(r.rows[1].instanceID, "i-wt")
        XCTAssertEqual(r.rows[1].lastActivityAt, Date(timeIntervalSince1970: 1_795_669_942.885))
        XCTAssertEqual(r.rows[1].workspaceStatus, "done")
    }

    func testBadJSONIsAWarning() {
        XCTAssertNotNil(OrcaWorktreeSource.parse(Data("not json".utf8)).warning)
        XCTAssertNotNil(OrcaWorktreeSource.parse(Data(#"{"ok":false}"#.utf8)).warning)
        XCTAssertNotNil(OrcaWorktreeSource.parse(Data(#"{"ok":true,"result":{}}"#.utf8)).warning)
    }

    func testMissingBinaryIsSkipped() async {
        let src = OrcaWorktreeSource(home: "/nonexistent-home", candidates: ["/nonexistent/orca"])
        let r = await src.list()
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertNotNil(r.warning)
    }

    func testRunsAFakeBinaryWithMinimalEnvAndOnlyListArgs() async throws {
        let tmp = try TemporaryDirectory()
        let script = try tmp.file("orca", contents: Data("""
        #!/bin/sh
        [ "$1 $2 $3" = "worktree list --json" ] && [ $# -eq 3 ] || exit 3
        echo '\(Self.fixture.replacingOccurrences(of: "\n", with: ""))'
        """.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let src = OrcaWorktreeSource(home: tmp.url.path, candidates: [script.path])
        let r = await src.list()
        XCTAssertNil(r.warning)
        XCTAssertEqual(r.rows.count, 2)
    }
}
