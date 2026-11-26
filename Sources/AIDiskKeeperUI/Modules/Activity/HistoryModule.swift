import DiskKeeperCore
import SwiftUI

/// Cleanup History: every action in `audit.jsonl`, grouped by run, with a lifetime counter and CSV export. Read-only.
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
