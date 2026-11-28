import Foundation
import IOKit.ps

/// Reads the power state behind a protocol, so tests never depend on the machine they run on.
public protocol PowerSourceReading: Sendable {
    func read() -> (onBattery: Bool, lowPowerMode: Bool)
}

public struct LivePowerSource: PowerSourceReading {
    public init() {}

    public func read() -> (onBattery: Bool, lowPowerMode: Bool) {
        var onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            onBattery = type == kIOPSBatteryPowerValue
        }
        return (onBattery, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
