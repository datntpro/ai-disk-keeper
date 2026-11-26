import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class StorageRenderTests: XCTestCase {
    private func ready(_ o: StorageOverview) async -> StorageModel {
        let m = StorageModel(load: { o })
        m.refresh()
        await m.settle()
        return m
    }

    private func render(_ view: some View, scheme: ColorScheme, _ what: String) {
        let r = ImageRenderer(content: view.frame(width: 760, height: 900).environment(\.colorScheme, scheme).background(.adkBg))
        XCTAssertNotNil(r.cgImage, what)
    }

    func testScreenStatesRenderLightAndDark() async {
        let trash = URL(fileURLWithPath: "/h/.Trash")
        let fda = TrashInfo(path: "/h/.Trash", state: .needsFullDiskAccess, allocatedBytes: nil, itemCount: nil)
        let cases: [(String, StorageModel)] = [
            ("ready", await ready(StorageFix.overview())),
            ("fda", await ready(StorageFix.overview(trash: fda))),
            ("snapshots unavailable", await ready(StorageFix.overview(snapshots: .unavailable(.timedOut)))),
            ("no snapshots", await ready(StorageFix.overview(snapshots: .listed([])))),
        ]
        for (name, model) in cases {
            for scheme in [ColorScheme.light, .dark] { render(StorageView(model: model, trashURL: trash), scheme: scheme, name) }
        }
        let loading = StorageModel(load: { try await Task.sleep(nanoseconds: 60_000_000_000); throw CancellationError() })
        loading.refresh()
        render(StorageView(model: loading, trashURL: trash), scheme: .light, "loading")
        let failed = StorageModel(load: { throw StorageFixError() })
        failed.refresh()
        await failed.settle()
        XCTAssertEqual(failed.phase, .failed("boom"))
        render(StorageView(model: failed, trashURL: trash), scheme: .dark, "failed")
    }

    func testGaugeHidesUntilTheFirstMeasurement() async {
        let empty = StorageModel(load: { StorageFix.overview() })
        XCTAssertNil(ImageRenderer(content: StorageGauge(model: empty).frame(width: 220)).cgImage)
        let m = await ready(StorageFix.overview())
        XCTAssertNotNil(ImageRenderer(content: StorageGauge(model: m).frame(width: 220)).cgImage)
    }
}
