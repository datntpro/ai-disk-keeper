import AppKit
import DiskKeeperCore
import SwiftUI

/// Age colouring for the disk map's age overlay: five sequential steps (teal → stone) plus "unknown".
enum AgeRamp {
    private static func step(_ bucket: AgeBucket) -> Int {
        switch bucket {
        case .lastMonth: 0
        case .last6Months: 1
        case .lastYear: 2
        case .last3Years: 3
        case .older: 4
        case .unknown: 5
        }
    }

    static func rgba(_ bucket: AgeBucket, _ appearance: ADKAppearance) -> RGBA {
        StrataPalette.age(step(bucket), appearance)
    }

    static func color(_ bucket: AgeBucket) -> Color {
        Color(nsColor: NSColor(name: nil) { rgba(bucket, ADKAppearance($0)).nsColor })
    }

    static func title(_ bucket: AgeBucket) -> String {
        switch bucket {
        case .lastMonth: loc("age.lt30d", "Under 30 days")
        case .last6Months: loc("age.lt6m", "1–6 months")
        case .lastYear: loc("age.lt1y", "6–12 months")
        case .last3Years: loc("age.lt3y", "1–3 years")
        case .older: loc("age.older", "Over 3 years")
        case .unknown: loc("age.unknown", "Unknown age")
        }
    }
}
