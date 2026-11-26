import XCTest
@testable import DiskKeeperCore

final class StartupItemScannerTests: XCTestCase {
    func testFixturesAreClassified() async throws {
        let fx = try StartupFixture()
        let valid = try fx.home.file("bin/real", bytes: 4)
        try fx.plist(fx.roots.userAgents, "com.test.valid.plist", ["Label": "com.test.valid", "Program": valid, "RunAtLoad": true])
        try fx.plist(fx.roots.userAgents, "com.test.broken.plist",
                     ["Label": "com.test.broken", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/x", "-a"],
                      "RunAtLoad": true, "StartInterval": 14400])
        try "<?xml version=\"1.0\"?><plist><dict><key>Label".write(
            toFile: fx.roots.userAgents + "/damaged.plist", atomically: true, encoding: .utf8)
        try fx.plist(fx.roots.systemDaemons, "com.vendor.daemon.plist", ["Label": "com.vendor.daemon", "Program": "/gone/daemon"])
        try fx.plist(fx.roots.userAgents, "com.test.bundle.plist", ["Label": "com.test.bundle", "BundleProgram": "Contents/Library/x"])

        let inv = try await fx.scanner().inventory()
        let byName = Dictionary(uniqueKeysWithValues: inv.items.map { ($0.fileName, $0) })
        XCTAssertEqual(inv.items.count, 5)

        let ok = try XCTUnwrap(byName["com.test.valid.plist"])
        XCTAssertEqual(ok.programState, .present)
        XCTAssertFalse(ok.isRemovable)
        XCTAssertEqual(ok.signer, .developerID(teamID: "TEAM123456"))

        let broken = try XCTUnwrap(byName["com.test.broken.plist"])
        XCTAssertEqual(broken.programState, .missing)
        XCTAssertTrue(broken.isRemovable)
        XCTAssertEqual(broken.schedules, [.atLoad, .interval(seconds: 14400)])
        XCTAssertEqual(broken.arguments, ["/Applications/Gone.app/Contents/MacOS/x", "-a"])
        XCTAssertNil(broken.signer)

        let damaged = try XCTUnwrap(byName["damaged.plist"])
        XCTAssertNil(damaged.label)
        XCTAssertNotNil(damaged.parseError)
        XCTAssertFalse(damaged.isRemovable)

        let daemon = try XCTUnwrap(byName["com.vendor.daemon.plist"])
        XCTAssertEqual(daemon.programState, .missing)
        XCTAssertEqual(daemon.domain, .systemDaemon)
        XCTAssertFalse(daemon.isRemovable)

        let bundle = try XCTUnwrap(byName["com.test.bundle.plist"])
        XCTAssertEqual(bundle.programState, .unresolvable)
        XCTAssertTrue(bundle.isBundleManaged)
        XCTAssertFalse(bundle.isRemovable)
    }

    func testSymlinkedPlistIsNotRemovable() async throws {
        let fx = try StartupFixture()
        let real = try fx.plist(fx.home.tempDir, "real.plist", ["Label": "com.test.link", "Program": "/gone/x"])
        try FileManager.default.createSymbolicLink(atPath: fx.roots.userAgents + "/link.plist", withDestinationPath: real)
        let inv = try await fx.scanner().inventory()
        let item = try XCTUnwrap(inv.items.first)
        XCTAssertTrue(item.isSymlink)
        XCTAssertEqual(item.programState, .missing)
        XCTAssertFalse(item.isRemovable)
    }

    func testPlistOwnedBySomeoneElseIsNotRemovable() async throws {
        let fx = try StartupFixture()
        try fx.plist(fx.roots.userAgents, "a.plist", ["Label": "com.test.a", "Program": "/gone/x"])
        let other = getuid() &+ 1
        let inv = try await fx.scanner(userID: other).inventory()
        let item = try XCTUnwrap(inv.items.first)
        XCTAssertFalse(item.ownedByUser)
        XCTAssertFalse(item.isRemovable)
    }

    func testRelativeAndMissingProgramFieldsAreUnresolvable() async throws {
        let fx = try StartupFixture()
        try fx.plist(fx.roots.userAgents, "rel.plist", ["Label": "com.test.rel", "Program": "bin/tool"])
        try fx.plist(fx.roots.userAgents, "none.plist", ["Label": "com.test.none"])
        let inv = try await fx.scanner().inventory()
        XCTAssertEqual(inv.items.map(\.programState), [.unresolvable, .unresolvable])
        XCTAssertEqual(inv.items.last?.schedules, [.onDemand])
        XCTAssertFalse(inv.items.contains(where: \.isRemovable))
    }

    func testOnlyOwnedUserAgentWithMissingProgramIsActionable() {
        for domain in StartupItem.Domain.allCases {
            for state in [StartupItem.ProgramState.present, .missing, .unresolvable] {
                for owned in [true, false] {
                    for link in [true, false] {
                        for label in ["x", nil] as [String?] {
                            let item = StartupItem(plistPath: "/x/a.plist", label: label, program: "/p", domain: domain,
                                                   programState: state, isSymlink: link, ownedByUser: owned)
                            let expected = domain == .userAgent && state == .missing && owned && !link && label != nil
                            XCTAssertEqual(item.isRemovable, expected)
                            XCTAssertEqual(item.makeScanItem().cleanupMethod == .trash, expected)
                            XCTAssertEqual(item.makeScanItem().ruleID, expected ? "startup.brokenAgent" : "startup.viewOnly")
                        }
                    }
                }
            }
        }
    }

