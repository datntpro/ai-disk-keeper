import Foundation

/// Scanners beyond the rule scanner that the app ships with. Empty until a tool scanner (Docker, simctl) lands;
/// each adds one line here.
public enum BuiltInScanners {
    public static func live(environment: PathEnvironment) -> [any Scanner] { [] }
}
