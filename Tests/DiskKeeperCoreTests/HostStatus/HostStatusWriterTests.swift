import XCTest
@testable import DiskKeeperCore

final class HostStatusWriterTests: XCTestCase {
    private var tmp: TemporaryDirectory!
    private var url: URL!
    override func setUpWithError() throws {
        tmp = try TemporaryDirectory()
        url = tmp.url.appendingPathComponent("AIDiskKeeper/status.json")
    }
    override func tearDown() { tmp = nil }

    func testWritesDecodableFileWithMode0600() throws {
        let writer = HostStatusWriter(fileURL: url)
        try writer.write(HostStatusFixtures.status())
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try HostStatus.makeDecoder().decode(HostStatus.self, from: Data(contentsOf: url)), HostStatusFixtures.status())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".tmp"), "no temp file is left")
    }

    func testReaderNeverSeesPartialJSON() throws {
        let writer = HostStatusWriter(fileURL: url)
        try writer.write(HostStatusFixtures.status())
        let done = NSLock(); var finished = false
        let reader = Thread { [url] in
            var reads = 0
            while true {
                done.lock(); let stop = finished; done.unlock()
                if stop, reads > 0 { break }
                guard let data = try? Data(contentsOf: url!) else { XCTFail("file vanished"); break }
                if (try? HostStatus.makeDecoder().decode(HostStatus.self, from: data)) == nil { XCTFail("partial JSON"); break }
                reads += 1
            }
        }
        let exit = expectation(description: "reader done")
        reader.qualityOfService = .userInitiated
        let watcher = Thread { while !reader.isFinished { usleep(1000) }; exit.fulfill() }
        reader.start(); watcher.start()
        for i in 0..<200 {
            var s = HostStatusFixtures.status()
            s.topWriters = (0..<10).map { .init(pid: Int32($0), name: String(repeating: "x", count: 50 + i), agent: nil, worktree: nil, writeBytesPerSec: Double(i)) }
            try writer.write(s)
        }
        done.lock(); finished = true; done.unlock()
        wait(for: [exit], timeout: 20)
    }

    func testQuitWritesRunningFalseAndLaterWritesAreIgnored() throws {
        let writer = HostStatusWriter(fileURL: url)
        try writer.write(HostStatusFixtures.status())
        writer.markStopped(now: HostStatusFixtures.date.addingTimeInterval(5))
        var read = try HostStatus.makeDecoder().decode(HostStatus.self, from: Data(contentsOf: url))
        XCTAssertFalse(read.running)
        XCTAssertEqual(read.generatedAt, HostStatusFixtures.date.addingTimeInterval(5))
        try writer.write(HostStatusFixtures.status())   // a racing tick after the quit
        read = try HostStatus.makeDecoder().decode(HostStatus.self, from: Data(contentsOf: url))
        XCTAssertFalse(read.running)
    }

    func testToggleOffRemovesTheFileAndOnWritesAgain() throws {
        let writer = HostStatusWriter(fileURL: url)
        try writer.write(HostStatusFixtures.status())
        writer.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try writer.write(HostStatusFixtures.status())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testQuitWithoutAnyWriteCreatesNothing() {
        HostStatusWriter(fileURL: url).markStopped()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
