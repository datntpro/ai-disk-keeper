import XCTest
@testable import DiskKeeperCore

final class ProtectedPathsTests: XCTestCase {
    let home = "/Users/tester"
    let tmp = "/var/folders/zz/T/"

    func policy(_ fake: FakePathResolver = FakePathResolver(), extra: [String] = []) throws -> ProtectedPaths {
        try ProtectedPaths(homeDirectory: home, temporaryDirectory: tmp, additionalPatterns: extra, resolver: fake)
    }

    func reason(_ p: ProtectedPaths, _ path: String) -> PathDenial.Reason? { p.check(path).denial?.reason }

    private func expand(_ t: String) -> String {
        t.replacingOccurrences(of: "$APP_SUPPORT", with: home + "/Library/Application Support")
            .replacingOccurrences(of: "~", with: home)
    }

    private func sample(_ t: String) -> String {
        var out = ""
        var chars = Array(expand(t))[...]
        while let c = chars.popFirst() {
            switch c {
            case "*", "?": out.append("x")
            case "[":
                out.append(chars.first ?? "x")
                while let n = chars.popFirst(), n != "]" {}
            default: out.append(c)
            }
        }
        return out
    }

    func testEveryBuiltInAnchoredPatternIsDenied() throws {
        let p = try policy()
        for pat in ProtectedPaths.builtInAnchored {
            let s = sample(pat.template)
            XCTAssertEqual(reason(p, s), .protectedPath, pat.template)
            XCTAssertEqual(reason(p, s + "/child"), .protectedPath, pat.template)
        }
    }

    func testEveryBuiltInBasenameIsDeniedBelowRoot() throws {
        let p = try policy()
        for pat in ProtectedPaths.builtInBasenames {
            let s = sample(pat.template)
            XCTAssertEqual(reason(p, "\(home)/proj/\(s)"), .protectedName, pat.template)
            XCTAssertEqual(reason(p, "\(home)/proj/\(s)/x"), .protectedName, pat.template)
        }
        XCTAssertNil(reason(p, "\(home)/proj/id_utils"))
        XCTAssertNil(reason(p, "\(home)/proj/.envrc"))
        XCTAssertNil(reason(p, "\(home)/proj/wt"), "dir that merely contains .git is fine")
    }

    func testEveryExactOnlyEntryIsDeniedButChildrenAllowed() throws {
        let p = try policy()
        for e in ProtectedPaths.builtInExactOnly {
            let s = e.hasPrefix("~") ? expand(e) : e
            XCTAssertEqual(reason(p, s), .protectedLocation, e)
        }
        XCTAssertNil(reason(p, "\(home)/Documents/repo/node_modules"))
        XCTAssertNil(reason(p, "\(home)/Library/Caches/com.todesktop.x"))
    }

    func testAncestorOfProtectedIsDenied() throws {
        let p = try policy()
        XCTAssertEqual(reason(p, "\(home)/.claude"), .containsProtectedPath)
        XCTAssertEqual(reason(p, "\(home)/.claude/projects/-Users-tester-app"), .containsProtectedPath)
        XCTAssertNil(reason(p, "\(home)/.claude/projects/-Users-tester-app/abc.jsonl"))
        XCTAssertNil(reason(p, "\(home)/.claude/todos"))
        XCTAssertEqual(reason(p, "\(home)/.cursor"), .containsProtectedPath)
        XCTAssertNil(reason(p, "\(home)/Library/Caches/com.todesktop.x"))
    }

    func testSystemRootsAndSlash() throws {
        let p = try policy()
        for s in ["/", "/System", "/System/Library/x", "/Applications/Foo.app", "/etc/hosts", "/Library/Caches"] {
            XCTAssertEqual(reason(p, s), .systemLocation, s)
        }
    }

    func testOutsideAllowedRoots() throws {
        let p = try policy()
        for s in ["/Users/other/x", "/private/var/log/x", "/opt2/x", "/Users/testerX/a", "/Users"] {
            XCTAssertEqual(reason(p, s), .outsideAllowedRoots, s)
        }
    }

    func testAllowedRootsThemselvesDenied() throws {
        let p = try policy()
        for s in [home, "/var/folders/zz/T", "/private/var/folders/zz/T/", "/private/tmp"] {
            XCTAssertEqual(reason(p, s), .protectedLocation, s)
        }
    }

