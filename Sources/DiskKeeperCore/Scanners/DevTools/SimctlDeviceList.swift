import Foundation

/// One simulator device from `simctl list devices unavailable --json`.
public struct SimctlDevice: Sendable, Hashable {
    public let udid: String
    public let name: String
    /// For example `com.apple.CoreSimulator.SimRuntime.iOS-17-5`.
    public let runtimeID: String
    public let isAvailable: Bool
    public let dataPath: String?
    public let state: String?

    public var isBooted: Bool { state?.lowercased() == "booted" }

    /// "iOS 17.5" from `com.apple.CoreSimulator.SimRuntime.iOS-17-5`; the raw id's last part when it doesn't parse.
    public var runtimeShortName: String {
        let last = runtimeID.split(separator: ".").last.map(String.init) ?? runtimeID
        let parts = last.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return last }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }
}

/// Pure decoding of the `simctl` device list. Lenient: a record with a missing required key is skipped, unknown
/// keys are ignored; a document that is not the expected shape is an error.
public enum SimctlDeviceList {
    public enum ParseError: Error, Sendable, Hashable { case notJSON, noDevicesKey }

    public static func parse(_ data: Data) throws -> [SimctlDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        guard let runtimes = root["devices"] as? [String: Any] else { throw ParseError.noDevicesKey }
        var out: [SimctlDevice] = []
        for runtime in runtimes.keys.sorted() {
            guard let list = runtimes[runtime] as? [[String: Any]] else { continue }
            for d in list {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                out.append(SimctlDevice(udid: udid, name: name, runtimeID: runtime,
                                        isAvailable: d["isAvailable"] as? Bool ?? false,
                                        dataPath: d["dataPath"] as? String, state: d["state"] as? String))
            }
        }
        return out
    }
}
