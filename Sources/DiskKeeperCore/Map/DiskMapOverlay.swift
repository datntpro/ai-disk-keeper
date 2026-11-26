import Foundation

public enum AgeBucket: Int, Sendable, CaseIterable {
    case lastMonth, last6Months, lastYear, last3Years, older, unknown
}

/// What the scan found at/below one map node. Holds IDs only: the map never owns or creates `ScanItem`s.
public struct NodeAttribution: Sendable, Hashable {
    /// By attributed bytes in the subtree.
    public var dominantCategory: ItemCategory?
    public var dominantTool: ToolID?
    /// Σ `sizeAllocated` of items mapped at/below this node (capped at the node's bytes).
    public var attributedBytes: Int64
    public var tiers: Set<RiskTier>
    /// Items whose deepest materialized node is exactly this node (for "Review in list").
    public var itemIDs: [ScanItem.ID]
    /// An item path equals this node's path.
    public var isExact: Bool
}

/// Maps scan results onto tree nodes. Read-only; protection comes from the tree flags, never from here.
public struct DiskMapOverlay: Sendable {
    private let table: [DiskNodeID: NodeAttribution]
    /// Items whose path is outside the tree root.
    public let unmappedItemCount: Int

    public func attribution(_ id: DiskNodeID) -> NodeAttribution? { table[id] }

    public static func build(tree: DiskTree, items: [ScanItem]) -> DiskMapOverlay {
        // Slot-based accumulation (flat arrays) keeps this allocation-light for thousands of items.
        let cats = ItemCategory.allCases, catCount = cats.count
        let tiers = RiskTier.allCases
        var catIndex: [ItemCategory: Int] = [:]
        for (i, c) in cats.enumerated() { catIndex[c] = i }
        var tierIndex: [RiskTier: Int] = [:]
        for (i, t) in tiers.enumerated() { tierIndex[t] = i }
        let tools = Array(Set(items.map(\.tool))).sorted(), toolCount = max(1, tools.count)
        var toolIndex: [ToolID: Int] = [:]
        for (i, t) in tools.enumerated() { toolIndex[t] = i }

        var slotOf: [DiskNodeID: Int] = [:]
        var slotNode: [DiskNodeID] = []
        var slotBytes: [Int64] = [], slotCats: [Int64] = [], slotTools: [Int64] = []
        var slotTiers: [UInt32] = [], slotExact: [Bool] = []
        var slotIDs: [Int: [ScanItem.ID]] = [:]
        func slot(_ n: DiskNodeID) -> Int {
            if let s = slotOf[n] { return s }
            let s = slotNode.count
            slotOf[n] = s
            slotNode.append(n); slotBytes.append(0); slotTiers.append(0); slotExact.append(false)
            slotCats.append(contentsOf: repeatElement(0, count: catCount))
            slotTools.append(contentsOf: repeatElement(0, count: toolCount))
            return s
        }

        var unmapped = 0
        let rootKey = PathCanonicalizer.key(tree.rootPath).components

        for item in items {
            let path = item.url.path
            guard PathNormalization.isAbsolute(path), !PathNormalization.containsNUL(path) else { unmapped += 1; continue }
            let key = componentsKey(path)
            guard key.count >= rootKey.count, key.starts(with: rootKey) else { unmapped += 1; continue }
            var node = tree.rootNodeID
            var matched = rootKey.count
            for comp in key[rootKey.count...] {
                guard let next = tree.childMatching(foldedName: comp, of: node) else { break }
                node = next
                matched += 1
            }
            let own = slot(node)
            slotIDs[own, default: []].append(item.id)
            if matched == key.count { slotExact[own] = true }

            let bytes = max(0, item.sizeAllocated)
            let ci = catIndex[item.category]!, ti = toolIndex[item.tool]!, bit = UInt32(1) << UInt32(tierIndex[item.tier]!)
            var cur: DiskNodeID? = node
            while let n = cur {
                let s = slot(n)
                slotBytes[s] += bytes
                slotCats[s * catCount + ci] += bytes
                slotTools[s * toolCount + ti] += bytes
                slotTiers[s] |= bit
                cur = tree.parentOf(n)
            }
        }

        var table: [DiskNodeID: NodeAttribution] = [:]
        table.reserveCapacity(slotNode.count)
        for s in 0..<slotNode.count {
            let id = slotNode[s]
            var bestCat: (ItemCategory, Int64)?
            for (i, c) in cats.enumerated() {          // strict ">" keeps the first category in allCases order on ties
                let b = slotCats[s * catCount + i]
                if b > 0, bestCat == nil || b > bestCat!.1 { bestCat = (c, b) }
            }
            var bestTool: (ToolID, Int64)?
            for (i, t) in tools.enumerated() {         // tools sorted: the smallest id wins ties
                let b = slotTools[s * toolCount + i]
                if b > 0, bestTool == nil || b > bestTool!.1 { bestTool = (t, b) }
            }
            var tierSet: Set<RiskTier> = []
            for (i, t) in tiers.enumerated() where slotTiers[s] & (UInt32(1) << UInt32(i)) != 0 { tierSet.insert(t) }
            table[id] = NodeAttribution(
                dominantCategory: bestCat?.0, dominantTool: bestTool?.0,
                attributedBytes: min(slotBytes[s], tree.allocated[Int(id.raw)]), tiers: tierSet,
                itemIDs: slotIDs[s] ?? [], isExact: slotExact[s])
        }
        return DiskMapOverlay(table: table, unmappedItemCount: unmapped)
    }

