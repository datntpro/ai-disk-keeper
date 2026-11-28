import XCTest

@testable import DiskKeeperCore

final class PRMatchingTests: XCTestCase {
    func rec(_ n: Int, _ state: String, _ branch: String = "feat", oid: String? = "abc1234", merged: Double? = nil) -> PRRecord {
        PRRecord(number: n, state: state, headRefName: branch, headRefOid: oid, mergedAt: merged.map { Date(timeIntervalSince1970: $0) })
    }

    func testMatching() {
        XCTAssertEqual(PRMatcher.state(branch: "feat", records: []), .none)
        XCTAssertEqual(PRMatcher.state(branch: nil, records: [rec(1, "MERGED")]), .none)
        XCTAssertEqual(PRMatcher.state(branch: "feat", records: [rec(1, "MERGED", "other")]), .none)
        XCTAssertEqual(PRMatcher.state(branch: "feat", records: [rec(1, "MERGED"), rec(2, "OPEN")]), .open(number: 2, url: nil))
        XCTAssertEqual(PRMatcher.state(branch: "feat", records: [rec(1, "MERGED", merged: 1), rec(2, "MERGED", merged: 5)]),
                       .merged(number: 2, headOID: "abc1234", url: nil))
        XCTAssertEqual(PRMatcher.state(branch: "feat", records: [rec(3, "CLOSED")]), .closed(number: 3, url: nil))
        if case .unknown = PRMatcher.state(branch: "feat", records: [rec(1, "MERGED", oid: nil)]) {} else { XCTFail() }
    }

    func testGitHubRemoteParsing() {
        XCTAssertEqual(PRMatcher.githubRepository(fromRemote: "https://github.com/o/n.git"), "o/n")
        XCTAssertEqual(PRMatcher.githubRepository(fromRemote: "git@github.com:o/n.git"), "o/n")
        XCTAssertEqual(PRMatcher.githubRepository(fromRemote: "ssh://git@github.com/o/n"), "o/n")
        XCTAssertEqual(PRMatcher.githubRepository(fromRemote: "https://user:tok@github.com/o/n/"), "o/n")
        XCTAssertNil(PRMatcher.githubRepository(fromRemote: "https://gitlab.com/o/n.git"))
        XCTAssertNil(PRMatcher.githubRepository(fromRemote: "https://github.com.evil.com/o/n"))
        XCTAssertNil(PRMatcher.githubRepository(fromRemote: "https://github.com/o/n/extra"))
        XCTAssertNil(PRMatcher.githubRepository(fromRemote: "/tmp/local/origin.git"))
        XCTAssertNil(PRMatcher.githubRepository(fromRemote: nil))
    }

    func testGhOutputParsing() {
        let json = #"[{"number":5,"state":"MERGED","headRefName":"f","headRefOid":"abc1234","mergedAt":"2026-11-01T10:00:00Z","closedAt":"2026-11-01T10:00:00Z","url":"https://github.com/o/n/pull/5","extra":1}]"#
        let r = GHCLIPRStatusSource.parse(Data(json.utf8))
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.number, 5)
        XCTAssertNotNil(r?.first?.mergedAt)
        XCTAssertNil(GHCLIPRStatusSource.parse(Data("nope".utf8)))
    }

    func testGhSourceNeverRunsForNonGitHubOrMissingBinary() async {
        let src = GHCLIPRStatusSource(home: "/nonexistent-home", candidates: ["/nonexistent/gh"])
        let a = await src.lookup(repository: "/r", remoteURL: "/tmp/x.git")
        guard case .unavailable = a else { return XCTFail() }
        let b = await src.lookup(repository: "/r", remoteURL: "https://github.com/o/n.git")
        guard case .unavailable(let why) = b else { return XCTFail() }
        XCTAssertTrue(why.contains("not installed"))
    }
}
