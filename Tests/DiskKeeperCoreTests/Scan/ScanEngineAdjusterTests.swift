import XCTest
@testable import DiskKeeperCore
import protocol DiskKeeperCore.Scanner

final class ScanEngineAdjusterTests: XCTestCase {
    struct Closure: ItemAdjuster {
        let name = "test"
        let body: @Sendable ([ScanItem]) -> [ScanItem]
        func adjust(_ items: [ScanItem], context: ScanContext) async -> (items: [ScanItem], warnings: [ScanWarning]) {
            (body(items), [])
        }
    }

    private func run(_ adjusters: [any ItemAdjuster], tier: RiskTier = .safe) async throws -> [ScanEvent] {
        let fx = try FixtureHome()
        let path = try fx.file("logs/a.log", bytes: 10)
        let guardian = try ScanGuard(environment: fx.env, protectPatterns: [])
        let context = ScanContext(environment: fx.env, pathGuard: guardian, now: Date(), maxConcurrentSizing: 1)
        let scanner = ClosureScanner(id: "s") { _, sink in
            await sink.item(EngineKit.item(path, tier: tier, size: 10))
        }
        let engine = ScanEngine(context: context, scanners: [scanner], adjusters: adjusters)
        return await EngineKit.collect(try await engine.scan())
    }

    func testAdjustmentTowardKeepIsAppliedAndAnnounced() async throws {
        let events = try await run([Closure { $0.map { var i = $0; i.tier = .keep; i.flags.insert(.inUse); return i } }])
        let adjusted = events.compactMap { e -> [ScanItem]? in if case .itemsAdjusted(let i) = e { return i } else { return nil } }
        XCTAssertEqual(adjusted.count, 1)
        XCTAssertEqual(adjusted[0].first?.tier, .keep)
        let t = try XCTUnwrap(EngineKit.terminal(events))
        XCTAssertEqual(t.result.items.first?.tier, .keep)
        // `.itemsAdjusted` comes after every item and before the terminal event.
        let idx = try XCTUnwrap(events.firstIndex { if case .itemsAdjusted = $0 { return true } else { return false } })
        let lastItem = try XCTUnwrap(events.lastIndex { if case .itemFound = $0 { return true } else { return false } })
        XCTAssertGreaterThan(idx, lastItem)
        XCTAssertLessThan(idx, events.count - 1)
    }

    func testRaisingATierIsRejectedWithAWarning() async throws {
        let events = try await run([Closure { $0.map { var i = $0; i.tier = .safe; return i } }], tier: .review)
        let t = try XCTUnwrap(EngineKit.terminal(events))
        XCTAssertEqual(t.result.items.first?.tier, .review, "unchanged")
        XCTAssertTrue(t.result.warnings.contains { $0.code == .adjusterRejected(name: "test") })
        XCTAssertFalse(events.contains { if case .itemsAdjusted = $0 { return true } else { return false } })
    }

    func testChangingSizeOrAddingItemsIsRejected() async throws {
        let grow = Closure { $0.map { var i = $0; i.sizeAllocated += 1; return i } }
        let add = Closure { $0 + [EngineKit.item("/nope/x", rule: "other")] }
        for adjuster in [grow, add] {
            let events = try await run([adjuster])
            let t = try XCTUnwrap(EngineKit.terminal(events))
            XCTAssertEqual(t.result.items.first?.sizeAllocated, 10)
            XCTAssertEqual(t.result.items.count, 1)
            XCTAssertTrue(t.result.warnings.contains { $0.code == .adjusterRejected(name: "test") })
        }
    }

    func testDroppingAnItemIsAllowed() async throws {
        let events = try await run([Closure { _ in [] }])
        let t = try XCTUnwrap(EngineKit.terminal(events))
        XCTAssertTrue(t.result.items.isEmpty)
        XCTAssertTrue(t.result.warnings.isEmpty)
    }

    func testNoAdjustersNoEvent() async throws {
        let events = try await run([])
        XCTAssertFalse(events.contains { if case .itemsAdjusted = $0 { return true } else { return false } })
    }
}