    func testAllowedExamples() throws {
        let p = try policy()
        for s in ["\(home)/.claude/todos/x.json", "/var/folders/zz/T/claude-123", "/tmp/claude-501/x",
                  "\(home)/orca/workspaces/repo/wt1"] {
            XCTAssertTrue(p.check(s).isAllowed, s)
        }
    }

    func testCaseInsensitiveMatch() throws {
        let p = try policy()
        for s in ["\(home)/.SSH/known_hosts", "\(home)/.Claude/Settings.json", "/USERS/TESTER/.aws"] {
            XCTAssertFalse(p.check(s).isAllowed, s)
        }
    }

    func testUnicodeNormalizationMatch() throws {
        let p = try policy(extra: ["/Users/tester/Caf\u{E9}"])
        XCTAssertEqual(reason(p, "/Users/tester/Cafe\u{301}/x"), .protectedPath)
    }

    func testFirmlinkFormIsCheckedLikeUserForm() throws {
        let p = try policy()
        XCTAssertEqual(reason(p, "/System/Volumes/Data/Users/tester/.ssh"), .protectedPath)
        XCTAssertTrue(p.check("/System/Volumes/Data/Users/tester/.cache/x").isAllowed)
    }

    func testParentTraversalRejected() throws {
        let p = try policy()
        XCTAssertEqual(reason(p, "\(home)/.cache/../.ssh"), .parentTraversal)
        XCTAssertEqual(reason(p, "\(home)/a/.."), .parentTraversal)
    }

    func testInvalidInputs() throws {
        let p = try policy()
        for s in ["", "relative/x", "~/x", "/a\0b"] { XCTAssertEqual(reason(p, s), .invalidPath, s) }
        XCTAssertEqual(p.check(URL(string: "https://x")!).denial?.reason, .invalidPath)
        XCTAssertTrue(p.check(URL(fileURLWithPath: "\(home)/.cache/x")).isAllowed)
    }

    func testResolvedFormDeniedViaSymlink() throws {
        var f = FakePathResolver()
        f.map["\(home)/.cache/link"] = .resolved("\(home)/.ssh")
        let d = try XCTUnwrap(policy(f).check("\(home)/.cache/link").denial)
        XCTAssertEqual(d.reason, .protectedPath)
        XCTAssertTrue(d.viaSymlink)
        XCTAssertEqual(d.resolvedPath, "\(home)/.ssh")
        XCTAssertTrue(d.message.contains("resolves to"))
    }

    func testResolvedOutsideHomeDenied() throws {
        var f = FakePathResolver()
        f.map["\(home)/.cache/out"] = .resolved("/System/Library")
        let d = try XCTUnwrap(policy(f).check("\(home)/.cache/out").denial)
        XCTAssertEqual(d.reason, .systemLocation)
        XCTAssertTrue(d.viaSymlink)
    }

    func testUnresolvableDenied() throws {
        var f = FakePathResolver()
        f.map["\(home)/.cache/x"] = .failed(errno: EACCES)
        XCTAssertEqual(reason(try policy(f), "\(home)/.cache/x"), .unresolvable)
    }

    func testLexicalDenialWinsOverResolution() throws {
        var f = FakePathResolver()
        f.map["\(home)/.ssh"] = .failed(errno: EACCES)
        let d = try XCTUnwrap(policy(f).check("\(home)/.ssh").denial)
        XCTAssertEqual(d.reason, .protectedPath)
        XCTAssertFalse(d.viaSymlink)
    }

    func testAdditionalPatternsAreAddedNeverSubtracted() throws {
        let p = try policy(extra: ["/Users/tester/.orca/auth.json", "/Users/tester/.tool/**"])
        XCTAssertEqual(reason(p, "\(home)/.orca/auth.json"), .protectedPath)
        XCTAssertEqual(reason(p, "\(home)/.ssh"), .protectedPath)
        XCTAssertEqual(reason(p, "\(home)/.tool"), .protectedPath)
        XCTAssertEqual(reason(p, "\(home)/.tool/a"), .protectedPath)
    }

