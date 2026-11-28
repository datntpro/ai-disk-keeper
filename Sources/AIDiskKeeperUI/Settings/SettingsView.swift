import SwiftUI

public struct SettingsView: View {
    let model: SettingsModel
    @State private var tab = Tab.general

    private enum Tab: Hashable { case general, scope, tools, rules, menuBar, schedule }

    public init(model: SettingsModel) { self.model = model }

    public var body: some View {
        content
            .id(model.languageRevision)
            .environment(\.locale, L10n.locale)
    }

    private var content: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model).tag(Tab.general)
                .tabItem { Label(loc("settings.tab.general", "General"), systemImage: "gearshape") }
            ScanScopeSettingsView(model: model).tag(Tab.scope)
                .tabItem { Label(loc("settings.tab.scope", "Scan scope"), systemImage: "folder.badge.gearshape") }
            ToolsSettingsView(model: model).tag(Tab.tools)
                .tabItem { Label(loc("settings.tab.tools", "Tools"), systemImage: "wrench.and.screwdriver") }
            RulesSettingsView(model: model).tag(Tab.rules)
                .tabItem { Label(loc("settings.rules.tab", "Rules"), systemImage: "list.bullet.rectangle") }
            MenuBarSettingsView(model: model).tag(Tab.menuBar)
                .tabItem { Label(loc("settings.tab.menubar", "Menu bar"), systemImage: "menubar.rectangle") }
            ScheduleSettingsView(model: model).tag(Tab.schedule)
                .tabItem { Label(loc("settings.schedule.tab", "Schedule"), systemImage: "calendar.badge.clock") }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
        .alert(loc("settings.alert.title", "Settings"), isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.clearError() } })) {
            Button(loc("common.ok", "OK")) { model.clearError() }
        } message: { Text(model.lastError ?? "") }
    }
}
