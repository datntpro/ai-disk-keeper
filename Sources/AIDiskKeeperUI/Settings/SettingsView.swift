import SwiftUI

public struct SettingsView: View {
    let model: SettingsModel

    public init(model: SettingsModel) { self.model = model }

    public var body: some View {
        TabView {
            GeneralSettingsView(model: model).tabItem { Label(loc("settings.tab.general", "General"), systemImage: "gearshape") }
            ScanScopeSettingsView(model: model).tabItem { Label(loc("settings.tab.scope", "Scan scope"), systemImage: "folder.badge.gearshape") }
            ToolsSettingsView(model: model).tabItem { Label(loc("settings.tab.tools", "Tools"), systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 420)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
        .alert(loc("settings.alert.title", "Settings"), isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.clearError() } })) {
            Button(loc("common.ok", "OK")) { model.clearError() }
        } message: { Text(model.lastError ?? "") }
    }
}
