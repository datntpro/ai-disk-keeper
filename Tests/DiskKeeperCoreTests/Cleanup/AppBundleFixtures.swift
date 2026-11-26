import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// Real lstat/realpath/Info.plist on the temp dir; signature, volume and owner are overridable.
final class FakeAppBundleProbe: AppBundleProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let live = LiveAppBundleProbe()
    private var _signature: AppSource = .developerID(teamID: "TEAM123456")
    private var _sealed: Bool? = false
    private var _ownerOverride: [String: UInt32] = [:]
    private(set) var signatureCalls = 0

    var signature: AppSource {
        get { lock.withLock { _signature } } set { lock.withLock { _signature = newValue } }
    }
    var sealed: Bool? {
        get { lock.withLock { _sealed } } set { lock.withLock { _sealed = newValue } }
    }
    func setOwner(_ uid: UInt32, for path: String) { lock.withLock { _ownerOverride[path] = uid } }

    func lstat(_ path: String) -> FileStat? {
        guard let st = live.lstat(path) else { return nil }
        guard let uid = lock.withLock({ _ownerOverride[path] }) else { return st }
        return FileStat(device: st.device, inode: st.inode, mode: st.mode, uid: uid, size: st.size, modified: st.modified)
    }
    func realpath(_ path: String) -> String? { live.realpath(path) }
    func readInfoPlist(bundle: String) -> InfoPlistRead { live.readInfoPlist(bundle: bundle) }
    func isOnSealedSystemVolume(_ path: String) -> Bool? { lock.withLock { _sealed } }
    func signatureSource(_ path: String) -> AppSource { lock.withLock { signatureCalls += 1; return _signature } }
}

final class FakeAppRunning: RunningAppChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _byID: Bool? = false
    private var _inside: Bool? = false
    var byID: Bool? { get { lock.withLock { _byID } } set { lock.withLock { _byID = newValue } } }
    var inside: Bool? { get { lock.withLock { _inside } } set { lock.withLock { _inside = newValue } } }
    func isRunning(bundleID: String) -> Bool? { byID }
    func isAnyProcessRunning(insideBundleAt path: String) -> Bool? { inside }
}

/// Records every call. Moves into `root` or throws `failure`.
final class RecordingTrash: TrashAdapter, @unchecked Sendable {
    private let lock = NSLock()
    let root: URL
    var failure: Error?
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    init(root: URL) { self.root = root }
    func trashItem(at url: URL) throws -> URL? {
        lock.withLock { _calls.append(url.path) }
        if let failure { throw failure }
        let dest = root.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

func posixError(_ code: Int32) -> Error {
    NSError(domain: NSCocoaErrorDomain, code: 513,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
}

/// `<fx>/tmp/Applications` (stand-in system root: inside the fixture guard's allowed tmp; the real
/// `/Applications` is `systemLocation`, covered lexically by the `waives` tests), `<fx>/home/Applications` (user root), temp Trash and audit.
class AppBundleTestCase: CleanupTestCase {
    var probe: FakeAppBundleProbe!
    var running: FakeAppRunning!
    var trashRec: RecordingTrash!
    var roots: ApplicationRoots { ApplicationRoots(roots: [fx.path("tmp/Applications"), fx.path("home/Applications")]) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try fx.dir("tmp/Applications"); try fx.dir("home/Applications")
        probe = FakeAppBundleProbe()
        running = FakeAppRunning()
        trashRec = RecordingTrash(root: trashDir)
    }

    var policy: ApplicationBundlePolicy { ApplicationBundlePolicy(roots: roots, userID: getuid(), probe: probe) }

    @discardableResult
    func makeApp(_ rel: String, id: String = "com.example.foo", plist: Bool = true) throws -> String {
        let base = fx.path(rel)
        try FileManager.default.createDirectory(atPath: base + "/Contents/MacOS", withIntermediateDirectories: true)
        if plist { try writePlist(rel, id: id) }
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: base + "/Contents/MacOS/bin"))
        return base
    }

    func writePlist(_ rel: String, id: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: fx.path(rel) + "/Contents/Info.plist"))
    }

    func appItem(_ rel: String, id: String = "com.example.foo") -> ScanItem {
        let url = URL(fileURLWithPath: fx.path(rel))
        return ScanItem(url: url, displayName: url.lastPathComponent, tool: .apps, category: .application,
                        sizeAllocated: 8192, sizeLogical: 4096, fileCount: 2, lastModified: nil, tier: .review,
                        explanation: "app", ruleID: "apps.bundle", cleanupMethod: .trashApplication(bundleID: id),
                        requiresAppQuit: id, groupID: "app:\(id)")
    }

    func evaluate(_ rel: String, id: String = "com.example.foo", action: CleanupAction = .trash,
                  expected: AppBundleFingerprint? = nil) throws -> (blockers: [CleanupBlocker], fingerprint: AppBundleFingerprint?) {
        policy.evaluate(appItem(rel, id: id), action: action, expected: expected, pathGuard: try makeGuard(),
                        runningApps: running)
    }

    func engine(noPolicy: Bool = false, apps: (any RunningAppChecking)? = nil,
                options: CleanupOptions = .init(), remover: any ItemRemover = RecordingRemover()) throws -> CleanupEngine {
        CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL), trash: trashRec,
                      remover: remover, runningApps: apps ?? running, options: options,
                      appPolicy: noPolicy ? nil : policy)
    }

    func refusals(_ b: [CleanupBlocker]) -> [AppBundleRefusal] {
        b.compactMap { if case .appBundleRefused(let r) = $0 { r } else { nil } }
    }
}
