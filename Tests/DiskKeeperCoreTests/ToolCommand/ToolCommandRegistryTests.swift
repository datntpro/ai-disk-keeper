import XCTest
@testable import DiskKeeperCore

final class ToolCommandRegistryTests: XCTestCase {
    private let env = PathEnvironment(home: "/Users/x", temporaryDirectory: "/tmp", variables: [:])
    private var reg: ToolCommandRegistry { ToolCommandRegistry(specs: [ToolFixtures.spec(exe: "/bin/echo")]) }

    private func refusal(_ item: ScanItem, _ r: ToolCommandRegistry? = nil) -> String? {
        if case .failure(let f) = (r ?? reg).match(item, environment: env) { return f.reason }
        return nil
    }

    func testExactMatchBindsTheArgv() throws {
        guard case .success(let m) = reg.match(ToolFixtures.virtualItem(), environment: env) else { return XCTFail("refused") }
        XCTAssertEqual(m.argv, ["thing", "rm", ToolFixtures.imageID])
    }

    func testBuiltInRegistryIsEmptyAndRefusesEverything() {
        XCTAssertTrue(ToolCommandRegistry.builtIn.specs.isEmpty)
        XCTAssertNotNil(refusal(ToolFixtures.virtualItem(), .builtIn))
    }

    func testRefusals() {
        let id = ToolFixtures.imageID
        func method(_ args: [String], command: String = "adk-test") -> CleanupMethod { .toolCommand(command: command, arguments: args) }
        let cases: [(String, ScanItem)] = [
            ("literal mismatch", ToolFixtures.virtualItem(method: method(["thing", "rmi", id]))),
            ("extra arg", ToolFixtures.virtualItem(method: method(["thing", "rm", id, "--force"]))),
            ("missing arg", ToolFixtures.virtualItem(method: method(["thing", "rm"]))),
            ("leading dash", ToolFixtures.virtualItem(method: method(["thing", "rm", "-f"]))),
            ("bad pattern", ToolFixtures.virtualItem(method: method(["thing", "rm", "sha256:xyz"]))),
            ("unicode lookalike", ToolFixtures.virtualItem(method: method(["thing", "rm", "sha256:" + String(repeating: "а", count: 64)]))),
            ("NUL", ToolFixtures.virtualItem(method: method(["thing", "rm", id + "\0"]))),
            ("other command", ToolFixtures.virtualItem(method: method(["thing", "rm", id], command: "docker"))),
            ("rule not in spec", ToolFixtures.virtualItem(rule: "other.rule")),
            ("binding mismatch", ToolFixtures.virtualItem(id: id, method: method(["thing", "rm", ToolFixtures.otherID]))),
            ("none method", ToolFixtures.virtualItem(method: CleanupMethod.none)),
        ]
        for (name, item) in cases { XCTAssertNotNil(refusal(item), name) }
    }

    func testWrongTargetKindIsRefused() {
        // A real path for a virtual spec.
        let real = ScanItem(url: URL(fileURLWithPath: "/Users/x/cache"), displayName: "c", tool: "t", category: .aiToolData,
                            sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x",
                            ruleID: "test.rule", cleanupMethod: .toolCommand(command: "adk-test", arguments: ["thing", "rm", ToolFixtures.imageID]))
        XCTAssertEqual(refusal(real), "wrong target kind")
        // Another namespace.
        let path = VirtualItemPath.build(namespace: "other", target: "t", kind: "image", id: ToolFixtures.imageID)!
        var other = ToolFixtures.virtualItem()
        other = ScanItem(url: URL(fileURLWithPath: path), displayName: "x", tool: "t", category: .aiToolData, sizeAllocated: 1,
                         sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x", ruleID: "test.rule",
                         cleanupMethod: other.cleanupMethod)
        XCTAssertEqual(refusal(other), "wrong target kind")
    }

    func testTwoMatchingSpecsAreAmbiguousAndRefused() {
        let two = ToolCommandRegistry(specs: [ToolFixtures.spec(exe: "/bin/echo"), ToolFixtures.spec(exe: "/bin/echo", id: "dup")])
        XCTAssertEqual(refusal(ToolFixtures.virtualItem(), two), "ambiguous command")
    }

    func testPathTargetMustBeDirectlyUnderRoot() {
        let spec = ToolFixtures.spec(exe: "/bin/echo", target: .path(root: { $0.home + "/devices" }))
        let r = ToolCommandRegistry(specs: [spec])
        func item(_ path: String) -> ScanItem {
            ScanItem(url: URL(fileURLWithPath: path), displayName: "d", tool: "t", category: .aiToolData, sizeAllocated: 1,
                     sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x", ruleID: "test.rule",
                     cleanupMethod: .toolCommand(command: "adk-test", arguments: ["thing", "rm", ToolFixtures.imageID]))
        }
        // `bind` reads the virtual path, so a real path cannot bind: refused even under the root.
        XCTAssertNotNil(refusal(item("/Users/x/devices/abc"), r))
        XCTAssertEqual(refusal(item("/Users/x/other/abc"), r), "wrong target kind")
    }

    func testArgPatterns() {
        XCTAssertTrue(ArgPattern.dockerContainerID.matches(String(repeating: "0", count: 64)))
        XCTAssertFalse(ArgPattern.dockerContainerID.matches(String(repeating: "0", count: 63)))
        XCTAssertTrue(ArgPattern.dockerVolumeName.matches("my_vol-1.x"))
        XCTAssertFalse(ArgPattern.dockerVolumeName.matches("-vol"))
        XCTAssertFalse(ArgPattern.dockerVolumeName.matches("a b"))
        XCTAssertFalse(ArgPattern.dockerVolumeName.matches("a=b"))
        XCTAssertTrue(ArgPattern.dockerImageRef.matches("ghcr.io/org/app:1.2"))
        XCTAssertFalse(ArgPattern.dockerImageRef.matches("app@sha256:abc"))
        XCTAssertFalse(ArgPattern.dockerImageRef.matches("a:b:c"))
        XCTAssertFalse(ArgPattern.dockerImageRef.matches("Upper/app"))
        XCTAssertTrue(ArgPattern.uppercaseUUID.matches("0123ABCD-0123-0123-0123-0123456789AB"))
        XCTAssertFalse(ArgPattern.uppercaseUUID.matches("0123abcd-0123-0123-0123-0123456789ab"))
        XCTAssertFalse(ArgPattern.dockerVolumeName.matches(String(repeating: "a", count: 256)))
    }

    func testVariadicBounds() {
        let spec = ToolCommandSpec(id: "v", command: "c", ruleIDs: ["r"], target: .virtual(namespace: "n"),
                                   template: [.literal("rm"), .params(.dockerVolumeName, max: 2)], bind: { _ in nil },
                                   timeout: .seconds(1), executable: { _, _ in ExecutableChoice(candidates: []) },
                                   environment: { _, _ in [:] })
        XCTAssertFalse(spec.accepts(["rm"]))
        XCTAssertTrue(spec.accepts(["rm", "a"]))
        XCTAssertTrue(spec.accepts(["rm", "a", "b"]))
        XCTAssertFalse(spec.accepts(["rm", "a", "b", "c"]))
    }
}
