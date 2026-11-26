import SwiftUI

/// Shape, spacing and type scale. Text uses text styles only, so the app follows the user's text size.
enum ADKTheme {
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Border width for lines and separators.
    static let hairline: CGFloat = 1

    enum Font {
        static let largeTitle = SwiftUI.Font.title.weight(.semibold)
        static let title = SwiftUI.Font.title3.weight(.semibold)
        static let headline = SwiftUI.Font.headline
        static let body = SwiftUI.Font.body
        static let caption = SwiftUI.Font.caption
        static let path = SwiftUI.Font.system(.caption, design: .monospaced)
        // The hero number is `HeroNumberText` (a scaled metric), not a static font.
    }
}
