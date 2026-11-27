import DiskKeeperCore
import SwiftUI

/// Settings → General: the status file toggle and the command-line tool install.
struct HostStatusSettingsSection: View {
    let model: SettingsModel
    let status: HostStatusSettingsModel

    var body: some View {
        Section {
            Toggle(loc("hoststatus.toggle", "Publish machine status for coding agents"), isOn: Binding(
                get: { model.settings.publishHostStatus }, set: { model.setPublishHostStatus($0) }))
            Text(loc("hoststatus.help", "Writes disk space, disk writes and load to a small file every 30 seconds while the app runs, so coding agents can check it with the adk command. No command lines or file contents are included."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent(loc("hoststatus.file", "Status file")) {
                HStack {
                    Text(verbatim: status.statusFileURL.path).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button(loc("hoststatus.reveal", "Reveal")) { status.reveal() }
                }
            }
            HStack {
                if status.state == .installed {
                    Button(loc("hoststatus.remove", "Remove command-line tool")) { status.remove() }
                } else {
                    Button(loc("hoststatus.install", "Install command-line tool…")) { status.install() }
                        .disabled(!status.canInstall || status.state == .foreign)
                }
                Text(verbatim: status.linkPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if status.needsPathHint {
                Text(loc("hoststatus.pathHint", "If the adk command is not found, add \(status.directory) to your PATH"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = status.foreignMessage ?? status.errorMessage {
                Text(verbatim: message).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { status.refresh() }
    }
}
