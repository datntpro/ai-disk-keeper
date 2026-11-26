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

    func testBuiltInRegistryHoldsOnlyBuiltInToolsAndRefusesUnknownItems() {
        XCTAssertTrue(ToolCommandRegistry.builtIn.specs.allSatisfy { $0.command == "docker" })
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
                            ruleID: "tool.adktest.rule", cleanupMethod: .toolCommand(command: "adk-test", arguments: ["thing", "rm", ToolFixtures.imageID]))
        XCTAssertEqual(refusal(real), "wrong target kind")
        // Another namespace.
        let path = VirtualItemPath.build(namespace: "other", target: "t", kind: "image", id: ToolFixtures.imageID)!
        var other = ToolFixtures.virtualItem()
        other = ScanItem(url: URL(fileURLWithPath: path), displayName: "x", tool: "t", category: .aiToolData, sizeAllocated: 1,
                         sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x", ruleID: "tool.adktest.rule",
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
                     sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x", ruleID: "tool.adktest.rule",
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
        let spec = ToolCommandSpec(id: "v", command: "c", ruleIDs: ["tool.r"], target: .virtual(namespace: "n"),
                                   template: [.literal("rm"), .params(.dockerVolumeName, max: 2)], bind: { _ in nil },
                                   timeout: .seconds(1), executable: { _, _ in ExecutableChoice(candidates: []) },
                                   environment: { _, _ in [:] })
        XCTAssertFalse(spec.accepts(["rm"]))
        XCTAssertTrue(spec.accepts(["rm", "a"]))
        XCTAssertTrue(spec.accepts(["rm", "a", "b"]))
        XCTAssertFalse(spec.accepts(["rm", "a", "b", "c"]))
    }

    // F2: Swift `==` treats the Kelvin sign as K. The bound argv must be checked and compared as raw bytes.
    func testCompatibilityEquivalentUnicodeIsRefused() {
        let spec = ToolCommandSpec(
            id: "x", command: "adk-test", ruleIDs: ["tool.adktest.rule"], target: .virtual(namespace: "adktest"),
            template: [.literal("thing"), .literal("rm"), .param(.dockerVolumeName)],
            bind: { item in VirtualItemPath.parse(item.path).map { ["thing", "rm", $0.id] } },
            timeout: .seconds(5), executable: { _, _ in ExecutableChoice(candidates: []) }, environment: { _, _ in [:] })
        XCTAssertTrue("\u{212A}" == "K", "premise: String == is canonical equivalence")
        let r = ToolCommandRegistry(specs: [spec])
        for lookalike in ["vol\u{212A}", "vol\u{FF4B}", "vo\u{0131}", "vol\u{0430}", "vol\u{200B}", "e\u{0301}", "\u{FB01}le"] {
            let path = VirtualItemPath.build(namespace: "adktest", target: "t1", kind: "volume", id: lookalike)!
            let item = ScanItem(url: URL(fileURLWithPath: path), displayName: "x", tool: "adktest", category: .aiToolData,
                                sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x",
                                ruleID: "tool.adktest.rule",
                                cleanupMethod: .toolCommand(command: "adk-test", arguments: ["thing", "rm", "volK"]))
            XCTAssertNotNil(refusal(item, r), "\(lookalike.unicodeScalars.map(\.value))")
            let own = ScanItem(url: URL(fileURLWithPath: path), displayName: "x", tool: "adktest", category: .aiToolData,
                               sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x",
                               ruleID: "tool.adktest.rule",
                               cleanupMethod: .toolCommand(command: "adk-test", arguments: ["thing", "rm", lookalike]))
            XCTAssertNotNil(refusal(own, r), "bound argv must pass the pattern: \(lookalike.unicodeScalars.map(\.value))")
        }
        XCTAssertFalse(spec.accepts(["thing", "rm", "vol\u{212A}"]))
        XCTAssertFalse(ToolCommandSpec.sameBytes(["\u{212A}"], ["K"]))
        XCTAssertTrue(ToolCommandSpec.sameBytes(["a", "b"], ["a", "b"]))
    }

    // F1: an item whose rule id is outside the reserved namespace (what a JSON rule can produce) never matches,
    // for both target kinds, even when a spec lists that exact id (specs cannot be built that way: see the precondition).
    func testItemsOutsideTheReservedNamespaceNeverMatch() {
        let virtualItem = ToolFixtures.virtualItem(rule: "test.rule")
        XCTAssertEqual(refusal(virtualItem), "only built-in scanners may run a command")
        let r = ToolCommandRegistry(specs: [ToolFixtures.spec(exe: "/bin/echo", target: .path(root: { $0.home + "/.test/cache" }))])
        let pathItem = ScanItem(url: URL(fileURLWithPath: "/Users/x/.test/cache/vol1"), displayName: "v", tool: "test", category: .aiToolData,
                                sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review, explanation: "x",
                                ruleID: "test.rule", cleanupMethod: .toolCommand(command: "adk-test", arguments: ["thing", "rm", "vol1"]))
        XCTAssertEqual(refusal(pathItem, r), "only built-in scanners may run a command")
    }

    func testDisplayEscapesControlAndBidiCharacters() {
        let line = ToolCommandDisplay.line(command: "docker", arguments: ["a\nb", "x\u{202E}y"])
        XCTAssertFalse(line.unicodeScalars.contains { $0 == "\n" || $0 == "\u{202E}" })
        XCTAssertEqual(line, "docker 'a\\u{A}b' 'x\\u{202E}y'")
    }
}
