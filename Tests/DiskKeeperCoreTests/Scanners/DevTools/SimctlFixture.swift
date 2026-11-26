import Darwin
import Foundation
import XCTest
@testable import DiskKeeperCore

/// A fake home with `Library/Developer/CoreSimulator/Devices`, a fake developer dir and a fake `xcrun` script
/// that records its argv. The host's xcrun, simctl and CoreSimulator are never touched.
final class SimctlFixture {
    static let udidA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    static let udidB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    let home: FixtureHome
    let devices: String
    let devDir: String
    let log: String
    let marker: String
    private(set) var xcrun = ""
    var hasDeveloperDir = true

    var developer: SimctlEnvironment {
        let dir = devDir
        let present = hasDeveloperDir
        return SimctlEnvironment { present ? dir : nil }
    }
    var env: PathEnvironment { home.env }

    init() throws {
        home = try FixtureHome()
        devices = home.abs("Library/Developer/CoreSimulator/Devices")
        devDir = home.abs("$TMP/Xcode/Developer")
        log = home.abs("$TMP/argv.log")
        marker = home.abs("$TMP/launched")
        try FileManager.default.createDirectory(atPath: devices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: devDir, withIntermediateDirectories: true)
    }

    func device(_ udid: String, bytes: Int = 4096) throws {
        try home.file("Library/Developer/CoreSimulator/Devices/\(udid)/data/blob", bytes: bytes)
    }

    func listJSON(_ entries: [(udid: String, available: Bool, state: String, dataPath: String?)]) -> String {
        let rows = entries.map { e -> String in
            let dp = (e.dataPath ?? "\(devices)/\(e.udid)/data")
            return #"{"udid":"\#(e.udid)","name":"Phone \#(e.udid.prefix(2))","isAvailable":\#(e.available),"state":"\#(e.state)","dataPath":"\#(dp)"}"#
        }
        return #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-5":[\#(rows.joined(separator: ","))]}}"#
    }

    /// Writes the fake xcrun: logs argv (one line per call), prints `listJSON` for `list`, and for `delete`
    /// removes the folder when `deletes` is true.
    func installXcrun(listJSON: String, deletes: Bool = true, listExit: Int = 0, extra: String = "") throws {
        let json = home.abs("$TMP/list.json")
        try listJSON.write(toFile: json, atomically: true, encoding: .utf8)
        let body = """
        touch '\(marker)'
        echo "$@" >> '\(log)'
        \(extra)
        case "$1 $2" in
          "simctl list") cat '\(json)'; exit \(listExit) ;;
          "simctl delete") \(deletes ? "rm -rf '\(devices)'/\"$3\"" : "true"); exit 0 ;;
        esac
        exit 3
        """
        let url = URL(fileURLWithPath: home.abs("$TMP/bin/xcrun"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        chmod(url.deletingLastPathComponent().path, 0o755)
        xcrun = url.path
    }

    var argvLog: [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    var launched: Bool { FileManager.default.fileExists(atPath: marker) }

    func scanner() -> UnavailableSimulatorScanner {
        UnavailableSimulatorScanner(devicesRoot: devices, candidates: [xcrun], developer: developer)
    }

    func registry() -> ToolCommandRegistry {
        ToolCommandRegistry(specs: SimctlToolCommands.makeSpecs(xcrunCandidates: [xcrun], developer: developer))
    }

    func performer() -> ToolCommandPerformer {
        ToolCommandPerformer(registry: registry(), context: ToolCommandContext(environment: env, runner: ToolCommandRunner()))
    }

    func context() throws -> ScanContext {
        ScanContext(environment: env, pathGuard: try ScanGuard(environment: env, protectPatterns: []), maxConcurrentSizing: 2)
    }

    func scan() async throws -> (items: [ScanItem], warnings: [ScanWarning]) {
        let c = ItemCollector()
        try await scanner().scan(context: try context(), sink: c.sink)
        return (await c.items, await c.warnings)
    }

    /// An item as the scanner would emit it, without running anything.
    func item(_ udid: String, rule: String = SimctlToolCommands.ruleID, args: [String]? = nil) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: "\(devices)/\(udid)"), displayName: "Phone", tool: "dev-caches",
                 category: .systemJunk, sizeAllocated: 4096, sizeLogical: 4096, fileCount: 1, lastModified: nil,
                 tier: .review, explanation: "x", ruleID: rule,
                 cleanupMethod: .toolCommand(command: "xcrun", arguments: args ?? ["simctl", "delete", udid]),
                 requiresAppQuit: "com.apple.iphonesimulator")
    }
}
