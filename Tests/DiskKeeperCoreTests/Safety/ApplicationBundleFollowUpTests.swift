import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// PR #88 verification follow-ups: F1 (Apple identities), F2 (all-process scan), F3 (protect patterns win).
final class ApplicationBundleFollowUpTests: AppBundleTestCase {
    // MARK: F1 (fixture bundles only; real Apple apps are never touched)

    func testF1_appleTeamIDsAreRefusedForDeveloperIDAndAppStore() throws {
        try makeApp("tmp/Applications/Foo.app")
        for source in [AppSource.developerID(teamID: "59GAB85EFG"), .appStore(teamID: "59GAB85EFG"),
                       .developerID(teamID: "74J34U3R6X"), .appStore(teamID: "74j34u3r6x")] {
            probe.signature = source
            XCTAssertEqual(refusals(try evaluate("tmp/Applications/Foo.app").blockers), [.appleOrSystem], "\(source)")
        }
        probe.signature = .developerID(teamID: "ZZZZZZZZZZ")
        XCTAssertEqual(try evaluate("tmp/Applications/Foo.app").blockers, [])
    }

    func testF1_comAppleBundleIDIsRefusedRegardlessOfSignatureAndOwner() throws {
        for id in ["com.apple.dt.Xcode", "COM.APPLE.Pages", "com.apple.iWork.Keynote"] {
            let rel = "tmp/Applications/\(id).app"
            try makeApp(rel, id: id)
            probe.signature = .developerID(teamID: "ZZZZZZZZZZ")
            let r = try evaluate(rel, id: id)
            XCTAssertEqual(refusals(r.blockers), [.appleOrSystem], id)
        }
        // Plist says com.apple.* while the plan asked for another id: refused for both reasons.
        try makeApp("tmp/Applications/Fake.app", id: "com.apple.fake")
        let r = try evaluate("tmp/Applications/Fake.app", id: "com.example.foo")
        XCTAssertTrue(refusals(r.blockers).contains(.appleOrSystem))
        XCTAssertTrue(refusals(r.blockers).contains(.bundleIDMismatch))
        // Look-alikes are not Apple.
        try makeApp("tmp/Applications/Like.app", id: "com.applesauce.app")
        XCTAssertEqual(try evaluate("tmp/Applications/Like.app", id: "com.applesauce.app").blockers, [])
    }

    func testF1_engineBlocksAppleAppEvenWhenUserOwned() async throws {
        try makeApp("tmp/Applications/Foo.app", id: "com.apple.dt.Xcode")
        probe.signature = .appStore(teamID: "59GAB85EFG")
        let e = try engine()
        let plan = await e.plan([appItem("tmp/Applications/Foo.app", id: "com.apple.dt.Xcode")])
        XCTAssertFalse(plan.entries[0].isExecutable)
        XCTAssertEqual(refusals(plan.entries[0].blockers), [.appleOrSystem])
        XCTAssertTrue(trashRec.calls.isEmpty)
    }

    // MARK: F2 (a live helper process launched from a fixture bundle)

