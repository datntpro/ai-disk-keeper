import Foundation

enum ScheduleCopy {
    static var section: String { loc("settings.schedule.section", "Scheduled scans") }
    static var frequency: String { loc("settings.schedule.frequency", "Scan automatically") }
    static var off: String { loc("settings.schedule.off", "Off") }
    static var daily: String { loc("settings.schedule.daily", "Daily") }
    static var weekly: String { loc("settings.schedule.weekly", "Weekly") }
    static var note: String {
        loc("settings.schedule.note", "A scheduled scan only looks: it never selects or cleans anything. Open the app to review what it found.")
    }
    static var safeThreshold: String { loc("settings.schedule.safeThreshold", "Notify when Safe items reach (GB)") }
    static var growthThreshold: String { loc("settings.schedule.growthThreshold", "Notify when AI tools grow by (GB)") }
    static var skipOnBattery: String { loc("settings.schedule.skipOnBattery", "Skip on battery and in Low Power Mode") }
    static var loginItem: String { loc("settings.schedule.loginItem", "Open at login (keeps scheduled scans running)") }
    static var loginNeedsApproval: String { loc("settings.schedule.loginNeedsApproval", "Needs approval in System Settings › Login Items.") }
    static var openLoginSettings: String { loc("settings.schedule.openLoginSettings", "Open Login Items") }
    static var loginUnavailable: String { loc("settings.schedule.loginUnavailable", "Only available in the installed app.") }
    static var notificationTitle: String { loc("schedule.notification.title", "Care Scan finished") }
    static func safeBody(_ bytes: String) -> String { loc("schedule.notification.safe", "\(bytes) is safe to free") }
    static func growthBody(_ bytes: String) -> String { loc("schedule.notification.growth", "AI tools grew by \(bytes) since the last scan") }
}
