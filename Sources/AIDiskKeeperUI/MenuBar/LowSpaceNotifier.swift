import DiskKeeperCore
import Foundation
import UserNotifications

/// Posts the low-space notification. The model takes this protocol so tests never post a real one.
@MainActor
protocol LowSpaceNotifying: AnyObject {
    func notify(freeBytes: Int64, percent: Int) async
}

/// Used when nothing should be posted (tests, previews, `RootView(env:)`).
@MainActor
final class SilentLowSpaceNotifier: LowSpaceNotifying {
    func notify(freeBytes: Int64, percent: Int) async {}
}

/// `UNUserNotificationCenter` adapter. Asks for permission the first time an alert would fire (never at launch).
/// A no-op without an app bundle (`swift run`), where `UNUserNotificationCenter.current()` traps.
@MainActor
final class LiveLowSpaceNotifier: NSObject, AppNotifying, UNUserNotificationCenterDelegate {
    /// Called when the user clicks the notification: bring the app up on Overview.
    var onOpen: @MainActor () -> Void = {}

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func notify(freeBytes: Int64, percent: Int) async {
        guard let center else { return }
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = MenuBarCopy.lowSpaceTitle
        content.body = MenuBarCopy.lowSpaceBody(free: Formatting.bytes(freeBytes), percent: Formatting.count(percent))
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "adk.lowSpace", content: content, trigger: nil))
    }

    func requestPermission() async -> Bool {
        guard let center else { return false }
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        let now = await center.notificationSettings().authorizationStatus
        return now == .authorized || now == .provisional
    }

    func notifyScheduled(_ alert: ScheduledAlert) async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = ScheduleCopy.notificationTitle
        switch alert {
        case .safeToFree(let bytes): content.body = ScheduleCopy.safeBody(Formatting.bytes(bytes))
        case .aiToolsGrew(let bytes): content.body = ScheduleCopy.growthBody(Formatting.bytes(bytes))
        }
        content.userInfo = ["target": "careScan"]
        try? await center.add(UNNotificationRequest(identifier: "adk.scheduledScan", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen() }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
