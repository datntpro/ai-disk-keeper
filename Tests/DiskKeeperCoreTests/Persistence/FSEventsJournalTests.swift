import XCTest
@testable import DiskKeeperCore

/// Real FSEvents history on a temp tree (never the user's files).
final class FSEventsJournalTests: XCTestCase {
    func testInPlaceAppendInNestedFileIsReported() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let f = try tmp.file("a/b/c/data.log", bytes: 100)
        guard let device = SizeCache.dataVolumeDevice() else { throw XCTSkip("no Data volume") }
        let journal = LiveFSEventsJournal()
        let since = journal.currentEventID()
        let h = try FileHandle(forWritingTo: f)
        try h.seekToEnd()
        try h.write(contentsOf: Data(repeating: 0x42, count: 100))
        try h.close()
        let result = await journal.changedPaths(since: since, device: device)
        guard case .changed(let paths) = result else { return XCTFail("journal gave up: \(result)") }
        let keys = Set(paths.map { PathCanonicalizer.key($0).components })
        let want = PathCanonicalizer.key(f.path).components
        // The file itself, or the directory holding it, must be reported (so the item containing it is invalidated).
        let parent = Array(want.dropLast())
        XCTAssertTrue(keys.contains(where: { $0 == want || $0 == parent }),
                      "no event for \(f.path); got \(paths.prefix(5))")
    }

    func testUUIDIsStablePerDevice() throws {
        guard let device = SizeCache.dataVolumeDevice() else { throw XCTSkip("no Data volume") }
        let j = LiveFSEventsJournal()
        XCTAssertNotNil(j.volumeUUID(device: device))
        XCTAssertEqual(j.volumeUUID(device: device), j.volumeUUID(device: device))
    }
}
