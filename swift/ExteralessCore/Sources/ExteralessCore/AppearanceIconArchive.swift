import Foundation

/// Bounded ZIP codec for Android .icons archives. Inflation is supplied by the
/// native adapter; Foundation-only policy tests also exercise stored ZIPs.
public enum AppearanceIconArchive {
    public static let maximumArchiveBytes = 100 * 1024 * 1024
    public static let maximumFileBytes = 10 * 1024 * 1024
    public static let maximumMetadataBytes = 262144
    public static let maximumEntries = 3000

    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else {
            throw AppearanceIconPackError.unsafePath
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AppearanceIconPackError.unsafePath }
    }

    public static func decode(_ data: Data, inflate: (Data, Int) throws -> Data) throws -> [String: Data] {
        guard data.count >= 22 else { throw AppearanceIconPackError.invalidArchive }
        guard data.count <= maximumArchiveBytes else { throw AppearanceIconPackError.sizeLimit }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= bytes.count else { throw AppearanceIconPackError.invalidArchive }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { throw AppearanceIconPackError.invalidArchive }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65535), by: -1) {
            if try u32(offset) == 0x06054b50, offset + 22 + (try u16(offset + 20)) == bytes.count { end = offset; break }
        }
        guard let end else { throw AppearanceIconPackError.invalidArchive }
        let count = try u16(end + 10)
        let directorySize = try u32(end + 12)
        let directory = try u32(end + 16)
        guard try u16(end + 4) == 0, try u16(end + 6) == 0, try u16(end + 8) == count,
              count > 0, count <= maximumEntries, directory + directorySize == end else { throw AppearanceIconPackError.invalidArchive }
        var position = directory
        var total = 0
        var names = Set<String>()
        var ranges: [Range<Int>] = []
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard position + 46 <= end, try u32(position) == 0x02014b50 else { throw AppearanceIconPackError.invalidArchive }
            let flags = try u16(position + 8)
            let method = try u16(position + 10)
            let crc = UInt32(try u32(position + 16))
            let compressedSize = try u32(position + 20)
            let size = try u32(position + 24)
            let nameSize = try u16(position + 28)
            let extraSize = try u16(position + 30)
            let commentSize = try u16(position + 32)
            let attributes = try u32(position + 38)
            let local = try u32(position + 42)
            let next = position + 46 + nameSize + extraSize + commentSize
            guard next <= end, flags & 1 == 0, try u16(position + 34) == 0,
                  (attributes >> 16) & 0xf000 != 0xa000 else { throw AppearanceIconPackError.invalidArchive }
            guard method == 0 || method == 8 else { throw AppearanceIconPackError.unsupportedCompression }
            guard size <= maximumFileBytes, compressedSize <= maximumFileBytes,
                  size <= max(1, compressedSize) * 250, total + size <= maximumArchiveBytes else { throw AppearanceIconPackError.sizeLimit }
            guard let name = String(bytes: bytes[(position + 46)..<(position + 46 + nameSize)], encoding: .utf8) else { throw AppearanceIconPackError.unsafePath }
            let isDirectory = name.hasSuffix("/")
            let path = isDirectory ? String(name.dropLast()) : name
            try validatePath(path)
            guard names.insert(path.lowercased()).inserted else { throw AppearanceIconPackError.unsafePath }
            guard local + 30 <= directory, try u32(local) == 0x04034b50,
                  try u16(local + 6) == flags, try u16(local + 8) == method else { throw AppearanceIconPackError.invalidArchive }
            if flags & 8 == 0 {
                guard try u32(local + 14) == Int(crc), try u32(local + 18) == compressedSize,
                      try u32(local + 22) == size else { throw AppearanceIconPackError.invalidArchive }
            }
            let localNameSize = try u16(local + 26)
            let localExtraSize = try u16(local + 28)
            let start = local + 30 + localNameSize + localExtraSize
            guard localNameSize == nameSize, start + compressedSize <= directory,
                  Array(bytes[(local + 30)..<(local + 30 + localNameSize)]) == Array(name.utf8) else { throw AppearanceIconPackError.invalidArchive }
            let range = local..<(start + compressedSize)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw AppearanceIconPackError.invalidArchive }
            ranges.append(range)
            total += size
            position = next
            let compressed = Data(bytes[start..<(start + compressedSize)])
            let contents: Data
            if method == 0 { contents = compressed }
            else { contents = try inflate(compressed, size) }
            guard contents.count == size else { throw AppearanceIconPackError.invalidArchive }
            guard checksum(contents) == crc else { throw AppearanceIconPackError.checksum }
            if isDirectory {
                guard size == 0 else { throw AppearanceIconPackError.invalidArchive }
                continue
            }
            result[path] = contents
        }
        guard position == end else { throw AppearanceIconPackError.invalidArchive }
        return result
    }

    /// Android can import stored ZIP entries as well as DEFLATE. Export does not
    /// require another compression dependency and preserves original image bytes.
    public static func encode(_ files: [String: Data]) throws -> Data {
        guard !files.isEmpty, files.count <= maximumEntries else { throw AppearanceIconPackError.sizeLimit }
        var output = Data()
        var directory = Data()
        var total = 0
        var seen = Set<String>()
        for name in files.keys.sorted() {
            try validatePath(name)
            guard seen.insert(name.lowercased()).inserted else { throw AppearanceIconPackError.unsafePath }
            let data = files[name]!
            total += data.count
            guard data.count <= maximumFileBytes, total <= maximumArchiveBytes else { throw AppearanceIconPackError.sizeLimit }
            let nameBytes = Data(name.utf8)
            let crc = checksum(data)
            let offset = output.count
            append32(0x04034b50, to: &output)
            append16(20, to: &output); append16(0x0800, to: &output); append16(0, to: &output)
            append16(0, to: &output); append16(0, to: &output)
            append32(crc, to: &output); append32(UInt32(data.count), to: &output); append32(UInt32(data.count), to: &output)
            append16(nameBytes.count, to: &output); append16(0, to: &output)
            output.append(nameBytes); output.append(data)

            append32(0x02014b50, to: &directory)
            append16(20, to: &directory); append16(20, to: &directory); append16(0x0800, to: &directory); append16(0, to: &directory)
            append16(0, to: &directory); append16(0, to: &directory)
            append32(crc, to: &directory); append32(UInt32(data.count), to: &directory); append32(UInt32(data.count), to: &directory)
            append16(nameBytes.count, to: &directory); append16(0, to: &directory); append16(0, to: &directory)
            append16(0, to: &directory); append16(0, to: &directory); append32(0, to: &directory); append32(UInt32(offset), to: &directory)
            directory.append(nameBytes)
        }
        let offset = output.count
        output.append(directory)
        append32(0x06054b50, to: &output)
        append16(0, to: &output); append16(0, to: &output)
        append16(files.count, to: &output); append16(files.count, to: &output)
        append32(UInt32(directory.count), to: &output); append32(UInt32(offset), to: &output); append16(0, to: &output)
        guard output.count <= maximumArchiveBytes else { throw AppearanceIconPackError.sizeLimit }
        return output
    }

    public static func unpack(_ files: [String: Data]) throws -> (AppearanceIconPackMetadata, [String: Data]) {
        let candidates = files.keys.filter { $0 == "metadata.json" || $0.hasSuffix("/metadata.json") }
        guard candidates.count == 1, let name = candidates.first, let bytes = files[name], bytes.count <= maximumMetadataBytes else {
            throw AppearanceIconPackError.invalidMetadata
        }
        let metadata: AppearanceIconPackMetadata
        do { metadata = try JSONDecoder().decode(AppearanceIconPackMetadata.self, from: bytes) }
        catch { throw AppearanceIconPackError.invalidMetadata }
        try metadata.validate()
        let prefix = String(name.dropLast("metadata.json".count))
        var result: [String: Data] = ["metadata.json": bytes]
        for path in Set(metadata.icons.values) {
            guard let value = files[prefix + path], value.count <= maximumFileBytes else { throw AppearanceIconPackError.invalidMetadata }
            result[path] = value
        }
        return (metadata, result)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }

    private static func append16(_ value: Int, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
