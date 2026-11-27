import AppKit
import DiskKeeperCore
import Foundation

/// Writes `status.json` every 30 s while the app runs and "Publish machine status for coding agents" is on (D10).
/// It owns its own `HostLoadSampler`, so the 5 s Disk Activity screen and this 30 s tick never split each other's
/// rate windows. No daemon, no socket: when the app quits, the last write says `running: false`.
@MainActor
final class HostStatusPublisher {
    static let interval: Duration = .seconds(30)
    /// The first status comes after one short window, so it already has rates.
    static let primeInterval: Duration = .seconds(5)

    private let settings: SettingsModel
    private let writer: HostStatusWriter
    private let sampler: HostLoadSampler
    private var composer: HostStatusComposer
    private let sleeper: @Sendable (Duration) async -> Void
    private let observeTermination: Bool
    private var loop: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var lastTick: ContinuousClock.Instant?
    private(set) var started = false

    init(settings: SettingsModel, writer: HostStatusWriter, sampler: HostLoadSampler, composer: HostStatusComposer,
         observeTermination: Bool = true,
         sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0, tolerance: $0 / 5) }) {
        self.settings = settings
        self.writer = writer
        self.sampler = sampler
        self.composer = composer
        self.observeTermination = observeTermination
        self.sleeper = sleeper
    }

    /// The real wiring: its own sampler (free space from the Data volume + the saved history's trend), the status file in App Support.
    static func make(env: AppEnvironment) -> HostStatusPublisher {
        let store = FreeSpaceHistoryStore(fileURL: FreeSpaceHistoryStore.defaultFileURL(environment: env.pathEnvironment))
        let sampler = HostLoadSampler(
            attribution: WorktreeAttribution(home: env.pathEnvironment.home),
            freeSpace: {
                guard let c = VolumeCapacity.live() else { return nil }
                // The threshold is applied by the policy, which reads the setting; this only carries bytes and the trend.
                return FreeSpaceStatus(freeBytes: c.free, totalBytes: c.total, thresholdPercent: AppSettings.defaultLowSpaceThresholdPercent,
                                       trend: FreeSpaceTrend.estimate(store.load().points, now: Date()))
            })
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return HostStatusPublisher(
            settings: env.settings, writer: HostStatusWriter(fileURL: HostStatusWriter.defaultFileURL(environment: env.pathEnvironment)),
            sampler: sampler, composer: HostStatusComposer(version: version))
    }

    var isPublishing: Bool { loop != nil }
    var statusFileURL: URL { writer.fileURL }

    func start() {
        guard !started else { return }
        started = true
        if observeTermination {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [writer] _ in
                writer.markStopped()
            }
        }
        apply()
        observeSettings()
    }

    func stop() {
        started = false
        loop?.cancel(); loop = nil
        if let o = terminationObserver { NotificationCenter.default.removeObserver(o); terminationObserver = nil }
    }

    /// The setting decides: on starts the loop, off stops it and deletes the file.
    func apply() {
        if settings.settings.publishHostStatus {
            guard loop == nil else { return }
            loop = Task { [weak self] in await self?.run() }
        } else {
            loop?.cancel(); loop = nil
            lastTick = nil
            writer.remove()
        }
    }

    private func run() async {
        _ = await sampler.tick()   // primes the rate counters
        lastTick = .now
        await sleeper(Self.primeInterval)
        while !Task.isCancelled {
            await publishOnce()
            await sleeper(Self.interval)
        }
    }

    /// One sample → one write. A failed write is dropped; the next tick tries again (readers then see "stale").
    func publishOnce() async {
        let snap = await sampler.tick()
        guard !Task.isCancelled, settings.settings.publishHostStatus else { return }
        let now = ContinuousClock.now
        let seconds = lastTick.map { Double((now - $0).components.seconds) + Double((now - $0).components.attoseconds) / 1e18 } ?? 0
        lastTick = now
        let status = composer.compose(snap, thresholdPercent: settings.settings.lowSpaceThresholdPercent, sampleSeconds: (seconds * 10).rounded() / 10)
        try? writer.write(status)
    }

    private func observeSettings() {
        withObservationTracking { _ = settings.settings.publishHostStatus } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.apply()
                self.observeSettings()
            }
        }
    }
}

/// What the General settings section reads and does: the file's place and the command-line install.
@MainActor @Observable
final class HostStatusSettingsModel {
    let statusFileURL: URL
    private let installer: CLIInstaller
    private(set) var state: CLIInstaller.State
    private(set) var errorMessage: String?

    init(statusFileURL: URL, installer: CLIInstaller) {
        self.statusFileURL = statusFileURL
        self.installer = installer
        self.state = installer.state
    }

    /// The real app: the status file in Application Support, and the `adk` next to the app's own executable.
    static func live(environment: PathEnvironment) -> HostStatusSettingsModel {
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/adk")
        return HostStatusSettingsModel(statusFileURL: HostStatusWriter.defaultFileURL(environment: environment),
                                       installer: CLIInstaller(home: environment.home, binary: binary))
    }

    var canInstall: Bool { installer.binaryExists }
    var linkPath: String { installer.linkPath }
    /// Shown after an install when `~/.local/bin` is not on the PATH.
    var needsPathHint: Bool { state == .installed }
    var directory: String { installer.directory }

    /// Shown up front when something else already sits at the link path.
    var foreignMessage: String? { state == .foreign ? Self.message(CLIInstaller.InstallError.occupied(installer.linkPath)) : nil }

    func install() {
        do { try installer.install(); errorMessage = nil } catch { errorMessage = Self.message(error) }
        state = installer.state
    }

    func remove() {
        do { try installer.remove(); errorMessage = nil } catch { errorMessage = Self.message(error) }
        state = installer.state
    }

    func refresh() { state = installer.state }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([statusFileURL])
    }

    private static func message(_ error: Error) -> String {
        if case CLIInstaller.InstallError.occupied(let p) = error { return loc("hoststatus.error.occupied", "\(p) already exists and is not ours.") }
        if case CLIInstaller.InstallError.binaryMissing = error { return loc("hoststatus.error.noBinary", "This build has no command-line tool.") }
        return error.localizedDescription
    }
}
