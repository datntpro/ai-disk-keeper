import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// One test per row of docs/protected-paths.md § "Application-bundle exception" (names carry the row number).
final class ApplicationBundlePolicyTests: AppBundleTestCase {
    func testRow01_systemRootHappyPath() throws {
        try makeApp("tmp/Applications/Foo.app")
        let r = try evaluate("tmp/Applications/Foo.app")
        XCTAssertEqual(r.blockers, [])
        XCTAssertEqual(r.fingerprint?.bundleID, "com.example.foo")
    }

    func testRow02_userRootHappyPath() throws {
        try makeApp("home/Applications/Foo.app")
        XCTAssertEqual(try evaluate("home/Applications/Foo.app").blockers, [])
    }

    func testRow03_utilitiesIsNotTopLevel() throws {
        try makeApp("tmp/Applications/Utilities/Foo.app")
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Utilities/Foo.app").blockers), [.notTopLevel])
    }

    func testRow04_vendorFolderIsNotTopLevel() throws {
        try makeApp("tmp/Applications/Vendor/Foo.app")
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Vendor/Foo.app").blockers), [.notTopLevel])
    }

    func testRow05_insideBundle() throws {
        try makeApp("tmp/Applications/Foo.app")
        try makeApp("tmp/Applications/Foo.app/Contents/Helpers/Bar.app")
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app/Contents/Helpers/Bar.app").blockers), [.insideBundle])
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app/Contents").blockers), [.insideBundle])
        // A nested .app one level down reports insideBundle, not notTopLevel.
        XCTAssertEqual(policy.lexicalRefusal(fx.path("tmp/Applications/X.app/Contents/Y.app")), .insideBundle)
    }

    func testRow06_symlinkedBundle() throws {
        let target = try makeApp("elsewhere/Safari.app", id: "com.example.foo")
        try FileManager.default.createSymbolicLink(atPath: fx.path("tmp/Applications/Foo.app"), withDestinationPath: target)
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app").blockers), [.symlink])
    }

    func testRow07_symlinkedParentAndRealpathDifference() throws {
        try makeApp("real/Foo.app")
        // The system root replaced by a link to another directory.
        try FileManager.default.removeItem(atPath: fx.path("tmp/Applications"))
        try FileManager.default.createSymbolicLink(atPath: fx.path("tmp/Applications"), withDestinationPath: fx.path("real"))
        let r = try evaluate("tmp/Applications/Foo.app")
        XCTAssertTrue(refusals(r.blockers).contains(.resolvedElsewhere))
        XCTAssertTrue(r.blockers.contains { if case .symlinkInParentChain = $0 { true } else { false } })
    }

    func testRow07_realpathDiffersFromLexical() throws {
        try makeApp("tmp/Applications/Foo.app")
        let p = DifferingRealpathProbe(inner: probe)
        let pol = ApplicationBundlePolicy(roots: roots, userID: getuid(), probe: p)
        let r = pol.evaluate(appItem("tmp/Applications/Foo.app"), action: .trash, expected: nil,
                             pathGuard: try makeGuard(), runningApps: running)
        XCTAssertEqual(refusals(r.blockers), [.resolvedElsewhere])
    }

    func testRow08_appleSignature() throws {
        try makeApp("tmp/Applications/Foo.app")
        probe.signature = .apple
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app").blockers), [.appleOrSystem])
    }

    func testRow08_sealedVolumeTrueAndUnknown() throws {
        try makeApp("tmp/Applications/Foo.app")
        probe.sealed = true
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app").blockers), [.appleOrSystem])
        probe.sealed = nil
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app").blockers), [.appleOrSystem])
    }

    func testRow08_systemApplicationsPathIsRefused() throws {
        let pol = ApplicationBundlePolicy(roots: ApplicationRoots(roots: ["/Applications", fx.path("home/Applications")]),
                                          userID: getuid(), probe: probe)
        XCTAssertEqual(pol.lexicalRefusal("/System/Applications/Foo.app"), .notTopLevel)
    }

    func testRow08_unknownSignatureFailsClosed() throws {
        try makeApp("tmp/Applications/Foo.app")
        probe.signature = .unknown("boom")
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app").blockers), [.signatureUnreadable])
    }

    func testRow09_ownerIsNotUser() throws {
        try makeApp("tmp/Applications/Foo.app")
        probe.setOwner(0, for: fx.path("tmp/Applications/Foo.app"))
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app").blockers, [.requiresAdmin(bundleID: "com.example.foo")])
    }

    func testRow10_runningByIDUnknownAndHelperInside() throws {
        try makeApp("tmp/Applications/Foo.app")
        running.byID = true
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app").blockers, [.appRunning(bundleID: "com.example.foo")])
        running.byID = nil
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app").blockers, [.appStateUnknown(bundleID: "com.example.foo")])
        running.byID = false
        running.inside = true
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app").blockers, [.appRunning(bundleID: "com.example.foo")])
        running.inside = nil
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app").blockers, [.appStateUnknown(bundleID: "com.example.foo")])
    }

