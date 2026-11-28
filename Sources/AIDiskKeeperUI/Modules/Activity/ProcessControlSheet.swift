import DiskKeeperCore
import SwiftUI

/// Confirmation sheet: what will happen to which processes, what is refused and why, and the warnings.
/// Cancel is the default button for pause; the confirmation is the default for lowering priority.
struct ProcessControlConfirmSheet: View {
    let model: ProcessControlModel

    var body: some View {
        if let plan = model.plan {
            VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                Text(ProcessControlCopy.title(plan.action)).font(.title3.weight(.semibold))
                if plan.action == .pause || plan.action == .background {
                    Toggle(ProcessControlCopy.includeChildren, isOn: Binding(
                        get: { model.includeDescendants }, set: { on in Task { await model.setIncludeDescendants(on) } }))
                }
                rows(plan)
                if plan.actionable.isEmpty {
                    Label(ProcessControlCopy.noneAllowed, systemImage: "hand.raised").foregroundStyle(.adkText2)
                }
                notes(plan.action)
                HStack {
                    Spacer()
                    Button(ProcessControlCopy.cancel) { model.cancel() }
                        .keyboardShortcut(plan.action == .pause ? .defaultAction : .cancelAction)
                    Button(ProcessControlCopy.confirm(plan.action)) { Task { await model.confirm() } }
                        .keyboardShortcut(plan.action == .pause ? nil : .defaultAction)
                        .disabled(plan.actionable.isEmpty)
                }
            }
            .padding(ADKTheme.Spacing.lg)
            .frame(width: 520)
        }
    }

    private func rows(_ plan: ProcessControlPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.rows) { row in
                    HStack {
                        Text(verbatim: "\(row.target.name) (\(row.target.pid))").lineLimit(1)
                            .padding(.leading, row.isRoot ? 0 : 16)
                        Spacer()
                        if let why = row.refusal {
                            Text(ProcessControlCopy.refusal(why)).font(.caption).foregroundStyle(.adkReviewInk)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text(ProcessControlCopy.okRow).font(.caption).foregroundStyle(.adkText2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    @ViewBuilder private func notes(_ action: ProcessAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch action {
            case .pause:
                Text(ProcessControlCopy.autoResume(model.autoResumeMinutes))
                Text(ProcessControlCopy.warnTimeout)
                Text(ProcessControlCopy.warnGitLock)
            case .background:
                Text(ProcessControlCopy.backgroundNote)
                Toggle(ProcessControlCopy.keepChildren, isOn: Binding(
                    get: { model.keepChildrenInBackground }, set: { model.keepChildrenInBackground = $0 }))
            default: EmptyView()
            }
            Text(ProcessControlCopy.warnNothingKilled)
        }
        .font(.callout).foregroundStyle(.adkText2).fixedSize(horizontal: false, vertical: true)
    }
}

/// Launch-time recovery: processes still stopped from a previous run (the app quit unexpectedly).
struct ProcessRecoverySheet: View {
    let model: ProcessControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
            Text(ProcessControlCopy.recoveryTitle).font(.title3.weight(.semibold))
            Text(ProcessControlCopy.recoveryMessage).foregroundStyle(.adkText2).fixedSize(horizontal: false, vertical: true)
            ForEach(model.recovery, id: \.key) { entry in
                Text(verbatim: "\(entry.name) (\(entry.pid))")
            }
            HStack {
                Spacer()
                Button(ProcessControlCopy.recoveryLeave) { Task { await model.recoveryLeave() } }
                Button(ProcessControlCopy.recoveryResume) { Task { await model.recoveryResumeAll() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ADKTheme.Spacing.lg)
        .frame(width: 440)
    }
}

extension ProcessControlPlanRow: Identifiable { public var id: ProcessTarget { target } }
