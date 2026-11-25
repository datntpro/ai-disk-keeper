import XCTest
@testable import DiskKeeperCore

final class ToolIDTests: XCTestCase {
    func testEncodesAsBareString() throws {
        XCTAssertEqual(try jsonString(ToolID.claudeCode), "\"claude-code\"")
    }

    func testDecodesUnknownToolID() throws {
        XCTAssertEqual(try decodeJSON(ToolID.self, "\"my-new-tool\"").rawValue, "my-new-tool")
    }

    func testDecodingEmptyOrInvalidThrows() {
        for bad in ["", "Claude Code", "-x", "a--b"] {
            XCTAssertThrowsError(try decodeJSON(ToolID.self, "\"\(bad)\""), bad)
        }
    }

    func testIsValidTable() {
        for ok in ["claude-code", "a", "x1", "lmstudio"] { XCTAssertTrue(ToolID.isValid(ok), ok) }
        for bad in ["", "A", "a b", "a_b", "-a", "a-", String(repeating: "a", count: 65)] {
            XCTAssertFalse(ToolID.isValid(bad), bad)
        }
    }

    func testWellKnownAreValidAndUnique() {
        XCTAssertEqual(Set(ToolID.wellKnown).count, ToolID.wellKnown.count)
        for t in ToolID.wellKnown {
            XCTAssertTrue(ToolID.isValid(t.rawValue))
            XCTAssertNotNil(t.knownDisplayName, t.rawValue)
        }
        XCTAssertNil(ToolID(rawValue: "unknown-tool").knownDisplayName)
    }

    func testStringLiteral() {
        let t: ToolID = "cursor"
        XCTAssertEqual(t, .cursor)
    }
}
