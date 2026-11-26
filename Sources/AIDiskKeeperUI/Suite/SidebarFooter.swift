import AppKit
import SwiftUI

/// The volume gauge under the sidebar list. It also keeps the shared volume model fresh: on first show, when the
/// app becomes active, and when a cleanup finishes (the Trash and free space changed).
struct SidebarFooter: View {
    let ctx: ModuleContext

    var body: some View {
        let model = StorageModule.model(ctx)
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                StorageGauge(model: model) { ctx.suite.navigation.selection = SidebarSelection(module: .storage) }
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                SettingsGearButton()
            }
        }
        .task { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onChange(of: cleanupFinished) { _, finished in if finished { model.noteCleanupFinished() } }
    }

    private var cleanupFinished: Bool {
        if case .finished? = ctx.suite.cleanup.flow?.state { true } else { false }
    }
}

/// Opens the Settings window (same as ⌘,). A real control, so it is reachable by keyboard and VoiceOver.
struct SettingsGearButton: View {
    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .imageScale(.medium)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.adkText2)
        .padding(.trailing, ADKTheme.Spacing.md)
        .help(Self.title)
        .accessibilityLabel(Self.title)
    }

    static var title: String { loc("sidebar.settings", "Settings") }
}
