import AppKit
import SwiftUI

/// The volume gauge under the sidebar list. It also keeps the shared volume model fresh: on first show, when the
/// app becomes active, and when a cleanup finishes (the Trash and free space changed).
struct SidebarFooter: View {
    let ctx: ModuleContext

    var body: some View {
        let model = StorageModule.model(ctx)
        VStack(spacing: 0) {
            if model.overview != nil { Divider() }
            StorageGauge(model: model) { ctx.suite.navigation.selection = SidebarSelection(module: .storage) }
        }
        .task { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onChange(of: cleanupFinished) { _, finished in if finished { model.noteCleanupFinished() } }
    }

    private var cleanupFinished: Bool {
        if case .finished? = ctx.suite.cleanup.flow?.state { true } else { false }
    }
}
