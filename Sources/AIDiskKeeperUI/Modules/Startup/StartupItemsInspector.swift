import DiskKeeperCore
import SwiftUI

struct StartupItemsInspector: View {
    let model: StartupItemsModel

    var body: some View {
        if let item = model.inspectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    Text(item.displayName).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if item.isRemovable { TierBadge(tier: .safe) }
                    Text(StartupCopy.status(item)).font(.callout).foregroundStyle(.adkText2)
                    SectionCard {
                        Text(explanation(item)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    field(StartupCopy.fieldFile) { PathText(item.plistPath) }
                    if let program = item.program {
                        field(StartupCopy.fieldProgram) {
                            PathText(program)
                            if item.programState == .missing { Text(StartupCopy.missingMark).foregroundStyle(.adkReviewInk) }
                        }
                    } else if item.isBundleManaged {
                        field(StartupCopy.fieldProgram) { Text(StartupCopy.managed) }
                    } else if item.label != nil {
                        field(StartupCopy.fieldProgram) { Text(StartupCopy.unresolved) }
                    }
                    if item.arguments.count > 1 {
                        field(StartupCopy.fieldArguments) {
                            Text(item.arguments.dropFirst().joined(separator: " ")).font(ADKTheme.Font.path).textSelection(.enabled)
                        }
                    }
                    if item.label != nil {
                        field(StartupCopy.colRuns) { Text(StartupCopy.runs(item)) }
                        field(StartupCopy.colWhere) { Text(StartupCopy.domain(item.domain)) }
                        field(StartupCopy.colStatus) { Text(StartupCopy.loadState(item.loadState)) }
                    }
                    if let name = StartupCopy.signerName(item.signer) { field(StartupCopy.fieldSigner) { Text(name) } }
                    field(StartupCopy.fieldModified) { Text(Formatting.absolute(item.lastModified)) }
                    actions(item)
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(StartupCopy.inspectorEmpty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func explanation(_ item: StartupItem) -> String {
        item.isRemovable ? StartupCopy.explainBroken(item.program ?? item.displayName) : StartupCopy.explainSystem
    }

    private func actions(_ item: StartupItem) -> some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
            Button(StartupCopy.revealPlist) { model.revealPlist(item) }
            if item.programState == .present { Button(StartupCopy.revealProgram) { model.revealProgram(item) } }
            if item.label != nil { Button(StartupCopy.copyLabel) { model.copyLabel(item) } }
            if item.isHomebrewService, item.label != nil { Button(StartupCopy.copyCommand) { model.copyBrewCommand(item) } }
        }
    }

    private func field<V: View>(_ title: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.adkText3)
            value()
        }
    }
}
