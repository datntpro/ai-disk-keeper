import DiskKeeperCore
import Foundation

/// Every notification the app can post. `LowSpaceNotifying` (T47) is unchanged; scheduled scans (T22) add two calls.
@MainActor
protocol AppNotifying: LowSpaceNotifying {
    /// Asks for notification permission now. Called when the user turns scheduled scans on, never at launch.
    @discardableResult func requestPermission() async -> Bool
    /// Posts the one alert of a scheduled run. Never asks for permission itself.
    func notifyScheduled(_ alert: ScheduledAlert) async
}

extension SilentLowSpaceNotifier: AppNotifying {
    func requestPermission() async -> Bool { false }
    func notifyScheduled(_ alert: ScheduledAlert) async {}
}
