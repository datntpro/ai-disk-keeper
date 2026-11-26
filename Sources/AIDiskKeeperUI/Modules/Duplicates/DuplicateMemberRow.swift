import DiskKeeperCore
import SwiftUI

/// One copy in a group: checkbox (or the "Keeps" pill), path, reason chips, size.
struct DuplicateMemberRow: View {
    let model: DuplicatesModel
    let group: DuplicateGroup
    let member: DuplicateMember

    var body: some View {
        let isKeeper = model.isKeeper(member, in: group)
        let selected = model.isSelected(member, in: group)
        let canSelect = model.canSelect(member, in: group)
        let reasons = DuplicateCopyReasons.reasons(for: member, in: group, rule: model.rule,
                                                    isManualKeeper: model.isManualKeeper(group), home: model.home)
        HStack(spacing: ADKTheme.Spacing.md) {
            Toggle(isKeeper ? loc("dup.a11y.keeperCheckbox", "Kept copy, can't be selected")
                            : loc("dup.a11y.checkbox", "Select this copy"),
                   isOn: Binding(get: { selected }, set: { _ in model.toggle(member, in: group) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!canSelect)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ADKTheme.Spacing.sm) {
                    if isKeeper { StatusPill(kind: .keeps) }
                    PathText(member.path)
                }
                if !reasons.isEmpty {
                    HStack(spacing: ADKTheme.Spacing.xs) {
                        ForEach(Array(reasons.enumerated()), id: \.offset) { _, r in ReasonChip(text: DuplicatesCopy.reason(r)) }
                    }
                }
            }
            Spacer(minLength: ADKTheme.Spacing.sm)
            if member.sharesAllStorage && !isKeeper {
                StatusPill(kind: .sharedStorage)
            } else {
                SizeText(member.allocatedBytes).foregroundStyle(.adkText2).font(.callout)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DuplicatesCopy.a11yRow(member: member, group: group, selected: selected))
        .accessibilityAddTraits(canSelect ? .isButton : [])
        .accessibilityAction { model.toggle(member, in: group) }
        .contextMenu {
            if !isKeeper {
                Button(loc("dup.action.keepInstead", "Keep this one instead")) { model.keepInstead(member.path, in: group.id) }
                Divider()
            }
            Button(loc("action.reveal", "Reveal in Finder")) { FinderReveal.reveal(URL(fileURLWithPath: member.path)) }
            Button(loc("dup.action.copyPath", "Copy path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(member.path, forType: .string)
            }
            Button(loc("dup.action.quickLook", "Quick Look")) { DuplicateQuickLook.shared.show(URL(fileURLWithPath: member.path)) }
        }
    }
}

/// A small caption chip. Text only; never colour alone.
struct ReasonChip: View {
    let text: String
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.adkText2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.adkSunken, in: Capsule())
            .overlay { if increasedContrast { Capsule().strokeBorder(.adkLineStrong, lineWidth: ADKTheme.hairline) } }
    }
}
