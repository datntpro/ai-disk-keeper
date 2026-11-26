import Foundation

/// Every string of the menu bar extra and its notification. Numbers and bytes arrive already formatted.
enum MenuBarCopy {
    static func free(_ bytes: String) -> String { loc("menubar.free", "\(bytes) free") }
    static func usedPercent(_ percent: String) -> String { loc("menubar.usedPercent", "\(percent) %") }
    static func safe(_ bytes: String) -> String { loc("menubar.safe", "+\(bytes) Safe to reclaim") }
    static func scanned(_ when: String) -> String { loc("menubar.scanned", "scanned \(when)") }
    static var notScanned: String { loc("menubar.notScanned", "Not scanned yet") }
    static func growth(_ bytes: String) -> String { loc("menubar.growth", "AI tools grew since last scan +\(bytes)") }
    static func growthDown(_ bytes: String) -> String { loc("menubar.growthDown", "AI tools shrank since last scan \(bytes)") }
    static func topModule(_ name: String, _ bytes: String) -> String { loc("menubar.topModule", "\(name) · \(bytes) Safe") }
    static var topTools: String { loc("menubar.topTools", "Top AI tools") }
    static func nextScan(_ when: String) -> String { loc("menubar.nextScan", "Next Care Scan: \(when)") }
    static var reviewInApp: String { loc("menubar.reviewInApp", "Review in app") }
    static var scanNow: String { loc("menubar.scanNow", "Scan now") }
    static var scanning: String { loc("menubar.scanning", "Scanning…") }
    static var quit: String { loc("menubar.quit", "Quit AI Disk Keeper") }
    static func labelA11y(_ free: String) -> String { loc("menubar.label.a11y", "AI Disk Keeper, \(free) free") }
    static var lowSpaceTitle: String { loc("menubar.lowSpace.title", "Your disk is almost full") }
    static func lowSpaceBody(free: String, percent: String) -> String {
        loc("menubar.lowSpace.body", "\(free) free (\(percent) %). Open AI Disk Keeper to review what's safe to remove.")
    }
}
