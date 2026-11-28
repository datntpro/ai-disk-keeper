import DiskKeeperCore
import SwiftUI

struct RulesSettingsView: View {
    let model: SettingsModel
    @State private var rules: RulesSettingsModel

    init(model: SettingsModel) {
        self.model = model
        _rules = State(initialValue: RulesSettingsModel.live(environment: model.environment))
    }

    var body: some View {
        Form {
            if model.userPolicyUnreadable {
                Section {
                    Label(loc("rules.policy.unreadable", "Your settings file couldn't be read, so your Keep and hidden-item choices are unknown. Nothing is cleaned until you continue."),
                          systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                    Button(loc("rules.policy.continue", "Continue with empty rules")) { model.acknowledgeUnreadablePolicy() }
                }
            }
            if model.userPolicySaveFailed {
                Section {
                    Label(loc("rules.policy.saveFailed", "Your last rules change couldn't be saved. It applies until you quit the app."),
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section {
                Toggle(loc("settings.rules.enabled", "Read my own rule files"),
                       isOn: Binding(get: { model.settings.userRulesEnabled }, set: { model.setUserRulesEnabled($0) }))
                Text(loc("settings.rules.capNote", "Your rules can add items at Review at most; Safe is only for the built-in rules, and protected folders stay protected."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(loc("settings.rules.openFolder", "Open rules folder")) { rules.openRulesFolder() }
                    Button(loc("settings.rules.reload", "Reload rules")) { Task { await rules.reload() } }
                    Button(loc("settings.rules.validate", "Validate")) { Task { await rules.validate() } }
                }
                if let e = rules.folderError { Text(e).font(.caption).foregroundStyle(.red) }
                if let s = rules.validationSummary { Text(s).font(.callout) }
            }
            if !rules.problems.isEmpty {
                Section(loc("settings.rules.problems", "Problems")) {
                    ForEach(rules.problems) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(p.file.isEmpty ? p.message : p.file,
                                  systemImage: p.isWarning ? "exclamationmark.triangle" : "xmark.octagon")
                                .foregroundStyle(p.isWarning ? .orange : .red)
                            if !p.jsonPath.isEmpty { Text(verbatim: p.jsonPath).font(.caption.monospaced()) }
                            if !p.file.isEmpty { Text(verbatim: p.message).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section(loc("settings.rules.files", "Rule files")) {
                if rules.files.isEmpty {
                    Text(loc("settings.rules.none", "No rule files loaded yet. Press Reload rules.")).foregroundStyle(.secondary)
                }
                ForEach(rules.files) { f in
                    DisclosureGroup {
                        ForEach(f.rules) { r in
                            Toggle(isOn: Binding(get: { !model.isRuleDisabled(r.id) },
                                                 set: { model.setRule(r.id, disabled: !$0) })) {
                                // Rule text is the author's own: shown as written, never translated.
                                Text(verbatim: r.title)
                            }
                        }
                    } label: {
                        HStack {
                            Text(verbatim: f.file.lastPathComponent)
                            Text(f.source == .bundled ? loc("settings.rules.bundled", "Built in")
                                                      : loc("settings.rules.yours", "Yours"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section(loc("settings.rules.ignored", "Ignored items")) {
                if model.settings.ignoredItemIDs.isEmpty {
                    Text(loc("settings.rules.ignored.none", "Nothing is hidden.")).foregroundStyle(.secondary)
                }
                ForEach(model.settings.ignoredItemIDs.sorted(), id: \.self) { id in
                    HStack {
                        Text(verbatim: id).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(loc("settings.rules.remove", "Remove")) { model.unignoreItem(id) }
                    }
                }
            }
            Section(loc("settings.rules.overrides", "Overrides")) {
                if model.settings.tierOverrides.isEmpty {
                    Text(loc("settings.rules.overrides.none", "No tier overrides.")).foregroundStyle(.secondary)
                }
                ForEach(model.settings.tierOverrides.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(verbatim: key).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(model.settings.tierOverrides[key].map { TierStyle.style(for: $0).label } ?? "").foregroundStyle(.secondary)
                        Button(loc("settings.rules.reset", "Reset")) { model.resetOverride(key) }
                    }
                }
            }
            Text(loc("settings.changesApplyNextScan", "Changes apply to the next scan.")).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)   // scrolls: the file list is long and everything below it must stay reachable
        .task { await rules.reload() }
    }
}