    func testRow11_nameAndInfoPlist() throws {
        try makeApp("tmp/Applications/Foo.App")
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.App").blockers, [], "case variant is accepted")
        for bad in ["tmp/Applications/Foo.apps", "tmp/Applications/Foo", "tmp/Applications/.app"] {
            try makeApp(bad)
            XCTAssertEqual(refusals(try evaluate(bad).blockers), [.notAnAppBundle], bad)
        }
        try makeApp("tmp/Applications/NoPlist.app", plist: false)
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/NoPlist.app").blockers), [.missingInfoPlist])
        // A regular file named *.app is not a bundle.
        try fx.file("tmp/Applications/File.app", bytes: 10)
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/File.app").blockers), [.notAnAppBundle])
    }

    func testRow11_infoPlistSymlinkOrTooLarge() throws {
        try makeApp("tmp/Applications/Link.app", plist: false)
        try fx.file("plist-target", contents: try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.foo"], format: .xml, options: 0))
        try FileManager.default.createSymbolicLink(atPath: fx.path("tmp/Applications/Link.app/Contents/Info.plist"),
                                                   withDestinationPath: fx.path("plist-target"))
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Link.app").blockers), [.missingInfoPlist])

        try makeApp("tmp/Applications/Big.app", plist: false)
        var big = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.foo"],
                                                     format: .xml, options: 0)
        big.append(Data(repeating: 0x20, count: LiveAppBundleProbe.maxInfoPlistBytes + 1))
        try big.write(to: URL(fileURLWithPath: fx.path("tmp/Applications/Big.app/Contents/Info.plist")))
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Big.app").blockers), [.missingInfoPlist])
    }

    func testRow12_bundleIDMismatch() throws {
        try makeApp("tmp/Applications/Foo.app", id: "com.other.app")
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app").blockers), [.bundleIDMismatch])
        // Exact, case-sensitive.
        try makeApp("tmp/Applications/Bar.app", id: "com.Example.Foo")
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Bar.app").blockers), [.bundleIDMismatch])
    }

    func testRow12_fingerprintChangeIsIdentityChanged() throws {
        try makeApp("tmp/Applications/Foo.app")
        let fp = try XCTUnwrap(try evaluate("tmp/Applications/Foo.app").fingerprint)
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app", expected: fp).blockers, [])
        try FileManager.default.removeItem(atPath: fx.path("tmp/Applications/Foo.app"))
        try makeApp("tmp/Applications/Foo.app")
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app", expected: fp).blockers, [.identityChanged])
    }

    func testRow13_permanentDeleteIsRefusedEvenWhenAllowed() throws {
        try makeApp("tmp/Applications/Foo.app")
        XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app", action: .deletePermanently).blockers), [.permanentDelete])
    }

    func testRow14_rootItself() throws {
        for rel in ["tmp/Applications", "home/Applications"] {
            XCTAssertEqual(refusals(try evaluate(rel).blockers), [.rootItself], rel)
        }
    }

    func testRow00_notApplicationMethod() throws {
        let item = try { () -> ScanItem in
            let i = appItem("tmp/Applications/Foo.app")
            return ScanItem(url: i.url, displayName: i.displayName, tool: .apps, category: .application,
                            sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review,
                            explanation: "x", ruleID: "r", cleanupMethod: .trash)
        }()
        let r = policy.evaluate(item, action: .trash, expected: nil, pathGuard: try makeGuard(), runningApps: running)
        XCTAssertEqual(refusals(r.blockers), [.notApplicationMethod])
    }

    func testInvalidPaths() throws {
        let p = policy
        for bad in ["", "tmp/Applications/Foo.app", "/Applications/Foo.app/", "/Applications//Foo.app",
                    "/Applications/../Applications/Foo.app", "/Applications/./Foo.app", "/Applications/Foo\u{0}.app", "/"] {
            XCTAssertEqual(p.lexicalRefusal(bad), .invalidPath, bad)
        }
    }

    func testMissingBundle() throws {
        XCTAssertEqual(try evaluate("tmp/Applications/Ghost.app").blockers, [.missing])
    }

    func testPolicyWorksWithoutTouchingSignatureWhenLexicallyRefused() throws {
        try makeApp("tmp/Applications/Utilities/Foo.app")
        _ = try evaluate("tmp/Applications/Utilities/Foo.app")
        XCTAssertEqual(probe.signatureCalls, 0)
    }

