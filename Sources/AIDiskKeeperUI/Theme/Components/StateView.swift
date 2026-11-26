import SwiftUI

struct StateAction: Identifiable {
    let id = UUID()
    var title: String
    var isDestructive = false
    var action: () -> Void
}

/// Empty, needs-permission, error and progress states, built on `ContentUnavailableView`.
struct StateView: View {
    enum Kind { case empty, needsPermission, error, progress(Double?) }

    let kind: Kind
    var symbol: String
    var title: String
    var message: String
    var actions: [StateAction] = []
    @Namespace private var focusScope

    private var firstSafeActionID: StateAction.ID? { actions.first { !$0.isDestructive }?.id }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            VStack(spacing: ADKTheme.Spacing.sm) {
                Text(message)
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
                Button(a.title, role: a.isDestructive ? .destructive : nil, action: a.action)
                    .prefersDefaultFocus(a.id == firstSafeActionID, in: focusScope)
            }
        }
        .focusScope(focusScope)
        .accessibilityElement(children: .contain)
    }
}
