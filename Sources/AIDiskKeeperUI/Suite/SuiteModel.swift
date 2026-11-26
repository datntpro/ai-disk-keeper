import Observation

/// Window-wide services shared by every module. Lives in `RootView` outside the language identity, so a
/// language switch or a module switch never drops the index.
@MainActor @Observable
public final class SuiteModel {
    public let diskIndex: DiskIndexModel
    public let cleanup: CleanupCoordinator
    public let navigation: NavigationModel
    @ObservationIgnored private var moduleStates: [ModuleID: AnyObject] = [:]

    public init(diskIndex: DiskIndexModel, cleanup: CleanupCoordinator, navigation: NavigationModel = NavigationModel()) {
        self.diskIndex = diskIndex
        self.cleanup = cleanup
        self.navigation = navigation
    }

    public convenience init(env: AppEnvironment) {
        let settings = env.settings
        self.init(
            diskIndex: DiskIndexModel(makeIndexer: env.makeDiskIndexer,
                                      fullDiskAccess: { settings.fdaStatus == .granted }),
            cleanup: CleanupCoordinator(holder: env.cleanup))
    }

    /// Per-module model store: the first call creates the model, later calls return the same one.
    public func state<T: AnyObject>(_ id: ModuleID, make: () -> T) -> T {
        if let existing = moduleStates[id] as? T { return existing }
        let created = make()
        moduleStates[id] = created
        return created
    }
}
