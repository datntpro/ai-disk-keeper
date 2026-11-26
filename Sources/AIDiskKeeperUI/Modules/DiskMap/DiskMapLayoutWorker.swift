import DiskKeeperCore
import Foundation

/// One layout request. Everything in it is `Sendable`, so it can run off the main actor.
struct DiskMapLayoutRequest: Sendable {
    var tree: DiskTree
    var focus: DiskNodeID
    var size: CGSize
    var mode: DiskMapModel.Mode
}

/// Runs `DiskMapLayout` off the main thread. Which result is still wanted is the model's job (a token per request).
enum DiskMapLayoutWorker {
    static let strataOptions = StrataOptions(rows: 6, minimumWidth: 2, rowGap: 1)
    static let tileOptions = TileOptions(levels: 2, minimumArea: 24)

    static func compute(_ r: DiskMapLayoutRequest) -> DiskMapLayout {
        let viewport = LayoutRect(x: 0, y: 0, width: Double(r.size.width), height: Double(r.size.height))
        switch r.mode {
        case .strata: return DiskMapLayout.strata(tree: r.tree, focus: r.focus, viewport: viewport, options: strataOptions)
        case .tiles: return DiskMapLayout.tiles(tree: r.tree, focus: r.focus, viewport: viewport, options: tileOptions)
        }
    }

    static func computeOffMain(_ r: DiskMapLayoutRequest) async -> DiskMapLayout {
        await Task.detached(priority: .userInitiated) { compute(r) }.value
    }
}
