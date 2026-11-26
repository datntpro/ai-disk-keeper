import DiskKeeperCore
import SwiftUI

/// Cleanup History: a read-only view of the audit log, with a CSV export.
enum HistoryModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .history, section: .activity, order: 1, symbol: "clock.arrow.circlepath",
                                             isEnabled: true)

    @MainActor static func model(_ ctx: ModuleContext) -> HistoryModel {
        let env = ctx.env.pathEnvironment
        return ctx.suite.state(.history) {
            HistoryModel(logURL: AuditLog.defaultURL(environment: env), home: env.home)
        }
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(HistoryView(model: model(ctx), coordinator: ctx.suite.cleanup))
    }
}
