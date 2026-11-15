import Foundation

/// A structural SFNT admission check before bytes reach CoreText. This is not a
/// font renderer: CoreText registration and a non-fallback glyph probe must also
/// succeed. No archives, executable font installers, WOFF, SVG or TTC are read.
public struct EmojiFontInspection: Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int
    public let fileExtension: String
    public let postScriptName: String?
    public let license: String?
    public let tables: Set<String>

    public static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func inspect(_ data: Data, fileExtension: String, expectedSHA256: String? = nil) throws -> EmojiFontInspection {
        guard data.count <= EmojiPackLimits.fontBytes else { throw EmojiPackError.tooLarge }
        guard ["ttf", "otf"].contains(fileExtension.lowercased()), data.count >= 12 else { throw EmojiPackError.invalidFont("expected a .ttf or .otf SFNT") }
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        let signature = u32(0)
        guard signature == 0x00010000 || signature == 0x4f54544f else { throw EmojiPackError.incompatibleFont }
        let count = u16(4)
        guard (1...128).contains(count), 12 + count * 16 <= bytes.count else { throw EmojiPackError.invalidFont("table directory") }
        var tables: [String: Range<Int>] = [:]
        for i in 0..<count {
            let position = 12 + 16 * i
            let tagBytes = bytes[position..<(position + 4)]
            guard tagBytes.allSatisfy({ (32...126).contains($0) }), let tag = String(bytes: tagBytes, encoding: .ascii), tables[tag] == nil else { throw EmojiPackError.invalidFont("duplicate or invalid table") }
            let offset = u32(position + 8), length = u32(position + 12)
            guard offset >= 12 + 16 * count, offset % 4 == 0, length > 0,
                  offset <= bytes.count, length <= bytes.count - offset else { throw EmojiPackError.invalidFont("table bounds") }
            let range = offset..<(offset + length)
            guard !tables.values.contains(where: { $0.overlaps(range) }) else { throw EmojiPackError.invalidFont("overlapping tables") }
            tables[tag] = range
        }
        guard let head = tables["head"], head.count >= 54, u32(head.lowerBound + 12) == 0x5f0f3cf5,
              (16...16384).contains(u16(head.lowerBound + 18)),
              let maxp = tables["maxp"], maxp.count >= 6, u16(maxp.lowerBound + 4) > 0,
              let cmap = tables["cmap"], cmap.count >= 12,
              let name = tables["name"], name.count >= 6,
              let hhea = tables["hhea"], hhea.count >= 36, tables["hmtx"] != nil else { throw EmojiPackError.invalidFont("required SFNT metrics") }
        let glyphCount = u16(maxp.lowerBound + 4)
        let metricCount = u16(hhea.lowerBound + 34)
        guard metricCount > 0, metricCount <= glyphCount,
              tables["hmtx"]!.count >= 4 * metricCount + 2 * (glyphCount - metricCount) else { throw EmojiPackError.invalidFont("horizontal metrics") }

        let hasOutline = tables["glyf"] != nil && tables["loca"] != nil || tables["CFF "] != nil
        // Android's CBDT/CBLC-only Noto fonts can register but draw blank on iOS.
        // COLR v1 and SVG have OS-dependent renderers, outside this iOS 15 floor.
        guard hasOutline || tables["sbix"] != nil else { throw EmojiPackError.incompatibleFont }
        if let colr = tables["COLR"] {
            guard colr.count >= 14, u16(colr.lowerBound) == 0, let cpal = tables["CPAL"], cpal.count >= 12 else { throw EmojiPackError.incompatibleFont }
        }
        if tables["SVG "] != nil { throw EmojiPackError.incompatibleFont }
        if let loca = tables["loca"] {
            let format = u16(head.lowerBound + 50)
            guard format <= 1, loca.count >= (glyphCount + 1) * (format == 0 ? 2 : 4), let glyf = tables["glyf"] else { throw EmojiPackError.invalidFont("glyph offsets") }
            var previous = 0
            for i in 0...glyphCount {
                let offset = format == 0 ? u16(loca.lowerBound + 2 * i) * 2 : u32(loca.lowerBound + 4 * i)
                guard offset >= previous, offset <= glyf.count else { throw EmojiPackError.invalidFont("glyph bounds") }
                previous = offset
            }
        }
        let cmapCount = u16(cmap.lowerBound + 2)
        guard u16(cmap.lowerBound) == 0, (1...64).contains(cmapCount), 4 + 8 * cmapCount <= cmap.count else { throw EmojiPackError.invalidFont("character map") }
        var hasUnicodeMap = false
        for i in 0..<cmapCount {
            let at = cmap.lowerBound + 4 + 8 * i
            let platform = u16(at), encoding = u16(at + 2), offset = u32(at + 4)
            guard offset <= cmap.count - 4 else { throw EmojiPackError.invalidFont("character map offset") }
            let start = cmap.lowerBound + offset
            let format = u16(start)
            if format == 4 {
                let length = u16(start + 2)
                guard length >= 16, length <= cmap.count - offset else { throw EmojiPackError.invalidFont("BMP character map") }
                let segments = u16(start + 6)
                guard segments > 0, segments % 2 == 0, 16 + 4 * segments <= length else { throw EmojiPackError.invalidFont("BMP segments") }
            } else if format == 12 || format == 13 {
                guard offset <= cmap.count - 16 else { throw EmojiPackError.invalidFont("Unicode character map") }
                let length = u32(start + 4), groups = u32(start + 12)
                guard length >= 16, length <= cmap.count - offset, groups <= 65536, groups <= (length - 16) / 12 else { throw EmojiPackError.invalidFont("Unicode map groups") }
            } else { continue }
            if platform == 0 || platform == 3 && (encoding == 1 || encoding == 10) { hasUnicodeMap = true }
        }
        guard hasUnicodeMap else { throw EmojiPackError.invalidFont("missing Unicode map") }

        let nameCount = u16(name.lowerBound + 2), stringOffset = u16(name.lowerBound + 4)
        guard u16(name.lowerBound) <= 1, nameCount <= 256, 6 + 12 * nameCount <= name.count,
              stringOffset >= 6 + 12 * nameCount, stringOffset <= name.count else { throw EmojiPackError.invalidFont("font names") }
        var postScriptName: String?, license: String?
        for i in 0..<nameCount {
            let at = name.lowerBound + 6 + i * 12
            let platform = u16(at), identifier = u16(at + 6), length = u16(at + 8), offset = u16(at + 10)
            guard offset <= name.count - stringOffset, length <= name.count - stringOffset - offset else { throw EmojiPackError.invalidFont("name string bounds") }
            if (identifier == 6 || identifier == 13), length <= 4096 {
                let start = name.lowerBound + stringOffset + offset
                let data = Data(bytes[start..<(start + length)])
                let value = String(data: data, encoding: platform == 0 || platform == 3 ? .utf16BigEndian : .macOSRoman)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if identifier == 6, let value, !value.isEmpty, value.utf8.count <= 127 { postScriptName = value }
                if identifier == 13, let value, !value.isEmpty { license = value }
            }
        }
        let digest = ToolsSHA256.hex(data)
        if let expectedSHA256 {
            guard isSHA256(expectedSHA256), digest == expectedSHA256 else { throw EmojiPackError.checksumMismatch }
        }
        return EmojiFontInspection(sha256: digest, byteCount: data.count, fileExtension: fileExtension.lowercased(), postScriptName: postScriptName, license: license, tables: Set(tables.keys))
    }

    /// Bounded reads also cover a file that grows after the initial size check.
    public static func readFile(_ url: URL, maximumBytes: Int = EmojiPackLimits.fontBytes) throws -> Data {
        guard url.isFileURL, maximumBytes >= 0 else { throw EmojiPackError.storage }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw EmojiPackError.storage }
        if let size = properties.fileSize, size > maximumBytes { throw EmojiPackError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw EmojiPackError.tooLarge }
        return bytes
    }
}
