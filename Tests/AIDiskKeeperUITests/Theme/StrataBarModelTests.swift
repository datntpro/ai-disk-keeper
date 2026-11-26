import XCTest
@testable import AIDiskKeeperUI

final class StrataBarModelTests: XCTestCase {
    private func seg(_ id: String, _ layer: StrataLayer, _ bytes: Int64) -> StrataSegment {
        StrataSegment(id: id, layer: layer, bytes: bytes, label: id)
    }

    func testOffsetsAreCumulativeAndExact() {
        let m = StrataBarModel(segments: [seg("a", .ai, 333_333_337), seg("b", .build, 333_333_331), seg("c", .model, 111_111_113)],
                               total: 1_000_000_007, free: 222_222_226)
        XCTAssertEqual(m.bars.map(\.start), [0, 333_333_337, 666_666_668])
        XCTAssertEqual(m.bars.map(\.end), [333_333_337, 666_666_668, 777_777_781])
        XCTAssertEqual(m.free, 222_222_226)
    }

    func testTinySegmentsMergeIntoOther() {
        let m = StrataBarModel(segments: [seg("big", .ai, 990_000), seg("t1", .junk, 3_000), seg("t2", .apps, 2_000)], total: 1_000_000)
        XCTAssertEqual(m.bars.count, 2)
        XCTAssertEqual(m.bars.last?.segment.layer, .other)
        XCTAssertEqual(m.bars.last.map { $0.end - $0.start }, 5_000)
    }

    func testZeroTotalIsEmpty() {
        let m = StrataBarModel(segments: [seg("a", .ai, 10)], total: 0, free: 5)
        XCTAssertTrue(m.bars.isEmpty)
        XCTAssertEqual(m.fraction(10), 0)
        XCTAssertEqual(m.percent(10), 0)
    }

    func testSegmentsNeverExceedTotal() {
        let m = StrataBarModel(segments: [seg("a", .ai, 800), seg("b", .build, 800)], total: 1000)
        XCTAssertEqual(m.bars.last?.end, 1000)
        XCTAssertEqual(m.free, 0)
    }
}
