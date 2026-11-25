import SwiftUI

public struct SettingsView: View {
    let model: SettingsModel

    public init(model: SettingsModel) { self.model = model }

    public var body: some View {
        TabView {
            GeneralSettingsView(model: model).tabItem { Label("General", systemImage: "gearshape") }
            ScanScopeSettingsView(model: model).tabItem { Label("Scan scope", systemImage: "folder.badge.gearshape") }
            ToolsSettingsView(model: model).tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 420)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
        .alert("Settings", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK") { model.clearError() }
        } message: { Text(model.lastError ?? "") }
    }
}