    func testGuardIsConsultedAndOtherReasonsAreNeverWaived() throws {
        // A fixture guard that denies by name: protectedPath, not waived.
        let g = try ProtectedPaths(homeDirectory: home, temporaryDirectory: fx.path("tmp"),
                                   additionalPatterns: [ProtectedPaths.escapeGlob(fx.path("home/Applications/Foo.app"))])
        try makeApp("home/Applications/Foo.app")
        let r = policy.evaluate(appItem("home/Applications/Foo.app"), action: .trash, expected: nil,
                                pathGuard: g, runningApps: running)
        XCTAssertTrue(r.blockers.contains { if case .protectedPath = $0 { true } else { false } }, "\(r.blockers)")
    }

    // MARK: waives truth table (pure; strings only)

    func testWaivesTruthTable() {
        let r = ApplicationRoots(roots: ["/Applications", "/Users/x/Applications"])
        func d(_ reason: PathDenial.Reason, _ p: String) -> PathDenial { PathDenial(path: p, reason: reason) }
        XCTAssertTrue(ApplicationBundlePolicy.waives(d(.systemLocation, "/Applications/Foo.app"),
                                                     path: "/Applications/Foo.app", roots: r))
        for p in ["/Applications/Utilities/Foo.app", "/Applications", "/Library/Foo.app", "/System/Applications/Foo.app",
                  "/usr/local/Foo.app", "/Applications/Foo.app/Contents", "/Volumes/X/Applications/Foo.app",
                  "/Users/x/Applications/Foo.app"] {
            XCTAssertFalse(ApplicationBundlePolicy.waives(d(.systemLocation, p), path: p, roots: r), p)
        }
        for reason in PathDenial.Reason.allCases where reason != .systemLocation {
            XCTAssertFalse(ApplicationBundlePolicy.waives(d(reason, "/Applications/Foo.app"),
                                                          path: "/Applications/Foo.app", roots: r), reason.rawValue)
        }
    }
}

struct DifferingRealpathProbe: AppBundleProbing {
    let inner: FakeAppBundleProbe
    func lstat(_ path: String) -> FileStat? { inner.lstat(path) }
    func realpath(_ path: String) -> String? { path + "-renamed" }
    func readInfoPlist(bundle: String) -> InfoPlistRead { inner.readInfoPlist(bundle: bundle) }
    func isOnSealedSystemVolume(_ path: String) -> Bool? { inner.isOnSealedSystemVolume(path) }
    func signatureSource(_ path: String) -> AppSource { inner.signatureSource(path) }
}

/// The guard exception must not weaken `ProtectedPaths` for any other caller.
final class AppBundleGuardRegressionTests: AppBundleTestCase {
    func testRealApplicationsPathIsSystemLocationAndWaivable() throws {
        let g = try makeGuard()
        let denial = try XCTUnwrap(g.check("/Applications/Foo.app").denial)
        XCTAssertEqual(denial.reason, .systemLocation)
        let live = ApplicationRoots.live(PathEnvironment(home: home, temporaryDirectory: fx.path("tmp")))
        XCTAssertTrue(ApplicationBundlePolicy.waives(denial, path: "/Applications/Foo.app", roots: live))
    }

    func testOtherMethodsStillBlockedOutsideHome() async throws {
        let engine = try engine()
        for path in ["/Applications/Foo.app", "/Library/X", "/usr/local/X", "/System/X"] {
            for method in [CleanupMethod.trash, .none] {
                let item = ScanItem(url: URL(fileURLWithPath: path), displayName: "x", tool: .apps, category: .application,
                                    sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .safe,
                                    explanation: "x", ruleID: "r", cleanupMethod: method)
                let plan = await engine.plan([item])
                let codes = plan.entries[0].blockers.map(\.code)
                if method == .trash {
                    XCTAssertTrue(codes.contains("protectedPath"), "\(path): \(codes)")
                }
                XCTAssertFalse(plan.entries[0].isExecutable)
            }
        }
    }

    func testTrashApplicationOutsideTheTwoRootsIsNotWaived() async throws {
        let engine = try engine()
        for path in ["/Library/Foo.app", "/usr/local/Foo.app", "/Applications/Utilities/Foo.app"] {
            let item = ScanItem(url: URL(fileURLWithPath: path), displayName: "Foo", tool: .apps, category: .application,
                                sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review,
                                explanation: "x", ruleID: "apps.bundle",
                                cleanupMethod: .trashApplication(bundleID: "com.example.foo"))
            let plan = await engine.plan([item])
            XCTAssertFalse(plan.entries[0].isExecutable, path)
        }
    }

    func testFixtureOutsideAllowedRootsIsNotWaived() throws {
        // `<fx>/Applications` is outside the fixture guard's roots: outsideAllowedRoots, never waived.
        try makeApp("Applications/Foo.app")
        let r = policy.evaluate(appItem("Applications/Foo.app"), action: .trash, expected: nil,
                                pathGuard: try makeGuard(), runningApps: running)
        // Not under a configured root either, so it is refused lexically.
        XCTAssertEqual(refusals(r.blockers), [.notTopLevel])
    }
}
