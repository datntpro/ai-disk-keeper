import SwiftUI

struct StateAction: Identifiable {
    let id = UUID()
    var title: String
    var isDestructive = false
    var action: () -> Void
}

/// Empty, needs-permission, error and progress states, built on `ContentUnavailableView`.
/// A tinted glyph tile, a title that states the fact, one sentence, and at most one primary action.
struct StateView: View {
    enum Kind: Equatable {
        case empty, needsPermission, error, progress(Double?)
        case firstRun, filteredEmpty, partialError, blockingError

        /// Glyph tint and its soft tile colour.
        var tint: (ink: Color, soft: Color) {
            switch self {
            case .empty, .filteredEmpty, .progress: (.adkText2, .adkSurface2)
            case .firstRun: (.adkAccent, .adkAccentSoft)
            case .needsPermission, .partialError: (.adkReviewInk, .adkReviewSoft)
            case .error, .blockingError: (.adkDangerInk, .adkDangerSoft)
            }
        }
    }

    let kind: Kind
    var symbol: String
    var title: String
    var message: String
    var actions: [StateAction] = []
    @Namespace private var focusScope
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    private var firstSafeActionID: StateAction.ID? { actions.first { !$0.isDestructive }?.id }

    /// How many `.borderedProminent` buttons this state shows. Always 0 or 1; tests pin it.
    var primaryActionCount: Int { firstSafeActionID == nil ? 0 : 1 }

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: ADKTheme.Spacing.md) {
                glyphTile
                Text(title).font(.title3.weight(.semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
        } description: {
            VStack(spacing: ADKTheme.Spacing.sm) {
                if !message.isEmpty { Text(message) }
                if case .progress(let value) = kind {
                    if let value {
                        ProgressView(value: value).frame(maxWidth: 240)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } actions: {
            ForEach(actions) { a in
                if a.id == firstSafeActionID {
                    Button(a.title, role: a.isDestructive ? .destructive : nil, action: a.action)
                        .buttonStyle(.borderedProminent).tint(.adkAccent)
                        .prefersDefaultFocus(true, in: focusScope)
                } else {
                    Button(a.title, role: a.isDestructive ? .destructive : nil, action: a.action)
                        .buttonStyle(.bordered)
                }
            }
        }
        .focusScope(focusScope)
        .accessibilityElement(children: .contain)
    }

    private var glyphTile: some View {
        let tint = kind.tint
        return Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(tint.ink)
            .frame(width: 44, height: 44)
            .background(tint.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if increasedContrast {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.adkLineStrong, lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}
