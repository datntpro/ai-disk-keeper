import SwiftUI

/// Byte sizes: monospaced digits, in-app locale, and an honest qualifier when the number is not exact.
struct SizeText: View {
    enum Qualifier: Sendable { case exact, upTo, estimate }

    let bytes: Int64
    var qualifier: Qualifier = .exact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ bytes: Int64, qualifier: Qualifier = .exact) {
        self.bytes = bytes
        self.qualifier = qualifier
    }

    static func string(_ bytes: Int64, _ qualifier: Qualifier) -> String {
        let s = Formatting.bytes(bytes)
        switch qualifier {
        case .exact: return s
        case .upTo: return loc("size.upTo", "up to \(s)")
        case .estimate: return loc("size.estimate", "about \(s)")
        }
    }

    var body: some View {
        Text(Self.string(bytes, qualifier))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(bytes)))
    }
}
