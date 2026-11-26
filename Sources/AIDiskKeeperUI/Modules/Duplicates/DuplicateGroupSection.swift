import DiskKeeperCore
import SwiftUI

/// One group: a header (name, copy count, "identical content", savings) and its member rows.
struct DuplicateGroupSection: View {
    let model: DuplicatesModel
    let group: DuplicateGroup

    var body: some View {
        Section {
            ForEach(group.members, id: \.path) { member in
                DuplicateMemberRow(model: model, group: group, member: member).tag(member.path)
            }
        } header: {
            header
        }
    }

    private var header: some View {
        let name = (group.keeper.path as NSString).lastPathComponent
        let saves = group.reclaimableBytes
        let savesText = loc("dup.group.saves", "saves \(Formatting.bytes(saves))")
        let copies = loc("dup.group.copies", "\(Formatting.count(group.members.count)) copies")
        let identical = loc("dup.group.identical", "identical content (SHA-256)")
        return HStack(spacing: ADKTheme.Spacing.sm) {
            Text(name).font(.headline).foregroundStyle(.adkText).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "· \(copies) · \(identical)").font(.caption).foregroundStyle(.adkText3).lineLimit(1)
            Spacer()
            Text(savesText).font(.callout.weight(.medium)).monospacedDigit()
                .foregroundStyle(saves == 0 ? Color.adkText3 : Color.adkText)
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loc("dup.a11y.header", "\(name), \(copies), \(savesText)"))
        .accessibilityAddTraits(.isHeader)
    }
}
