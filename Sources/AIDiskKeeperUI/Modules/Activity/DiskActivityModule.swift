import DiskKeeperCore
import SwiftUI

/// Disk Activity: which worktree and which agent is writing to the disk right now. Read-only.
enum DiskActivityModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .diskActivity, section: .activity, order: 0, symbol: "waveform.path.ecg",
                                             isEnabled: true)

    /// One model for the window, the popover and the scheduler.
    @MainActor static func model(env: AppEnvironment, suite: SuiteModel) -> DiskActivityModel {
        suite.state(.diskActivity) {
            DiskActivityModel(sampler: HostLoadSampler(attribution: WorktreeAttribution(home: env.pathEnvironment.home)))
        }
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(DiskActivityView(model: model(env: ctx.env, suite: ctx.suite)))
    }
}
