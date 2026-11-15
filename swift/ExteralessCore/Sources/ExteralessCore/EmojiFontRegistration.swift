import Foundation

/// CoreText's registry is process-wide and refuses a second font with the same
/// PostScript name. Give each content hash a private *in-memory* family/name so
/// updates can coexist with attributed strings still retaining the previous face.
/// Original bytes, source SHA and copyright/license names remain in the store.
public enum EmojiFontRegistration {
    public static func privateName(sha256: String) -> String { "EXLEmoji-" + String(sha256.prefix(40)) }

    public static func data(_ original: Data, inspection: EmojiFontInspection) throws -> Data {
        guard ToolsSHA256.hex(original) == inspection.sha256 else { throw EmojiPackError.checksumMismatch }
        let bytes = [UInt8](original)
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        let count = u16(4)
        var tables: [(String, Data)] = []
        for i in 0..<count {
            let at = 12 + i * 16
            let tag = String(bytes: bytes[at..<(at + 4)], encoding: .ascii)!
            if tag == "DSIG" { continue }
            let start = u32(at + 8), length = u32(at + 12)
            var table = original.subdata(in: start..<(start + length))
            if tag == "name" {
                let names = u16(start + 2), stringStart = u16(start + 4)
                var records = Data(), strings = Data()
                let privateName = self.privateName(sha256: inspection.sha256)
                let replaced: Set<Int> = [1, 3, 4, 6, 16, 18, 21, 25]
                for j in 0..<names {
                    let at = start + 6 + j * 12
                    let platform = u16(at), identifier = u16(at + 6)
                    // Format-1 language tag records would need offset rebuilding;
                    // retain the usable Windows/Unicode/Mac named records only.
                    guard u16(at + 4) < 0x8000 else { continue }
                    let text: Data
                    if replaced.contains(identifier) {
                        guard let encoded = privateName.data(using: platform == 0 || platform == 3 ? .utf16BigEndian : .ascii) else { throw EmojiPackError.incompatibleFont }
                        text = encoded
                    } else {
                        let offset = start + stringStart + u16(at + 10)
                        text = original.subdata(in: offset..<(offset + u16(at + 8)))
                    }
                    guard strings.count + text.count <= 65535 else { throw EmojiPackError.incompatibleFont }
                    records.append(contentsOf: bytes[at..<(at + 8)])
                    append16(text.count, to: &records)
                    append16(strings.count, to: &records)
                    strings.append(text)
                }
                table = Data()
                append16(0, to: &table)
                append16(records.count / 12, to: &table)
                append16(6 + records.count, to: &table)
                table.append(records); table.append(strings)
            } else if tag == "head" { table.replaceSubrange(8..<12, with: [0, 0, 0, 0]) }
            tables.append((tag, table))
        }
        tables.sort { $0.0 < $1.0 }
        let n = tables.count
        var power = 1, selector = 0
        while power * 2 <= n { power *= 2; selector += 1 }
        var result = original.subdata(in: 0..<4)
        append16(n, to: &result); append16(power * 16, to: &result)
        append16(selector, to: &result); append16(n * 16 - power * 16, to: &result)
        var body = Data(), headOffset: Int?
        for (tag, table) in tables {
            let offset = 12 + n * 16 + body.count
            result.append(Data(tag.utf8))
            append32(checksum(table), to: &result)
            append32(UInt32(offset), to: &result); append32(UInt32(table.count), to: &result)
            if tag == "head" { headOffset = offset }
            body.append(table)
            while body.count % 4 != 0 { body.append(0) }
        }
        result.append(body)
        guard let headOffset, result.count <= EmojiPackLimits.fontBytes else { throw EmojiPackError.incompatibleFont }
        var adjustment = Data()
        append32(0xb1b0afba &- checksum(result), to: &adjustment)
        result.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: adjustment)
        return result
    }

    private static func append16(_ value: Int, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8)); data.append(UInt8(truncatingIfNeeded: value))
    }
    private static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    private static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for at in stride(from: 0, to: data.count, by: 4) {
            var word: UInt32 = 0
            for i in 0..<4 { word = word << 8 | UInt32(at + i < data.count ? data[at + i] : 0) }
            value = value &+ word
        }
        return value
    }
}
