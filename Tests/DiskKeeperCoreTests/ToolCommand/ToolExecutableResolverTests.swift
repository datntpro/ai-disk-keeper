import Darwin
import XCTest
@testable import DiskKeeperCore

final class ToolExecutableResolverTests: XCTestCase {
    private var fx: TemporaryDirectory!
    override func setUpWithError() throws { fx = try TemporaryDirectory() }
    override func tearDown() { fx = nil }
    private let resolver = ToolExecutableResolver()

    private func failure(_ candidates: [String]) -> ToolUnavailable? {
        if case .failure(let f) = resolver.resolve(candidates: candidates) { return f }
        return nil
    }

    func testResolvesGoodExecutableToRealpath() throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        let link = fx.path("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe)
        guard case .success(let url) = resolver.resolve(candidates: ["/nonexistent/tool", link]) else { return XCTFail("refused") }
        XCTAssertEqual(url.path, exe)
    }

    func testNotFound() { XCTAssertEqual(failure(["/nonexistent/tool"]), .notFound); XCTAssertEqual(failure([]), .notFound) }

    func testRelativeCandidatesAreIgnored() throws { XCTAssertEqual(failure(["adk-test", "bin/x"]), .notFound) }

    func testDirectoryIsRefused() throws {
        try FileManager.default.createDirectory(atPath: fx.path("d"), withIntermediateDirectories: true)
        guard case .notRegularFile? = failure([fx.path("d")]) else { return XCTFail("\(String(describing: failure([fx.path("d")])))") }
    }

    func testNotExecutableIsRefused() throws {
        let exe = try ToolFixtures.writeTool(in: fx); chmod(exe, 0o644)
        guard case .notExecutable? = failure([exe]) else { return XCTFail() }
    }

    func testGroupAndWorldWritableAreRefused() throws {
        let exe = try ToolFixtures.writeTool(in: fx)
        chmod(exe, 0o775)
        guard case .unsafeOwnerOrMode? = failure([exe]) else { return XCTFail("group-writable file") }
        chmod(exe, 0o755)
        chmod((exe as NSString).deletingLastPathComponent, 0o757)
        guard case .unsafeOwnerOrMode? = failure([exe]) else { return XCTFail("world-writable parent") }
        chmod((exe as NSString).deletingLastPathComponent, 0o755)
        XCTAssertNil(failure([exe]))
    }

    func testSymlinkToBadTargetIsRefused() throws {
        let exe = try ToolFixtures.writeTool(in: fx); chmod(exe, 0o777)
        let link = fx.path("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe)
        XCTAssertNotNil(failure([link]))
    }

    func testOtherOwnerIsRefused() throws {
        // The file is ours; pretending to be another uid makes it "owned by another user".
        let exe = try ToolFixtures.writeTool(in: fx)
        let other = ToolExecutableResolver(userID: getuid() &+ 12345)
        if getuid() == 0 { throw XCTSkip("root owns everything") }
        guard case .failure(.unsafeOwnerOrMode) = other.resolve(candidates: [exe]) else { return XCTFail() }
    }

    func testFirstExistingCandidateWinsEvenIfLaterOnesAreGood() throws {
        let bad = try ToolFixtures.writeTool(in: fx, name: "bad"); chmod(bad, 0o666)
        let good = try ToolFixtures.writeTool(in: fx, name: "good")
        XCTAssertNotNil(failure([bad, good]))
    }
}
