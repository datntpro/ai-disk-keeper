import AppKit
import DiskKeeperCore
import SwiftUI

struct UninstallerView: View {
    @Bindable var model: UninstallerModel
    let coordinator: CleanupCoordinator
    private let launched = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
    private let terminated = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { model.load() }
        .onReceive(launched) { _ in model.refreshRunning() }
        .onReceive(terminated) { _ in model.refreshRunning() }
    }

    private var header: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(UninstallerCopy.title).font(.headline)
                if model.phase == .ready {
                    Text(UninstallerCopy.subtitle(apps: Formatting.count(model.apps.count), unused: Formatting.count(model.unusedCount)))
                        .font(.caption).foregroundStyle(.adkText3)
                }
            }
            Spacer()
            Picker(UninstallerCopy.title, selection: $model.tab) {
                Text(UninstallerCopy.tabApps).tag(UninstallerModel.Tab.apps)
                Text(UninstallerCopy.tabOrphans(Formatting.bytes(model.orphanBytes))).tag(UninstallerModel.Tab.orphans)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            StateView(kind: .progress(nil), symbol: "xmark.app", title: UninstallerCopy.title, message: UninstallerCopy.loading)
        case .failed:
            StateView(kind: .error, symbol: "exclamationmark.triangle", title: UninstallerCopy.failedTitle, message: UninstallerCopy.failed,
                      actions: [StateAction(title: UninstallerCopy.retry) { model.load() }])
        case .ready:
            if model.tab == .orphans {
                UninstallOrphansView(model: model, coordinator: coordinator)
            } else if model.apps.isEmpty {
                StateView(kind: .empty, symbol: "xmark.app", title: UninstallerCopy.emptyTitle, message: UninstallerCopy.emptyMessage)
            } else {
                HSplitView {
                    UninstallAppList(model: model).frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                    detail.frame(minWidth: 380, maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            UninstallAppDetail(app: app, model: model, coordinator: coordinator)
        } else {
            StateView(kind: .empty, symbol: "xmark.app", title: UninstallerCopy.title, message: UninstallerCopy.selectApp)
        }
    }
}
