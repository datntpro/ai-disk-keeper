import SwiftUI

/// Small status chips: Protected, Shared storage, Keeps, Estimate. Icon + text, never colour alone.
struct StatusPill: View {
    enum Kind: CaseIterable, Sendable { case protected, sharedStorage, keeps, estimate }

    let kind: Kind
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    private var symbol: String {
        switch kind {
        case .protected: "lock.shield"
        case .sharedStorage: "externaldrive.connected.to.line.below"
        case .keeps: "arrow.uturn.backward.circle"
        case .estimate: "plusminus"
        }
    }

    private var title: String {
        switch kind {
        case .protected: loc("pill.protected", "Protected")
        case .sharedStorage: loc("pill.sharedStorage", "Shared storage")
        case .keeps: loc("pill.keeps", "Keeps")
        case .estimate: loc("pill.estimate", "Estimate")
        }
    }

    private var ink: Color { kind == .protected ? .adkKeepInk : .adkText2 }
    private var fill: Color { kind == .protected ? .adkKeepSoft : .adkSunken }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(fill, in: Capsule())
            .overlay { if increasedContrast { Capsule().strokeBorder(.adkLineStrong, lineWidth: ADKTheme.hairline) } }
            .accessibilityElement(children: .combine)
    }
}
