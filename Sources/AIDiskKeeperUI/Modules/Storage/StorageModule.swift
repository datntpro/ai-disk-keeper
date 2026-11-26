import AppKit
import DiskKeeperCore
import SwiftUI

/// Storage overview: capacity, purgeable space, local snapshots and the Trash. Report-only.
enum StorageModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .storage, section: .storage, order: 4, symbol: "internaldrive",
                                             isEnabled: true)

    /// The shared volume model (sidebar gauge, this screen; Overview and the menu bar read it later).
    @MainActor static func model(_ ctx: ModuleContext) -> StorageModel {
        let env = ctx.env.pathEnvironment
        return ctx.suite.state(.storage) { StorageModel(load: live(environment: env)) }
    }

    static func live(environment env: PathEnvironment) -> @Sendable () async throws -> StorageOverview {
        let service = StorageOverviewService(environment: env)
        return { try await service.overview() }
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(StorageView(model: model(ctx), trashURL: URL(fileURLWithPath: ctx.env.pathEnvironment.home + "/.Trash")))
    }
}