    func testScanEmitsOnlyRemovableUserAgents() async throws {
        let fx = try StartupFixture()
        try fx.plist(fx.roots.userAgents, "broken.plist", ["Label": "com.test.broken", "Program": "/gone/x"])
        try fx.plist(fx.roots.userAgents, "fine.plist", ["Label": "com.test.fine", "Program": "/bin/echo"])
        try fx.plist(fx.roots.systemDaemons, "d.plist", ["Label": "com.test.d", "Program": "/gone/d"])
        let collector = ItemCollector()
        let guardian = try ScanGuard(environment: fx.home.env, protectPatterns: [])
        let context = ScanContext(environment: fx.home.env, pathGuard: guardian)
        try await fx.scanner().scan(context: context, sink: collector.sink)
        let items = await collector.items
        XCTAssertEqual(items.map(\.displayName), ["com.test.broken"])
        XCTAssertEqual(items.first?.cleanupMethod, .trash)
        XCTAssertEqual(items.first?.tier, .safe)
        XCTAssertEqual(items.first?.category, .startupItem)
        XCTAssertTrue(items.first?.explanation.hasPrefix("Starts /gone/x, which no longer exists.") == true)
    }

    func testScanGuardAllowsUserLaunchAgents() throws {
        let fx = try StartupFixture()
        let guardian = try ScanGuard(environment: fx.home.env, protectPatterns: [])
        XCTAssertTrue(guardian.check(fx.home.abs("Library/LaunchAgents/x.plist")).isAllowed)
    }

    func testScanLeavesFixtureUntouched() async throws {
        let fx = try StartupFixture()
        try fx.plist(fx.roots.userAgents, "broken.plist", ["Label": "com.test.broken", "Program": "/gone/x"])
        let before = try fx.home.snapshot()
        _ = try await fx.scanner().inventory()
        XCTAssertEqual(try fx.home.snapshot(), before)
    }

    func testSignedPathPrefersEnclosingApp() {
        XCTAssertEqual(StartupItemScanner.signedPath("/Applications/Foo.app/Contents/MacOS/foo"), "/Applications/Foo.app")
        XCTAssertEqual(StartupItemScanner.signedPath("/usr/local/bin/foo"), "/usr/local/bin/foo")
    }

    func testHomebrewServiceAndLoadState() async throws {
        let fx = try StartupFixture()
        try fx.plist(fx.roots.userAgents, "homebrew.mxcl.adkqa.plist", ["Label": "homebrew.mxcl.adkqa", "Program": "/bin/sleep"])
        try fx.plist(fx.roots.userAgents, "com.example.running.plist", ["Label": "com.example.running", "Program": "/bin/sleep"])
        try fx.plist(fx.roots.userAgents, "com.example.other.plist", ["Label": "com.example.other", "Program": "/bin/sleep"])
        try fx.plist(fx.roots.systemDaemons, "com.example.running.plist", ["Label": "com.example.running", "Program": "/bin/sleep"])
        let exe = try fx.script("cat <<'EOF'\n\(StartupFixture.launchctlSample)\nEOF")
        let inv = try await fx.scanner(loaded: LaunchctlLoadedState(executable: exe)).inventory()
        let states = Dictionary(grouping: inv.items, by: \.domain).mapValues { $0.map { "\($0.label ?? "")=\($0.loadState)" }.sorted() }
        XCTAssertEqual(inv.items.first { $0.label == "homebrew.mxcl.adkqa" }?.isHomebrewService, true)
        XCTAssertEqual(states[.userAgent], ["com.example.other=notLoaded", "com.example.running=running(pid: 612)",
                                            "homebrew.mxcl.adkqa=loaded"])
        XCTAssertEqual(states[.systemDaemon], ["com.example.running=unknown"])
        XCTAssertTrue(inv.warnings.isEmpty)
    }

    func testLaunchctlFailureGivesUnknownAndOneWarning() async throws {
        let fx = try StartupFixture()
        try fx.plist(fx.roots.userAgents, "a.plist", ["Label": "com.test.a", "Program": "/bin/sleep"])
        let exe = try fx.script("exit 1")
        let inv = try await fx.scanner(loaded: LaunchctlLoadedState(executable: exe)).inventory()
        XCTAssertEqual(inv.items.first?.loadState, .unknown)
        XCTAssertEqual(inv.warnings.count, 1)
    }
}

actor ItemCollector {
    private(set) var items: [ScanItem] = []
    private(set) var warnings: [ScanWarning] = []
    nonisolated var sink: ScanSink {
        ScanSink(item: { await self.add($0) }, warning: { await self.add($0) }, progress: { _ in })
    }
    private func add(_ i: ScanItem) { items.append(i) }
    private func add(_ w: ScanWarning) { warnings.append(w) }
}