    /// Runs a real process whose image lives inside the fixture bundle. A copied system binary can be killed
    /// on some hosts (CI), so a tiny compiled program is the fallback.
    private func launchHelper(in bundleRel: String) throws -> Process {
        let dest = fx.path(bundleRel + "/Contents/MacOS/helper")
        func run(_ exe: String, _ args: [String]) throws {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: exe)
            t.arguments = args
            t.standardError = FileHandle.nullDevice
            try t.run(); t.waitUntilExit()
        }
        func start() throws -> Process? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: dest)
            p.arguments = ["60"]
            guard (try? p.run()) != nil else { return nil }
            usleep(400_000)
            return p.isRunning ? p : nil
        }
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: dest)
        try run("/usr/bin/codesign", ["--force", "-s", "-", dest])
        if let p = try start() { return p }
        try? FileManager.default.removeItem(atPath: dest)
        let src = fx.path("helper.swift")
        try "import Darwin\nsleep(60)\n".write(toFile: src, atomically: true, encoding: .utf8)
        try run("/usr/bin/xcrun", ["swiftc", src, "-o", dest])
        if let p = try start() { return p }
        throw XCTSkip("could not launch a helper process from the fixture bundle on this host")
    }

    func testF2_scannerSeesHelperInsideBundleOnly() throws {
        try makeApp("tmp/Applications/Foo.app")
        try makeApp("tmp/Applications/Other.app", id: "com.example.other")
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(insideBundleAt: fx.path("tmp/Applications/Foo.app")), false)
        let helper = try launchHelper(in: "tmp/Applications/Foo.app")
        defer { if helper.isRunning { helper.terminate() } }
        var seen = false
        for _ in 0..<50 where !seen {
            seen = LiveProcessScanner.isAnyProcessRunning(insideBundleAt: fx.path("tmp/Applications/Foo.app")) == true
            if !seen { usleep(100_000) }
        }
        XCTAssertTrue(seen, "helper process not detected")
        // Case-folded / resolved forms match too; a sibling bundle does not.
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(
            insideBundleAt: fx.path("tmp/Applications/Foo.app").uppercased()), true)
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(insideBundleAt: fx.path("tmp/Applications/Other.app")), false)
        helper.terminate(); helper.waitUntilExit()
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(insideBundleAt: fx.path("tmp/Applications/Foo.app")), false)
    }

    func testF2_policyBlocksWhenAHelperRunsInsideTheBundle() throws {
        try makeApp("tmp/Applications/Foo.app")
        let helper = try launchHelper(in: "tmp/Applications/Foo.app")
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        struct ScanBacked: RunningAppChecking {
            func isRunning(bundleID: String) -> Bool? { false }
            func isAnyProcessRunning(insideBundleAt path: String) -> Bool? {
                LiveProcessScanner.isAnyProcessRunning(insideBundleAt: path)
            }
        }
        let r = policy.evaluate(appItem("tmp/Applications/Foo.app"), action: .trash, expected: nil,
                                pathGuard: try makeGuard(), runningApps: ScanBacked())
        XCTAssertEqual(r.blockers, [.appRunning(bundleID: "com.example.foo")])
    }

    // MARK: F3 (stub probe, so the real /Applications is only ever evaluated lexically)

    struct StubProbe: AppBundleProbing {
        func lstat(_ path: String) -> FileStat? {
            FileStat(device: 1, inode: 2, mode: S_IFDIR | 0o755, uid: getuid(), size: 0, modified: Date(timeIntervalSince1970: 1))
        }
        func realpath(_ path: String) -> String? { path }
        func readInfoPlist(bundle: String) -> InfoPlistRead {
            .ok(bundleID: "com.example.foo", FileStat(device: 1, inode: 3, mode: S_IFREG | 0o644, uid: getuid(),
                                                      size: 10, modified: Date(timeIntervalSince1970: 1)))
        }
        func isOnSealedSystemVolume(_ path: String) -> Bool? { false }
        func signatureSource(_ path: String) -> AppSource { .developerID(teamID: "ZZZZZZZZZZ") }
    }

    private func stubEvaluate(path: String, patterns: [String] = []) throws -> [CleanupBlocker] {
        let g = try ProtectedPaths(homeDirectory: home, temporaryDirectory: fx.path("tmp"), additionalPatterns: patterns)
        let pol = ApplicationBundlePolicy(roots: ApplicationRoots(roots: ["/Applications", fx.path("home/Applications")]),
                                          userID: getuid(), probe: StubProbe())
        let item = ScanItem(url: URL(fileURLWithPath: path), displayName: "Foo", tool: .apps, category: .application,
                            sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review,
                            explanation: "x", ruleID: "apps.bundle", cleanupMethod: .trashApplication(bundleID: "com.example.foo"))
        return pol.evaluate(item, action: .trash, expected: nil, pathGuard: g, runningApps: running).blockers
    }

    func testF3_waiverStillAppliesWithoutAPattern() throws {
        XCTAssertEqual(try stubEvaluate(path: "/Applications/Foo.app"), [])
    }

    func testF3_protectPatternOnWaivedPathAlwaysWins() throws {
        for pattern in ["/Applications/Foo.app", "/Applications/Fo*.app", "/Applications/Foo.app/**"] {
            let b = try stubEvaluate(path: "/Applications/Foo.app", patterns: [pattern])
            XCTAssertTrue(b.contains { if case .protectedPath(.protectedPath, _, _, _) = $0 { true } else { false } },
                          "\(pattern): \(b)")
        }
        // A pattern for another path does not interfere.
        XCTAssertEqual(try stubEvaluate(path: "/Applications/Foo.app", patterns: ["/Applications/Bar.app"]), [])
    }

    func testF3_anchoredPatternDenialDoesNotChangeCheck() throws {
        let g = try makeGuard()
        XCTAssertNil(g.anchoredPatternDenial("/Applications/Foo.app"))
        XCTAssertEqual(g.check("/Applications/Foo.app").denial?.reason, .systemLocation)
        XCTAssertEqual(g.anchoredPatternDenial(home + "/.ssh")?.reason, .protectedPath)
    }

    // MARK: nits

    func testNit_dataVolumeAliasIsNotLabelledAppleOrSystem() throws {
        let b = try stubEvaluate(path: "/System/Volumes/Data/Applications/Foo.app")
        XCTAssertFalse(b.contains(.appBundleRefused(.appleOrSystem)), "\(b)")
    }

    func testNit_permanentDeleteBlockerIsListedOnce() async throws {
        try makeApp("tmp/Applications/Foo.app")
        let e = try engine(options: CleanupOptions(requestPermanentDelete: true, permanentDeleteEnabled: true))
        let plan = await e.plan([appItem("tmp/Applications/Foo.app")])
        XCTAssertEqual(plan.entries[0].blockers.filter { $0 == .appBundleRefused(.permanentDelete) }.count, 1)
        _ = try await e.execute(plan)
        let rec = try XCTUnwrap(try AuditLog.read(auditURL).first)
        XCTAssertEqual(rec.reasons.filter { $0 == "appBundleRefused:permanentDelete" }.count, 1)
    }
}