    func testInvalidAdditionalPatternsThrow() {
        for pat in ["relative", "~/x", "/a/../b", "/a/**/b", "/**", "/a\0"] {
            XCTAssertThrowsError(try policy(extra: [pat]), pat) { err in
                guard case .invalidPattern = err as? ProtectedPathsError else { return XCTFail("\(err)") }
            }
        }
    }

    func testInvalidRootsThrow() {
        for r in ["", "rel", "/", "/a/../b", "/a\0"] {
            XCTAssertThrowsError(try ProtectedPaths(homeDirectory: r, temporaryDirectory: tmp)) {
                XCTAssertEqual($0 as? ProtectedPathsError, .invalidRoot(r))
            }
            XCTAssertThrowsError(try ProtectedPaths(homeDirectory: home, temporaryDirectory: r)) {
                XCTAssertEqual($0 as? ProtectedPathsError, .invalidRoot(r))
            }
        }
    }

    func testHomeUnderSymlinkResolvedRootAlsoAllowed() throws {
        var f = FakePathResolver()
        f.map[home] = .resolved("/Volumes/Data/tester")
        f.fallback = { p in
            p.hasPrefix(self.home + "/") ? .resolved("/Volumes/Data/tester" + p.dropFirst(self.home.count)) : .resolved(p)
        }
        let p = try policy(f)
        XCTAssertTrue(p.check("\(home)/.cache/x").isAllowed)
        XCTAssertEqual(reason(p, "\(home)/.ssh"), .protectedPath)
        XCTAssertEqual(reason(p, "/Volumes/Data/tester/.ssh"), .protectedPath)
        XCTAssertEqual(reason(p, "/Volumes/Other"), .systemLocation)
    }

    func testHardReasonBeatsContainerReason() throws {
        var f = FakePathResolver()
        f.map["\(home)/Developer"] = .resolved("\(home)/.ssh")
        let d = try XCTUnwrap(policy(f).check("\(home)/Developer").denial)
        XCTAssertEqual(d.reason, .protectedPath)
        XCTAssertTrue(d.viaSymlink)
        XCTAssertEqual(reason(try policy(), "\(home)/.claude"), .containsProtectedPath)
        var g = FakePathResolver()
        g.map["\(home)/Developer"] = .failed(errno: EACCES)
        XCTAssertEqual(reason(try policy(g), "\(home)/Developer"), .unresolvable)
    }

    func testContainerViaSymlinkOnly() throws {
        var f = FakePathResolver()
        f.map["\(home)/.cache/l"] = .resolved("\(home)/Documents")
        let d = try XCTUnwrap(policy(f).check("\(home)/.cache/l").denial)
        XCTAssertEqual(d.reason, .protectedLocation)
        XCTAssertTrue(d.viaSymlink)
    }

    func testMessagesAreHumanReadable() throws {
        let p = try policy()
        let d = try XCTUnwrap(p.check("\(home)/.ssh/id_rsa").denial)
        XCTAssertTrue(d.message.contains("~/.ssh"))
        XCTAssertTrue(d.message.contains("credentials"))
        XCTAssertEqual(d.description, d.message)
        XCTAssertTrue(try XCTUnwrap(p.check("\(home)/Documents").denial).message.contains("~/Documents"))
    }

    func testDenialReasonCasesAllReachable() throws {
        var f = FakePathResolver()
        f.map["\(home)/.cache/bad"] = .failed(errno: EACCES)
        let p = try policy(f)
        let table: [(PathDenial.Reason, String)] = [
            (.invalidPath, "x"), (.parentTraversal, "\(home)/a/../b"), (.unresolvable, "\(home)/.cache/bad"),
            (.systemLocation, "/System"), (.outsideAllowedRoots, "/Users/other"),
            (.protectedLocation, "\(home)/Documents"), (.protectedPath, "\(home)/.ssh"),
            (.containsProtectedPath, "\(home)/.claude"), (.protectedName, "\(home)/proj/.env"),
        ]
        XCTAssertEqual(Set(table.map(\.0)), Set(PathDenial.Reason.allCases))
        for (r, s) in table {
            let d = try XCTUnwrap(p.check(s).denial, s)
            XCTAssertEqual(d.reason, r, s)
            XCTAssertFalse(d.message.isEmpty)
        }
    }
}
