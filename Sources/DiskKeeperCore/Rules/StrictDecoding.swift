import Foundation

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension Decoder {
    /// Throws `DecodingError.dataCorrupted` ("unknownKey:<key>") when the keyed container has a key outside
    /// `allowed`. When several are unknown the alphabetically first is reported.
    func rejectUnknownKeys(allowed: Set<String>) throws {
        let c = try container(keyedBy: AnyCodingKey.self)
        let unknown = c.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        if let key = unknown.first {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath, debugDescription: "unknownKey:\(key)"))
        }
    }
}
