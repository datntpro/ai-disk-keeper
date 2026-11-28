import AppKit
import DiskKeeperCore
import SwiftUI

struct StorageView: View {
    let model: StorageModel
    let trashURL: URL

    static let timeMachineSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var header: some View {
        HStack(spacing: ADKTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                Text(loc("storage.title", "Storage")).font(.headline)
                if let o = model.overview {
                    Text(subtitle(o.dataVolume)).font(.caption).foregroundStyle(.adkText3)
                }
            }
            Spacer()
            if let measured = model.lastRefreshed {
                Text(loc("storage.measured", "Measured \(Formatting.relative(measured))")).font(.caption).foregroundStyle(.adkText3)
            }
            Button { model.refresh(force: true) } label: { Label(loc("storage.refresh", "Refresh"), systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.phase == .loading)
        }
        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.md)
    }

    private func subtitle(_ v: VolumeInfo) -> String {
        [model.volumeName, v.fileSystem?.uppercased(),
         v.isInternal.map { $0 ? loc("storage.internal", "internal") : loc("storage.external", "external") }].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if let overview = model.overview {
            ScrollView {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.lg) {
                    if case .failed = model.phase, let at = model.lastRefreshed {
                        Label(loc("storage.stale", "Couldn't refresh — showing values from \(Formatting.relative(at))"),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.adkReviewInk)
                    }
                    StorageCapacityCard(model: model)
                    StorageSSDCard(model: model.ssdHealth)
                    StorageExplainCard()
                    StorageSnapshotsCard(listing: overview.snapshots, openTimeMachine: {
                        NSWorkspace.shared.open(Self.timeMachineSettingsURL)
                    })
                    StorageTrashCard(trash: overview.trash, openTrash: { NSWorkspace.shared.open(trashURL) },
                                     grantAccess: { NSWorkspace.shared.open(SystemSettingsLinks.fullDiskAccess) })
                }
                .padding(ADKTheme.Spacing.lg)
            }
        } else if case .failed(let reason) = model.phase {
            StateView(kind: .error, symbol: "exclamationmark.triangle", title: loc("storage.failed.title", "Couldn't read storage"),
                      message: loc("storage.failed.body", "Nothing was changed. \(reason)"),
                      actions: [StateAction(title: loc("storage.retry", "Try again")) { model.refresh(force: true) }])
        } else {
            StateView(kind: .progress(nil), symbol: "internaldrive", title: loc("storage.title", "Storage"),
                      message: loc("storage.loading", "Measuring storage…"))
        }
    }
}
