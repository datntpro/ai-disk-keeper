import CoreServices
import Foundation

public protocol AppUsageProviding: Sendable {
    func lastUsedDate(ofBundleAt path: String) -> Date?
}

/// Spotlight's `kMDItemLastUsedDate`. nil when Spotlight has no record (never used or indexing off).
public struct SpotlightUsageProvider: AppUsageProviding {
    public init() {}

    public func lastUsedDate(ofBundleAt path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
