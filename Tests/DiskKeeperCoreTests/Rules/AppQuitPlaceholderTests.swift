import XCTest
@testable import DiskKeeperCore

/// T39: `cleanup.requiresAppQuit: "{name}"`.
final class AppQuitPlaceholderTests: XCTestCase {
    private let env = PathEnvironment(home: "/H", temporaryDirectory: "/T", variables: [:])

    private func validate(match: String = #"{"kind": "children", "type": "directory"}"#,
                          quit: String) -> Result<RuleFile, RuleLoadError> {
        let rule = RuleFixtures.rule(paths: #"["$CACHES"]"#, match: match, extra: #""cleanup": {"method": "trash", "requiresAppQuit": "\#(quit)"}"#)
        return RuleFixtures.loader(env).validate(data: Data(RuleFixtures.file(rules: [rule]).utf8),
                                                 file: RuleFixtures.fileURL, source: .user)
    }

    func testDecodingAcceptsPlaceholderOnly() {
        guard case .success(let f) = validate(quit: "{name}") else { return XCTFail("expected success") }
        XCTAssertEqual(f.rules[0].cleanup.requiresAppQuit, "{name}")
        for bad in ["{Name}", "{name}.x", "x{name}", "{}", "{name} "] {
            guard case .failure = validate(quit: bad) else { return XCTFail("\(bad) should be rejected") }
        }
    }

    func testValidatorRequiresChildrenDepthOne() {
        for match in [#"{"kind": "self"}"#, #"{"kind": "children", "depth": 2}"#,
                      #"{"kind": "find", "name": "x", "marker": "m", "maxDepth": 2}"#] {
            let rule = RuleFixtures.rule(paths: #"["$CACHES/x"]"#, match: match,
                                         extra: #""cleanup": {"method": "trash", "requiresAppQuit": "{name}"}"#)
            let r = RuleFixtures.loader(env).validate(data: Data(RuleFixtures.file(rules: [rule]).utf8),
                                                      file: RuleFixtures.fileURL, source: .user)
            guard case .failure(let e) = r else { XCTFail("\(match) should be rejected"); continue }
            XCTAssertEqual(e.kind, .invalidValue, match)
            XCTAssertTrue(e.description.contains("requiresAppQuit"), "\(e)")
        }
    }

    func testEngineSubstitutesAndSkipsInvalidLeaf() async throws {
        let f = try FixtureHome()
        try f.file("Library/Caches/com.example.App/a.bin", bytes: 10)
        try f.file("Library/Caches/Not A Bundle/a.bin", bytes: 10)
        try f.file("Library/Caches/plain/a.bin", bytes: 10)
        let json = RuleFixtures.file(tool: "t", rules: [RuleFixtures.rule(
            category: "systemJunk", paths: #"["$CACHES"]"#, match: #"{"kind": "children", "type": "directory"}"#,
            extra: #""cleanup": {"method": "trash", "requiresAppQuit": "{name}"}"#)])
        let r = try await RuleHarness.run(json: json, fixture: f)
        XCTAssertEqual(r.loadErrors, [])
        XCTAssertEqual(r.items.map(\.path), [f.abs("Library/Caches/com.example.App")])
        XCTAssertEqual(r.items.first?.requiresAppQuit, "com.example.App")
        XCTAssertTrue(r.warnings.isEmpty)
    }
}
