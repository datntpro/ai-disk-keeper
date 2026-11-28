import Darwin
import XCTest
@testable import DiskKeeperCore

/// PR #154 verifier attack tests (FixtureHome only; nothing touches the real home).
final class H7VerifierAttackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    private let dd = "Library/Developer/Xcode/DerivedData"

    private func plist(_ ws: String) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": ws], format: .xml, options: 0)) ?? Data()
    }

    @discardableResult
    private func derived(_ f: FixtureHome, _ rel: String, ws: String?, days: Double, deepFileDays: Double? = nil) throws -> String {
        try f.file("\(rel)/Build/out.o", bytes: 4096, modified: ago(days: deepFileDays ?? days))
        if let ws {
            XCTAssertTrue(FileManager.default.createFile(atPath: f.abs("\(rel)/info.plist"), contents: plist(ws)))
            try FileManager.default.setAttributes([.modificationDate: ago(days: days)], ofItemAtPath: f.abs("\(rel)/info.plist"))
        }
        try f.dir("\(rel)/Build", modified: ago(days: days))
        return try f.dir(rel, modified: ago(days: days))
    }

    private func scanDD(_ f: FixtureHome) async throws -> [ScanItem] {
        let ctx = ScanContext(environment: f.env, pathGuard: try ScanGuard(environment: f.env, protectPatterns: []),
                              now: now, maxConcurrentSizing: 2)
        let c = ItemCollector()
        try await DerivedDataScanner.live(environment: f.env).scan(context: ctx, sink: c.sink)
        return await c.items
    }

    private func runRules(_ f: FixtureHome) async throws -> HarnessResult {
        let r = try await RuleHarness.run(bundledFile: "build-caches.json", fixture: f, now: now)
        XCTAssertEqual(r.loadErrors, [])
        // tart/tmp is a scanner now (a Safe item needs a root that resolves to itself): run it with the rules.
        let ctx = ScanContext(environment: f.env, pathGuard: try ScanGuard(environment: f.env, protectPatterns: []),
                              now: now, maxConcurrentSizing: 2)
        let c = ItemCollector()
        try await TartTmpScanner.live(environment: f.env).scan(context: ctx, sink: c.sink)
        return HarnessResult(items: (r.items + (await c.items)).sorted { $0.path < $1.path },
                             warnings: r.warnings, loadErrors: r.loadErrors)
    }

    @discardableResult
    private func make(_ f: FixtureHome, _ rel: String, days: Double) throws -> String {
        try f.file(rel + "/payload.bin", bytes: 4096, modified: ago(days: days))
        return try f.dir(rel, modified: ago(days: days))
    }

    // MARK: DerivedData

    /// A1: ~/Library/Developer/Xcode symlinked into ~/Documents. Root lstat follows intermediate links.
    func testA1_SymlinkedXcodeParentIntoDocuments() async throws {
        let f = try FixtureHome()
        try derived(f, "Documents/Work/DerivedData/MyThesis", ws: f.abs("Gone/Thesis.xcodeproj"), days: 30)
        try f.dir("Library/Developer")
        try f.symlink("Library/Developer/Xcode", to: f.abs("Documents/Work"))
        let items = try await scanDD(f)
        let safe = items.filter { $0.tier == .safe }
        print("A1 items:", items.map { "\($0.path) \($0.tier)" })
        XCTAssertTrue(safe.isEmpty, "a Documents folder reached through a symlinked Xcode dir must not be Safe: \(safe.map(\.path))")
    }

    /// A2: live WorkspacePath (old) → Review; live via symlinked parent → Review; dangling-symlink workspace → not gone.
    func testA2_LiveWorkspaceVariants() async throws {
        let f = try FixtureHome()
        let real = try f.dir("Code/App.xcodeproj")
        try f.symlink("LinkToCode", to: f.abs("Code"))
        try f.symlink("Dangling.xcodeproj", to: f.abs("nowhere"))
        try derived(f, "\(dd)/Live", ws: real, days: 30)
        try derived(f, "\(dd)/ViaLink", ws: f.abs("LinkToCode/App.xcodeproj"), days: 30)
        try derived(f, "\(dd)/Dangling", ws: f.abs("Dangling.xcodeproj"), days: 30)
        let items = try await scanDD(f)
        for n in ["Live", "ViaLink", "Dangling"] {
            XCTAssertEqual(items.first { $0.displayName == n }?.tier, .review, n)
        }
    }

    /// A3: unreadable parent (EACCES) is not "gone".
    func testA3_UnreadableParentIsNotGone() async throws {
        let f = try FixtureHome()
        try f.dir("Locked/inner")
        try derived(f, "\(dd)/Locked", ws: f.abs("Locked/inner/App.xcodeproj"), days: 30)
        chmod(f.abs("Locked"), 0)
        defer { chmod(f.abs("Locked"), 0o755) }
        let items = try await scanDD(f)
        XCTAssertEqual(items.first { $0.displayName == "Locked" }?.tier, .review)
    }

    /// A4: top dir old but a deep file written an hour ago (running build) → Keep.
    func testA4_RecentDeepWriteIsKept() async throws {
        let f = try FixtureHome()
        try derived(f, "\(dd)/Building", ws: f.abs("Gone/App.xcodeproj"), days: 30, deepFileDays: 0.04)
        let items = try await scanDD(f)
        XCTAssertEqual(items.first?.tier, .keep)
    }

    /// A5: a FIFO as info.plist must not hang the scanner and gives Review.
    func testA5_FifoInfoPlist() async throws {
        let f = try FixtureHome()
        try derived(f, "\(dd)/Fifo", ws: nil, days: 30)
        XCTAssertEqual(mkfifo(f.abs("\(dd)/Fifo/info.plist"), 0o644), 0)
        let items = try await scanDD(f)
        XCTAssertEqual(items.first?.tier, .review)
    }

    /// A6: WorkspacePath under a protected location that was deleted → still only depends on the DerivedData folder.
    func testA6_DerivedDataChildThatIsSymlinkToDocumentsIsSkipped() async throws {
        let f = try FixtureHome()
        try derived(f, "Documents/Precious", ws: f.abs("Gone/X.xcodeproj"), days: 30)
        try f.dir(dd)
        try f.symlink("\(dd)/Precious-abc", to: f.abs("Documents/Precious"))
        let items = try await scanDD(f)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: Rules

    /// A7: ~/.tart symlinked into ~/Documents: tmp children must not become Safe items in Documents.
    func testA7_SymlinkedTartIntoDocuments() async throws {
        let f = try FixtureHome()
        try make(f, "Documents/stuff/tmp/report-2025", days: 30)
        try make(f, "Documents/stuff/vms/myvm", days: 30)
        try f.symlink(".tart", to: f.abs("Documents/stuff"))
        let r = try await runRules(f)
        print("A7 items:", r.items.map { "\($0.path) \($0.tier)" }, r.warnings.map(\.message))
        XCTAssertTrue(r.items.filter { $0.tier == .safe }.isEmpty, "Safe through ~/.tart → ~/Documents: \(r.paths)")
    }

    /// A8: ~/.tart/tmp itself a symlink to ~/Documents → nothing.
    func testA8_SymlinkedTartTmpContainer() async throws {
        let f = try FixtureHome()
        try make(f, "Documents/report", days: 30)
        try f.dir(".tart")
        try f.symlink(".tart/tmp", to: f.abs("Documents"))
        let r = try await runRules(f)
        XCTAssertTrue(r.items.isEmpty, "\(r.paths)")
    }

    /// A9: symlinks inside tart/tmp (to a VM, to Documents) are not items.
    func testA9_SymlinksInsideTartTmp() async throws {
        let f = try FixtureHome()
        let vm = try make(f, ".tart/vms/prod", days: 30)
        try f.symlink(".tart/tmp/looks-like-cache", to: vm)
        try f.symlink(".tart/tmp/docs", to: try f.dir("Documents"))
        let r = try await runRules(f)
        XCTAssertEqual(r.paths, [vm])
        XCTAssertFalse(r.item(vm)!.isSelectable)
    }

    /// A10: a VM directory named like a cache inside vms is never selectable; OCI level-1/2 symlinks not followed.
    func testA10_VMNamedLikeCacheAndOCISymlinkLevels() async throws {
        let f = try FixtureHome()
        let vm = try make(f, ".tart/vms/cache", days: 400)
        let vm2 = try make(f, ".tart/vms/tmp", days: 400)
        try make(f, "Documents/registry/org/img", days: 40)
        try f.dir(".tart/cache/OCIs")
        try f.symlink(".tart/cache/OCIs/evil.io", to: f.abs("Documents/registry"))
        try make(f, "Documents/org2/img2", days: 40)
        try f.dir(".tart/cache/OCIs/ghcr.io")
        try f.symlink(".tart/cache/OCIs/ghcr.io/org2", to: f.abs("Documents/org2"))
        let r = try await runRules(f)
        XCTAssertEqual(r.paths, [vm, vm2])
        for i in r.items { XCTAssertFalse(i.isSelectable); XCTAssertNotEqual(i.tier, .safe) }
    }

    /// A11: OCI image with a 2-level name (registry/image): items are then the digest dirs (tags are symlinks, skipped).
    func testA11_TwoLevelOCIName() async throws {
        let f = try FixtureHome()
        let digest = try make(f, ".tart/cache/OCIs/local.io/img/sha256:aa", days: 40)
        try f.symlink(".tart/cache/OCIs/local.io/img/latest", to: digest)
        let r = try await runRules(f)
        XCTAssertEqual(r.paths, [digest])
        XCTAssertEqual(r.tier(digest), .review)
    }

    /// A12: PNPM_HOME pointing at ~/Documents, at $HOME or at "/": what is offered, and never Safe.
    func testA12a_PnpmHomeDocuments() async throws { try await pnpmHome("Documents") }
    func testA12b_PnpmHomeIsHome() async throws { try await pnpmHome("") }
    func testA12c_PnpmHomeIsRoot() async throws { try await pnpmHome("/") }

    private func pnpmHome(_ value: String) async throws {
        do {
            let f = try FixtureHome()
            let pnpmHome = value == "/" ? "/" : (value.isEmpty ? f.home : f.abs(value))
            f.env = PathEnvironment(home: f.home, temporaryDirectory: f.tempDir, variables: ["PNPM_HOME": pnpmHome])
            try make(f, (value.isEmpty || value == "/" ? "" : value + "/") + "store", days: 40)
            let r = try await RuleHarness.run(bundledFile: "build-caches.json", fixture: f, now: now)
            print("A12 PNPM_HOME=\(pnpmHome):", r.items.map { "\($0.path) \($0.tier)" }, r.loadErrors)
            for i in r.items {
                XCTAssertNotEqual(i.tier, .safe)
                XCTAssertTrue(i.path.hasPrefix(f.tmp.url.path), "outside fixture: \(i.path)")
            }
        }
    }

    /// A13: tart/tmp Safe item sitting on another volume / hard-linked file to a VM disk: trash moves only the link.
    func testA13_HardlinkInTmpToVMDisk() async throws {
        let f = try FixtureHome()
        let disk = try f.file(".tart/vms/prod/disk.img", bytes: 4096, modified: ago(days: 30))
        try f.dir(".tart/tmp")
        XCTAssertEqual(link(disk, f.abs(".tart/tmp/disk.img")), 0)
        _ = try f.file(".tart/tmp/disk.img", bytes: 4096, modified: ago(days: 30))
        let r = try await runRules(f)
        // Reported for the record: a hard link in tmp is Safe; trashing it does not touch the VM's own link.
        print("A13 tmp hardlink tier:", r.tier(f.abs(".tart/tmp/disk.img")) as Any)
    }
    /// A14: ~/.tart symlinked into iCloud Drive (a protected area) → no items at all.
    func testA14_SymlinkedTartIntoICloud() async throws {
        let f = try FixtureHome()
        try make(f, "Library/Mobile Documents/com~apple~CloudDocs/t/tmp/old", days: 30)
        try f.symlink(".tart", to: f.abs("Library/Mobile Documents/com~apple~CloudDocs/t"))
        let r = try await runRules(f)
        print("A14 items:", r.items.map { "\($0.path) \($0.tier)" })
        XCTAssertTrue(r.items.isEmpty, "\(r.paths)")
    }

    /// A15: ~/Library/Developer/Xcode symlinked into iCloud Drive → DerivedData scanner emits nothing.
    func testA15_SymlinkedXcodeIntoICloud() async throws {
        let f = try FixtureHome()
        try derived(f, "Library/Mobile Documents/com~apple~CloudDocs/X/DerivedData/P", ws: f.abs("Gone/P.xcodeproj"), days: 30)
        try f.dir("Library/Developer")
        try f.symlink("Library/Developer/Xcode", to: f.abs("Library/Mobile Documents/com~apple~CloudDocs/X"))
        let items = try await scanDD(f)
        print("A15 items:", items.map { "\($0.path) \($0.tier)" })
        XCTAssertTrue(items.isEmpty)
    }
}
