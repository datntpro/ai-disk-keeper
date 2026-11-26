import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class ModuleStateResolverTests: XCTestCase {
    private func warn(_ kind: ScanWarning.Kind, _ path: String? = nil) -> ScanWarning { ScanWarning(kind: kind, path: path, message: "m") }

    private func state(hasRun: Bool = true, loading: Bool = false, items: Int = 3, filtered: Int = 3, query: String = "",
                       warnings: [ScanWarning] = [], error: String? = nil) -> ModuleState {
        ModuleStateResolver.state(hasRun: hasRun, isLoading: loading, progress: nil, itemCount: items, filteredCount: filtered,
                                  query: query, warnings: warnings, error: error)
    }

    func testPlainContent() { XCTAssertEqual(state(), .content) }
    func testFirstRun() { XCTAssertEqual(state(hasRun: false, items: 0, filtered: 0), .firstRun) }
    func testEmpty() { XCTAssertEqual(state(items: 0, filtered: 0), .empty) }
    func testFilteredEmpty() { XCTAssertEqual(state(filtered: 0, query: " zzz "), .filteredEmpty(query: "zzz")) }
    func testBlankQueryIsNotFiltered() { XCTAssertEqual(state(filtered: 0, query: "  "), .content) }
    func testPartialCountsNonFDAWarnings() {
        XCTAssertEqual(state(warnings: [warn(.timeout), warn(.needsFullDiskAccess, "/a")]), .partialError(warnings: 1))
        XCTAssertEqual(state(warnings: [warn(.needsFullDiskAccess, "/a")]), .content)
    }
    func testPrecedence() {
        XCTAssertEqual(state(hasRun: false, loading: true, error: "x"), .blockingError("x"))
        XCTAssertEqual(state(hasRun: false, loading: true), .loading(nil))
        XCTAssertEqual(state(hasRun: false, items: 0, filtered: 0, query: "q", warnings: [warn(.timeout)]), .firstRun)
        XCTAssertEqual(state(items: 0, filtered: 0, query: "q", warnings: [warn(.timeout)]), .empty)
        XCTAssertEqual(state(filtered: 0, query: "q", warnings: [warn(.timeout)]), .filteredEmpty(query: "q"))
    }
    func testFDABannerCountsUniquePaths() {
        let w = [warn(.needsFullDiskAccess, "/a"), warn(.needsFullDiskAccess, "/a"), warn(.needsFullDiskAccess, "/b"), warn(.timeout, "/c")]
        XCTAssertEqual(ModuleStateResolver.fdaBanner(warnings: w, fdaGranted: false), 2)
        XCTAssertNil(ModuleStateResolver.fdaBanner(warnings: w, fdaGranted: true))
        XCTAssertNil(ModuleStateResolver.fdaBanner(warnings: [warn(.timeout)], fdaGranted: false))
    }
}
