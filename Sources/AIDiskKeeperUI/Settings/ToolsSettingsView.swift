import SwiftUI

struct ToolsSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            if model.allToolsDisabled {
                Label("Nothing will be scanned.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(model.availableTools) { tool in
                Toggle(tool.name, isOn: Binding(get: { model.isEnabled(tool.id) },
                                                set: { model.setTool(tool.id, enabled: $0) }))
            }
            Text("Changes apply to the next scan.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
