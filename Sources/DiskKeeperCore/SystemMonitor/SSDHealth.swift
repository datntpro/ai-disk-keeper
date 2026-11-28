import CNVMeSMART
import Foundation

/// The drive's own health report (NVMe SMART / Health page). Read-only; the serial number is not part of it and is never read.
public struct SSDHealth: Sendable, Equatable {
    public let criticalWarning: UInt8
    /// nil when the page reports 0 K (unknown) or a value outside 1...1000 K.
    public let temperatureCelsius: Int?
    public let availableSparePercent: Int
    public let spareThresholdPercent: Int
    /// The controller's own endurance estimate ("Percentage Used"). Whole percent; may exceed 100.
    public let percentageUsed: Int
    /// Host data written / read over the drive's life, in bytes (1 data unit = 1000 × 512 B). Saturates at `UInt64.max`.
    public let bytesWritten: UInt64
    public let bytesRead: UInt64
    public let powerCycles: UInt64
    public let powerOnHours: UInt64
    public let unsafeShutdowns: UInt64
    public let mediaErrors: UInt64

    /// A reading above this wear estimate is shown as a warning.
    public static let wearWarningPercent = 80

    /// True when the drive reports a critical warning, spare below its threshold, or wear at 80 % or more.
    public var needsAttention: Bool {
        criticalWarning != 0 || availableSparePercent < spareThresholdPercent || percentageUsed >= Self.wearWarningPercent
    }

    /// True when `bytesWritten` hit the 64-bit ceiling (the page's 128-bit counter was larger than that).
    public var bytesWrittenSaturated: Bool { bytesWritten == UInt64.max }

    public init(criticalWarning: UInt8, temperatureCelsius: Int?, availableSparePercent: Int, spareThresholdPercent: Int,
                percentageUsed: Int, bytesWritten: UInt64, bytesRead: UInt64, powerCycles: UInt64, powerOnHours: UInt64,
                unsafeShutdowns: UInt64, mediaErrors: UInt64) {
        self.criticalWarning = criticalWarning; self.temperatureCelsius = temperatureCelsius
        self.availableSparePercent = availableSparePercent; self.spareThresholdPercent = spareThresholdPercent
        self.percentageUsed = percentageUsed; self.bytesWritten = bytesWritten; self.bytesRead = bytesRead
        self.powerCycles = powerCycles; self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns; self.mediaErrors = mediaErrors
    }

    /// Parses the packed 512-byte page. Pure, so a recorded page tests it. Wrong size → nil.
    public init?(page: [UInt8]) {
        guard page.count == Int(ADK_NVME_SMART_PAGE_SIZE) else { return nil }
        /// A 128-bit little-endian counter; anything above `UInt64.max` saturates.
        func counter(_ offset: Int) -> UInt64 {
            if page[(offset + 8)..<(offset + 16)].contains(where: { $0 != 0 }) { return .max }
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(page[offset + $1]) << (8 * UInt64($1)) }
        }
        func bytes(_ units: UInt64) -> UInt64 {
            let (product, overflow) = units.multipliedReportingOverflow(by: 512_000)
            return overflow ? .max : product
        }
        let kelvin = Int(page[1]) | Int(page[2]) << 8
        let celsius: Int? = (1...1000).contains(kelvin) ? Int((Double(kelvin) - 273.15).rounded()) : nil
        self.init(criticalWarning: page[0], temperatureCelsius: celsius, availableSparePercent: Int(page[3]),
                  spareThresholdPercent: Int(page[4]), percentageUsed: Int(page[5]),
                  bytesWritten: bytes(counter(48)), bytesRead: bytes(counter(32)),
                  powerCycles: counter(112), powerOnHours: counter(128), unsafeShutdowns: counter(144), mediaErrors: counter(160))
    }
}

/// Reads the raw page. A protocol so tests use a fake and never touch the device.
public protocol SSDHealthReading: Sendable {
    /// nil = this disk doesn't report health data (virtual disk, external enclosure, read refused).
    func read() -> SSDHealth?
}

/// IOKit, through the `CNVMeSMART` shim: `SMARTReadData` only. No subprocess, no root, no writes to the device.
public struct LiveSSDHealthReader: SSDHealthReading {
    public init() {}

    public func read() -> SSDHealth? {
        var page = [UInt8](repeating: 0, count: Int(ADK_NVME_SMART_PAGE_SIZE))
        let status = page.withUnsafeMutableBufferPointer { adk_nvme_smart_read($0.baseAddress!) }
        guard status == 0 else { return nil }
        return SSDHealth(page: page)
    }
}
