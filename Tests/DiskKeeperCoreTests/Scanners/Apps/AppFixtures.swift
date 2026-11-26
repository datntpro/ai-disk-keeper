import Darwin
import Foundation
@testable import DiskKeeperCore

struct FakeSignatures: CodeSignatureReading {
    var sources: [String: AppSource] = [:]   // by .app file name
    var fallback: AppSource = .developerID(teamID: "TEAM123456")
    func source(ofBundleAt path: String) -> AppSource {
        sources[(path as NSString).lastPathComponent] ?? fallback
    }
}

struct FakeUsage: AppUsageProviding {
    var dates: [String: Date] = [:]
    func lastUsedDate(ofBundleAt path: String) -> Date? { dates[(path as NSString).lastPathComponent] }
}

struct FakeRunning: RunningAppChecking {
    var running: Set<String> = []
    func isRunning(bundleID: String) -> Bool? { running.contains(bundleID) }
}

struct FakeLookup: BundleLookup {
    var answers: [String: Bool?] = [:]
    func isInstalledAnywhere(bundleID: String) -> Bool? { answers[bundleID] ?? nil }
}

/// Builds fake `.app` bundles. Never touches anything outside the directory it is given.
enum AppFixtures {
    @discardableResult
    static func makeApp(at path: String, bundleID: String?, name: String = "Fake", bundleName: String? = nil,
                        binary: Bool = false, receipt: Bool = false, payload: Int = 100,
                        plist: Data? = nil, omitPlist: Bool = false) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: payload).write(to: URL(fileURLWithPath: path + "/Contents/MacOS/exe"))
        if !omitPlist {
            var dict: [String: Any] = ["CFBundleDisplayName": name, "CFBundleExecutable": "exe",
                                       "CFBundleShortVersionString": "1.2"]
            if let bundleName { dict["CFBundleName"] = bundleName }
            if let bundleID { dict["CFBundleIdentifier"] = bundleID }
            let data = try plist ?? PropertyListSerialization.data(
                fromPropertyList: dict, format: binary ? .binary : .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        }
        if receipt {
            try fm.createDirectory(atPath: path + "/Contents/_MASReceipt", withIntermediateDirectories: true)
            try Data([1]).write(to: URL(fileURLWithPath: path + "/Contents/_MASReceipt/receipt"))
        }
        return path
    }

    static func app(_ id: String, name: String, team: String? = "TEAM123456", bundleName: String? = nil,
                    source: AppSource? = nil, path: String? = nil) -> InstalledApp {
        InstalledApp(path: path ?? "/Applications/\(name).app", bundleID: id, name: name, bundleName: bundleName,
                     location: .applications, source: source ?? (team.map { .developerID(teamID: $0) } ?? .unsigned),
                     ownerUID: getuid(), isSymlink: false, sizeAllocated: 1, sizeLogical: 1, fileCount: 1,
                     viewOnlyReason: nil)
    }
}

final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [ScanItem] = []
    private var _warnings: [ScanWarning] = []
    var items: [ScanItem] { lock.withLock { _items } }
    var warnings: [ScanWarning] { lock.withLock { _warnings } }
    private func add(_ i: ScanItem) { lock.withLock { _items.append(i) } }
    private func add(_ w: ScanWarning) { lock.withLock { _warnings.append(w) } }
    var sink: ScanSink {
        ScanSink(item: { [self] in add($0) }, warning: { [self] in add($0) }, progress: { _ in })
    }
}
