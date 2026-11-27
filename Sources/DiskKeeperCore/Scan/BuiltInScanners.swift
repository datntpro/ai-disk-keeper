import Foundation

/// Scanners beyond the rule scanner that the app ships with. Empty until a tool scanner (Docker, simctl) lands;
/// each adds one line here.
public enum BuiltInScanners {
    public static func live(environment: PathEnvironment) -> [any Scanner] {
        [
            DockerScanner(layout: { DockerRuntimeLayout.live(environment: $0) }),
            UnavailableSimulatorScanner.live(environment: environment),
            DerivedDataScanner.live(environment: environment),
        ]
    }
}
