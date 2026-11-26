import XCTest
@testable import DiskKeeperCore

final class LiveProcessSnapshotTests: XCTestCase {
    private typealias E = LiveProcessScanner.ProcessEntry
    private let snap = [
        E(pid: 10, path: "/h/applications/x.app/contents/macos/x", uid: 501),
        E(pid: 11, path: "/h/applications/x.app2/contents/macos/x", uid: 501),
        E(pid: 12, path: "/h/applications/x.app/contents/xpcservices/h.xpc/h", uid: nil),
        E(pid: 13, path: "/usr/bin/true", uid: 0),
    ]

    func testEntriesMatchByPrefixCaseFoldedAndNotSiblings() {
        XCTAssertEqual(LiveProcessScanner.entries(insideBundleAt: "/H/Applications/X.app", in: snap).map(\.pid), [10, 12])
        XCTAssertTrue(LiveProcessScanner.entries(insideBundleAt: "/h/applications/y.app", in: snap).isEmpty)
    }

    func testSnapshotSeesThisTestProcessWithItsOwner() throws {
        let all = try XCTUnwrap(LiveProcessScanner.snapshot())
        let me = try XCTUnwrap(all.first { $0.pid == getpid() })
        XCTAssertEqual(me.uid, getuid())
        let root = (me.path as NSString).deletingLastPathComponent
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(insideBundleAt: root), true)
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(insideBundleAt: "/nonexistent/adk-none.app"), false)
    }

    private typealias U = LiveProcessScanner.UnresolvedProcess

    /// An unresolved process shaped like the kernel reports it: `pbi_comm` = first 15 bytes, `pbi_name` = first 31.
    private func kernelProc(_ exe: String, pid: pid_t = 1, uid: uid_t? = 501) -> U {
        func cut(_ n: Int) -> String { PathCanonicalizer.fold(String(decoding: Array(exe.utf8.prefix(n)), as: UTF8.self)) }
        return U(pid: pid, uid: uid, comm: cut(15), name: cut(31))
    }

    private func matches(_ exeNames: [String], _ list: [U], conservative: Bool = false) -> [pid_t] {
        LiveProcessScanner.unresolvedMatches(executableNames: exeNames, currentUID: 501, in: list, conservative: conservative).map(\.pid)
    }

    func testUnresolvedMatchesOnCommOwnedByCurrentUser() {
        let list = [U(pid: 1, uid: 501, comm: "myapp"), U(pid: 2, uid: 501, comm: "other"),
                    U(pid: 3, uid: 0, comm: "myapp"), U(pid: 4, uid: nil, comm: "myapp")]
        XCTAssertEqual(matches(["MyApp"], list), [1])
        XCTAssertEqual(matches(["Nope"], list), [])
        XCTAssertEqual(matches([], list), [])
        XCTAssertEqual(matches(["Nope"], list, conservative: true), [1, 2])
    }

    func testRealKernelNameShapesMatchAtEveryLength() {
        let names = [
            "Short",                                        // <= 15
            "Exactly15Chars1",                              // exactly 15
            "Exactly16CharsXY",                             // 16: comm keeps 15
            "AVeryLongExecutableName",                      // 23
            String(repeating: "LongExecutableName", count: 2) + "Plus", // 40: name keeps 31
            "Ünïcödé Ápp Nämé Wïth Ümläuts",                // multibyte, cut mid-character
            String(repeating: "日本語", count: 8),            // 3-byte characters, cut mid-character
        ]
        for n in names {
            XCTAssertEqual(matches([n], [kernelProc(n)]), [1], n)
            XCTAssertEqual(matches([n.uppercased()], [kernelProc(n)]), [1], "case: \(n)")
            XCTAssertEqual(matches([n + "X"], [kernelProc("Unrelated")]), [], n)
        }
        // Real comm for a 16+ char name is 15 chars (the earlier 16-char key never matched).
        XCTAssertEqual(kernelProc("AVeryLongExecutableName").comm, "averylongexecut")
        // pbi_name alone also identifies it (comm may be shared with a sibling executable).
        XCTAssertEqual(matches(["AVeryLongExecutableName"], [U(pid: 1, uid: 501, comm: "other", name: "averylongexecutablename")]), [1])
        // Same 15-char comm, different long name: still blocks (comm collision fails closed).
        XCTAssertEqual(matches(["AVeryLongExecutableOne"], [kernelProc("AVeryLongExecutableTwo")]), [1])
        // A different app's short name never matches.
        XCTAssertEqual(matches(["AVeryLongExecutableName"], [kernelProc("AVeryLong")]), [])
    }

    // MARK: Helper / login-item executables, temp bundles only

    private func makeTempBundle() throws -> (root: URL, app: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adk-f2-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Main.app").path
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try plist("MainExecutableWithLongName").write(toFile: app + "/Contents/Info.plist", atomically: true, encoding: .utf8)
        return (root, app)
    }
    private func plist(_ exe: String) -> String {
        "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>\(exe)</string></dict></plist>"
    }
    private func nested(_ app: String, _ rel: String, exe: String) throws {
        try FileManager.default.createDirectory(atPath: app + "/" + rel + "/Contents/MacOS", withIntermediateDirectories: true)
        try plist(exe).write(toFile: app + "/" + rel + "/Contents/Info.plist", atomically: true, encoding: .utf8)
    }

    func testBundleExecutableNamesIncludeHelpersLoginItemsAndXPC() throws {
        let (root, app) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try nested(app, "Contents/Library/LoginItems/Launcher.app", exe: "LauncherLoginItemHelper")
        try nested(app, "Contents/XPCServices/Svc.xpc", exe: "ServiceXPCBinaryName")
        try nested(app, "Contents/Frameworks/X.framework/Helpers/Inner Helper.app", exe: "InnerHelperExecutable")
        try FileManager.default.createDirectory(atPath: app + "/Contents/Helpers", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app + "/Contents/Helpers/plainhelper-tool", contents: Data([0x41]))
        FileManager.default.createFile(atPath: app + "/Contents/MacOS/second-binary", contents: Data([0x41]))
        let names = Set(LiveProcessScanner.bundleExecutableNames(at: app))
        XCTAssertTrue(names.isSuperset(of: ["MainExecutableWithLongName", "LauncherLoginItemHelper", "ServiceXPCBinaryName",
                                            "InnerHelperExecutable", "plainhelper-tool", "second-binary"]), "\(names)")
        // Each of them blocks through the real shape of an unresolved process; an unrelated one does not.
        for n in names { XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(
            insideBundleAt: app, in: .init(entries: [], unresolved: [kernelProc(n)]), currentUID: 501), true, n) }
        XCTAssertEqual(LiveProcessScanner.isAnyProcessRunning(
            insideBundleAt: app, in: .init(entries: [], unresolved: [kernelProc("Unrelated")]), currentUID: 501), false)
    }

    // MARK: End to end through the uninstall blocker (injected snapshot, nothing on the host is touched)

    private struct SnapshotBacked: RunningAppChecking {
        let snapshot: LiveProcessScanner.Snapshot?
        func isRunning(bundleID: String) -> Bool? { false }
        func isAnyProcessRunning(insideBundleAt path: String) -> Bool? {
            LiveProcessScanner.isAnyProcessRunning(insideBundleAt: path, in: snapshot, currentUID: 501)
        }
    }

    func testUninstallBlockerFromInjectedSnapshot() throws {
        let (root, app) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try nested(app, "Contents/Library/LoginItems/Launcher.app", exe: "LauncherLoginItemHelper")
        func blocked(_ snap: LiveProcessScanner.Snapshot?) -> Bool? {
            SnapshotBacked(snapshot: snap).isAnyProcessRunning(insideBundleAt: app)
        }
        typealias S = LiveProcessScanner.Snapshot
        // Allowed: nothing of the bundle runs.
        XCTAssertEqual(blocked(S(entries: [E(pid: 9, path: "/usr/bin/true", uid: 501)], unresolved: [kernelProc("Unrelated")])), false)
        // Blocked: main executable (16+ chars) with a deleted binary.
        XCTAssertEqual(blocked(S(entries: [], unresolved: [kernelProc("MainExecutableWithLongName")])), true)
        // Blocked: login item left running after the main app quit.
        XCTAssertEqual(blocked(S(entries: [], unresolved: [kernelProc("LauncherLoginItemHelper")])), true)
        // Another user's process with the same name is ignored.
        XCTAssertEqual(blocked(S(entries: [], unresolved: [kernelProc("MainExecutableWithLongName", uid: 0),
                                                           kernelProc("MainExecutableWithLongName", uid: nil)])), false)
        // Process list unreadable: fail closed (unknown).
        XCTAssertNil(blocked(nil))
        // And the policy turns that into the appRunning blocker.
        let policy = ApplicationBundlePolicy(roots: ApplicationRoots(roots: [root.path]), userID: getuid(), probe: PlistProbe())
        let item = ScanItem(url: URL(fileURLWithPath: app), displayName: "Main", tool: .apps, category: .application,
                            sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review,
                            explanation: "x", ruleID: "apps.bundle", cleanupMethod: .trashApplication(bundleID: "com.example.main"))
        let guardRails = try ProtectedPaths(homeDirectory: root.path, temporaryDirectory: root.path)
        func eval(_ snap: LiveProcessScanner.Snapshot?) -> [CleanupBlocker] {
            policy.evaluate(item, action: .trash, expected: nil, pathGuard: guardRails,
                            runningApps: SnapshotBacked(snapshot: snap)).blockers.filter {
                if case .appRunning = $0 { return true }; if case .appStateUnknown = $0 { return true }; return false }
        }
        XCTAssertEqual(eval(S(entries: [], unresolved: [kernelProc("MainExecutableWithLongName")])),
                       [.appRunning(bundleID: "com.example.main")])
        XCTAssertEqual(eval(S(entries: [], unresolved: [])), [])
        XCTAssertEqual(eval(nil), [.appStateUnknown(bundleID: "com.example.main")])
    }

    private struct PlistProbe: AppBundleProbing {
        func lstat(_ path: String) -> FileStat? {
            FileStat(device: 1, inode: 2, mode: S_IFDIR | 0o755, uid: getuid(), size: 0, modified: Date(timeIntervalSince1970: 1))
        }
        func realpath(_ path: String) -> String? { path }
        func readInfoPlist(bundle: String) -> InfoPlistRead {
            .ok(bundleID: "com.example.main", FileStat(device: 1, inode: 3, mode: S_IFREG | 0o644, uid: getuid(),
                                                       size: 10, modified: Date(timeIntervalSince1970: 1)))
        }
        func isOnSealedSystemVolume(_ path: String) -> Bool? { false }
        func signatureSource(_ path: String) -> AppSource { .developerID(teamID: "ZZZZZZZZZZ") }
    }

    func testBundleExecutableNameReadFromInfoPlist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adk-f2-\(UUID().uuidString)/X.app/Contents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        try ("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Xexe</string></dict></plist>")
            .write(to: dir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LiveProcessScanner.bundleExecutableName(at: dir.deletingLastPathComponent().path), "Xexe")
        XCTAssertNil(LiveProcessScanner.bundleExecutableName(at: "/nonexistent/none.app"))
    }
}
