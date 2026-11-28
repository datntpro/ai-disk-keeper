import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

private struct FixtureReader: SSDHealthReading {
    let health: SSDHealth
    func read() -> SSDHealth? { health }
}

private struct SinceBoot: DiskStatisticsReading {
    func read() -> DiskStatistics? { DiskStatistics(bytesRead: 0, bytesWritten: 2_100_000_000_000, totalTimeReadNs: 0, totalTimeWriteNs: 0) }
}

/// The ready card needs NVMe SMART, which a VM lacks, so it is rendered from the recorded values here.
/// Set `ADK_SNAPSHOT_DIR` to also write PNGs (used for the PR screenshot).
@MainActor
final class SSDCardRenderTests: XCTestCase {
    func testReadyAndWarningCardsRender() async throws {
        let ok = SSDHealth(criticalWarning: 0, temperatureCelsius: 28, availableSparePercent: 100, spareThresholdPercent: 99,
                           percentageUsed: 1, bytesWritten: 81_064_666 * 512_000, bytesRead: 78_767_032 * 512_000,
                           powerCycles: 315, powerOnHours: 1002, unsafeShutdowns: 27, mediaErrors: 0)
        var worn = ok
        worn = SSDHealth(criticalWarning: 0, temperatureCelsius: 28, availableSparePercent: 100, spareThresholdPercent: 99,
                         percentageUsed: 85, bytesWritten: ok.bytesWritten, bytesRead: ok.bytesRead, powerCycles: 1,
                         powerOnHours: 1, unsafeShutdowns: 0, mediaErrors: 0)
        let dir = ProcessInfo.processInfo.environment["ADK_SNAPSHOT_DIR"]
        for (name, health) in [("ready", ok), ("warning", worn)] {
            let model = SSDHealthModel(reader: FixtureReader(health: health), statistics: SinceBoot())
            model.refreshIfNeeded()
            await model.settle()
            guard case .ready = model.state else { return XCTFail("not ready") }
            for scheme in [ColorScheme.light, .dark] {
                L10n.apply(.en)
                let view = StorageSSDCard(model: model).padding(16).frame(width: 460)
                    .background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: view)
                r.scale = 2
                let image = try XCTUnwrap(r.cgImage, "\(name) \(scheme)")
                if let dir {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("ssd-card-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
