import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class LargeOldRenderTests: XCTestCase {
    func testKindSummaryAndInspectorRender() async {
        let index = DiskIndexModel(makeIndexer: { throw DiskIndexUnavailable() }, fullDiskAccess: { false })
        let model = LargeOldModel(index: index, scanner: { _ in LargeOldFix.report() }, now: { LargeOldFix.now })
        let views: [AnyView] = [AnyView(LargeOldKindSummary(model: model)), AnyView(LargeOldInspector(model: model))]
        for v in views {
            let r = ImageRenderer(content: v.frame(width: 700, height: 200))
            XCTAssertNotNil(r.cgImage)
        }
    }
}
