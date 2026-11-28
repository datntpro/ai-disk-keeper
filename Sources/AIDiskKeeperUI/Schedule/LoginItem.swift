import Foundation
import ServiceManagement

/// "Open at login" for the scheduled scans. `SMAppService.mainApp` only: no LaunchAgent, no helper (T22).
@MainActor
protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ on: Bool) throws
}

enum LoginItemStatus: Equatable {
    case off, enabled, requiresApproval, unavailable
}

@MainActor
final class LiveLoginItem: LoginItemControlling {
    /// `swift run` has no bundle, where registering is meaningless.
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    var status: LoginItemStatus {
        guard available else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .off
        }
    }

    func setEnabled(_ on: Bool) throws {
        guard available else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
