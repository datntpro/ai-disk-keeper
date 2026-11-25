import XCTest
@testable import DiskKeeperCore

final class CoreResourcesTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreResourcesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func makeFakeBundle(in dir: URL) throws {
        let contents = dir
            .appendingPathComponent("\(CoreResources.bundleName).bundle/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.fake.\(UUID().uuidString)"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testBundleResolvesUnderSwiftTest() {
        let marker = Bundle(for: CoreResourcesBundleMarker.self).bundleURL
        guard let bundle = CoreResources.bundle else {
            return XCTFail("bundle not found; marker bundleURL=\(marker.path)")
        }
        XCTAssertTrue(bundle.bundleURL.path.hasSuffix("AIDiskKeeper_DiskKeeperCore.bundle"))
    }

    func testRulesDirectoryContainsPlaceholderReadme() throws {
        let rules = try XCTUnwrap(CoreResources.rulesDirectoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rules.appendingPathComponent("README.md").path))
    }

    func testLocateBundleReturnsNilForEmptyCandidates() throws {
        XCTAssertNil(CoreResources.locateBundle(in: []))
        XCTAssertNil(CoreResources.locateBundle(in: [try makeTempDir()]))
    }

    func testLocateBundlePrefersFirstCandidate() throws {
        let a = try makeTempDir()
        let b = try makeTempDir()
        try makeFakeBundle(in: a)
        try makeFakeBundle(in: b)
        let found = try XCTUnwrap(CoreResources.locateBundle(in: [a, b]))
        XCTAssertEqual(found.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path,
                       a.resolvingSymlinksInPath().path)
    }

    func testCandidateDirectoriesAreDeduplicated() {
        let dirs = CoreResources.defaultCandidateDirectories().map { $0.standardizedFileURL.path }
        XCTAssertEqual(dirs.count, Set(dirs).count)
    }
}
