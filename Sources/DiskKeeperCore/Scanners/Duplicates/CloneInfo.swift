import Darwin
import Foundation

/// What APFS says about how a file's blocks are shared (clones, hard links). See docs/duplicates.md §1.
public enum CloneInfo: Sendable, Hashable {
    /// The attributes were not returned (non-APFS volume, old volume, error). Treated as "may share".
    case unknown
    case known(cloneID: UInt64, refCount: UInt32, privateBytes: Int64, sharesAllBlocks: Bool, maySharesBlocks: Bool)
}

enum CloneProbe {
    // sys/attr.h and sys/stat.h (not all of them are imported into Swift).
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let extPrivateSize: UInt32 = 0x0000_0008
    static let extCloneID: UInt32 = 0x0000_0100
    static let extFlags: UInt32 = 0x0000_0200
    static let extCloneRefCount: UInt32 = 0x0000_1000
    static let fsoptNoFollow: UInt32 = 0x0000_0001
    static let fsoptCmnExtended: UInt32 = 0x0000_0020
    static let efMayShareBlocks: UInt64 = 0x1
    static let efSharesAllBlocks: UInt64 = 0x40

    /// One `getattrlist` per file. The kernel packs the requested attributes in bit order after the
    /// returned-attributes set: PRIVATESIZE (off_t), CLONEID (u64), EXT_FLAGS (u64), CLONE_REFCNT (u32).
    /// Every field is read only if `returned.forkattr` says it is present.
    static func probe(_ path: String) -> CloneInfo {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(cmnReturnedAttrs)
        list.forkattr = attrgroup_t(extPrivateSize | extCloneID | extFlags | extCloneRefCount)
        var buffer = [UInt8](repeating: 0, count: 128)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, fsoptNoFollow | fsoptCmnExtended)
        }
        guard rc == 0 else { return .unknown }
        return buffer.withUnsafeBytes { raw -> CloneInfo in
            guard raw.count >= 4 + 20 else { return .unknown }
            let length = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr
            let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            let need = extPrivateSize | extCloneID | extFlags | extCloneRefCount
            guard returnedFork & need == need, length <= raw.count else { return .unknown }
            var offset = 4 + 20
            guard offset + 8 + 8 + 8 + 4 <= min(length, raw.count) else { return .unknown }
            let privateSize = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self); offset += 8
            let cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self); offset += 8
            let flags = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self); offset += 8
            let refCount = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return .known(cloneID: cloneID, refCount: refCount, privateBytes: max(0, privateSize),
                          sharesAllBlocks: flags & efSharesAllBlocks != 0,
                          maySharesBlocks: flags & efMayShareBlocks != 0)
        }
    }

    /// `VOL_CAP_FMT_CLONE_MAPPING` of the volume holding `path`: whether clone ids are tracked.
    static func volumeTracksClones(_ path: String) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(0x8002_0000)
        var buffer = [UInt8](repeating: 0, count: 128)
        let rc = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, 0)
        }
        guard rc == 0 else { return false }
        // length (4), vol_capabilities_attr_t { capabilities[4], valid[4] }
        return buffer.withUnsafeBytes { raw in
            let caps = raw.loadUnaligned(fromByteOffset: 4 + 4, as: UInt32.self)     // capabilities[FORMAT]
            let valid = raw.loadUnaligned(fromByteOffset: 4 + 16 + 4, as: UInt32.self)
            let bit: UInt32 = 0x0400_0000
            return valid & bit != 0 && caps & bit != 0
        }
    }
}

extension CloneInfo {
    static func probe(_ path: String) -> CloneInfo { CloneProbe.probe(path) }
}
