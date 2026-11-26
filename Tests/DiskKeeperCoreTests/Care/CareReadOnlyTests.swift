import XCTest
@testable import DiskKeeperCore

final class CareReadOnlyTests: XCTestCase {
    /// Acceptance: no cleanup API is reachable from the Care sources.
    func testCareSourcesReferenceNoCleanupAPI() throws {
        let careDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DiskKeeperCore/Care")
        let files = try FileManager.default.contentsOfDirectory(at: careDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 7)
        let banned = try NSRegularExpression(
            pattern: #"CleanupEngine|CleanupPlan|TrashAdapter|trashItem|removeItem|unlink|execute\("#)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            let hits = banned.matches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertTrue(hits.isEmpty, "\(f.lastPathComponent) mentions a cleanup API")
        }
    }

    func testCoordinatorHasNoCleanupProperties() {
        let c = CareScanCoordinator(stages: [], history: nil, scopeFingerprint: "x")
        for child in Mirror(reflecting: c).children {
            XCTAssertFalse(String(describing: type(of: child.value)).contains("Cleanup"), "\(child.label ?? "?")")
        }
    }

    private func snapshot(_ root: String) throws -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(atPath: root)
        while let rel = e?.nextObject() as? String {
            let path = root + "/" + rel
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            out[rel] = isDir.boolValue ? "dir" : try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
        }
        return out
    }

    func testFixtureHomeIsUntouchedApartFromTheHistoryFile() async throws {
        let fx = try FixtureHome()
        try fx.file(".t/projects/a.jsonl", bytes: 50)
        try fx.file("Downloads/big.bin", bytes: 2_000)
        let before = try snapshot(fx.home)
        let history = CareHistoryStore(fileURL: CareHistoryStore.defaultFileURL(environment: fx.env))
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [])
        let context = ScanContext(environment: fx.env, pathGuard: guardian, now: Date(), maxConcurrentSizing: 2)
        let events = try await CareKit.run([
            CareStages.rules { ScanEngine(context: context, scanners: [ExampleScanner(directory: fx.abs(".logs"))]) },
            CareStages.index { try await IndexTest.index(fx) },
        ], history: history)
        XCTAssertNotNil(CareKit.report(events))
        let after = try snapshot(fx.home)
        let changed = Set(after.keys).symmetricDifference(before.keys)
            .union(after.keys.filter { before[$0] != nil && before[$0] != after[$0] })
        let allowed: Set<String> = ["Library", "Library/Application Support", "Library/Application Support/AIDiskKeeper",
                                    "Library/Application Support/AIDiskKeeper/care-history.json"]
        XCTAssertTrue(changed.isSubset(of: allowed), "unexpected changes: \(changed.subtracting(allowed))")
        XCTAssertTrue(changed.contains("Library/Application Support/AIDiskKeeper/care-history.json"))
    }
}