    /// Same result as `PathCanonicalizer.key(path).components`, without the lexical pass when the path is already clean
    /// (no "." / ".." components, first component not one of the aliased roots). Anything else takes the canonical route.
    private static func componentsKey(_ path: String) -> [String] {
        var comps: [String] = []
        for part in path.utf8.split(separator: 0x2F, omittingEmptySubsequences: true) {
            if part.count <= 2, part.allSatisfy({ $0 == 0x2E }) { return PathCanonicalizer.key(path).components }
            comps.append(foldFast(String(decoding: part, as: UTF8.self)))
        }
        if let first = comps.first, first == "system" || first == "tmp" || first == "var" || first == "etc" {
            return PathCanonicalizer.key(path).components
        }
        return comps
    }

    /// `PathCanonicalizer.fold`, with an exact ASCII fast path (ASCII case folding is lowercasing; NFC is identity).
    private static func foldFast(_ s: String) -> String {
        var s = s
        let ascii = s.withUTF8 { buf -> Bool in
            for b in buf where b >= 0x80 { return false }
            return true
        }
        guard ascii else { return PathCanonicalizer.fold(s) }
        return s.withUTF8 { buf in
            String(unsafeUninitializedCapacity: buf.count) { out in
                for i in 0..<buf.count { let b = buf[i]; out[i] = (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b }
                return buf.count
            }
        }
    }

    /// <30 d, <183 d, <365 d, <3·365 d, older; nil → unknown. Dates in the future count as the last month.
    public static func ageBucket(_ date: Date?, now: Date) -> AgeBucket {
        guard let date else { return .unknown }
        let days = now.timeIntervalSince(date) / 86_400
        if days < 30 { return .lastMonth }
        if days < 183 { return .last6Months }
        if days < 365 { return .lastYear }
        if days < 3 * 365 { return .last3Years }
        return .older
    }
}

extension DiskTree {
    func parentOf(_ id: DiskNodeID) -> DiskNodeID? {
        let p = parents[Int(id.raw)]
        return p < 0 ? nil : DiskNodeID(raw: p)
    }
}

extension DiskTree {
    /// First non-synthetic child whose `PathCanonicalizer.fold`ed name equals `comp` (already folded). ASCII names are
    /// compared byte-wise without allocating; anything else goes through the canonical fold.
    func childMatching(foldedName comp: String, of node: DiskNodeID) -> DiskNodeID? {
        let want = Array(comp.utf8)
        for c in children(of: node) {
            let i = Int(c.raw)
            if flagBits[i] & NodeFlags.smallItems.rawValue != 0 { continue }
            let s = Int(nameStart[i]), n = Int(nameLen[i])
            var ascii = true
            for k in s..<(s + n) where arena[k] >= 0x80 { ascii = false; break }
            if ascii {
                guard n == want.count else { continue }
                var same = true
                for k in 0..<n {
                    let b = arena[s + k]
                    if ((b >= 0x41 && b <= 0x5A) ? b | 0x20 : b) != want[k] { same = false; break }
                }
                if same { return c }
            } else if PathCanonicalizer.fold(nameString(i)) == comp {
                return c
            }
        }
        return nil
    }
}
