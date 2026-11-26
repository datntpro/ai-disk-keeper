import Darwin
import Foundation
import SystemConfiguration

public struct InterfaceCounters: Sendable, Equatable {
    public var name: String
    public var inBytes: UInt32
    public var outBytes: UInt32
    public init(name: String, inBytes: UInt32, outBytes: UInt32) { self.name = name; self.inBytes = inBytes; self.outBytes = outBytes }
}

public enum NetworkMath {
    /// VPN tunnels and virtual links would double-count real traffic.
    public static let excludedPrefixes = ["lo", "utun", "ipsec", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi", "vmenet"]
    /// Anything above this per second is a counter reset, not traffic.
    public static let maxPlausibleBytesPerSecond = 10_000_000_000.0

    public static func isCounted(_ name: String) -> Bool { !excludedPrefixes.contains { name.hasPrefix($0) } }

    public struct Rate: Equatable, Sendable { public var down: Double, up: Double, busiest: String? }

    /// nil = discard this tick (interface set changed, a counter reset, or no time passed); keep the new counters.
    public static func rate(previous: [InterfaceCounters], current: [InterfaceCounters], seconds: Double) -> Rate? {
        guard seconds > 0, Set(previous.map(\.name)) == Set(current.map(\.name)) else { return nil }
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, $0) })
        var down = 0.0, up = 0.0, busiest: (String, Double)?
        for c in current {
            guard let p = before[c.name] else { return nil }
            let d = Double(c.inBytes &- p.inBytes), u = Double(c.outBytes &- p.outBytes)
            guard d / seconds <= maxPlausibleBytesPerSecond, u / seconds <= maxPlausibleBytesPerSecond else { return nil }
            down += d; up += u
            if busiest == nil || d + u > busiest!.1 { busiest = (c.name, d + u) }
        }
        return Rate(down: down / seconds, up: up / seconds, busiest: busiest?.0)
    }
}

public struct LiveNetworkSampler: NetworkSampling {
    private var previous: [InterfaceCounters]?
    private var previousAt: ContinuousClock.Instant?
    private var displayNames: [String: String] = [:]
    private var knownSet: Set<String> = []

    public init() {}

    public mutating func sample() -> SampleResult<NetworkReading> {
        guard let current = Self.read() else { return .failed }
        let now = ContinuousClock.now
        defer { previous = current; previousAt = now }
        let names = Set(current.map(\.name))
        if names != knownSet { knownSet = names; displayNames = Self.localizedNames() }   // cached until the set changes
        guard let previous, let previousAt else { return .pending }
        let d = now - previousAt
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        guard let r = NetworkMath.rate(previous: previous, current: current, seconds: seconds) else { return .pending }
        return .value(NetworkReading(down: r.down, up: r.up, interfaceName: r.busiest,
                                     interfaceDisplayName: r.busiest.flatMap { displayNames[$0] }))
    }

    private static func read() -> [InterfaceCounters]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var out: [InterfaceCounters] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard NetworkMath.isCounted(name) else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            out.append(InterfaceCounters(name: name, inBytes: d.ifi_ibytes, outBytes: d.ifi_obytes))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func localizedNames() -> [String: String] {
        var m: [String: String] = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(i) as String?, let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? { m[bsd] = n }
        }
        return m
    }
}
