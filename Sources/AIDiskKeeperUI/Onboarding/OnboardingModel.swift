import Foundation
import Observation

@MainActor @Observable
public final class OnboardingModel {
    private let settings: SettingsModel
    @ObservationIgnored private let startScan: () -> Void

    public init(settings: SettingsModel, startScan: @escaping () -> Void) {
        self.settings = settings
        self.startScan = startScan
    }

    /// True until the user has finished (or skipped) onboarding once.
    public var isFirstRun: Bool { !settings.settings.hasCompletedOnboarding }

    /// Marks onboarding complete; with `startScan` also requests the first scan (once).
    public func finish(startScan wantsScan: Bool) {
        guard isFirstRun else { return }
        settings.setOnboardingCompleted(true)
        if wantsScan { startScan() }
    }
}
