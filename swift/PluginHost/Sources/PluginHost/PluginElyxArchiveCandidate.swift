import Foundation

/// ZIP transformation in memory. The input must be the source lease's verified
/// bytes; the output still requires the archive owner's full FD-backed static
/// inspection (CRC/inflation, metadata, bytecode and wheels) before publication.
/// Untouched compressed bodies are preserved; new/changed bodies use ZIP_STORED.
public enum PluginElyxArchiveCandidate {
    public static let maximumBytes = 32 * 1024 * 1024
    private static let maximumExpanded = 64 * 1024 * 1024

    private struct Entry {
        let directory: Bool
        let method: Int
        let crc: UInt32
        let size: Int
        let bytes: Data

        init(directory: Bool, method: Int = 0, crc: UInt32? = nil, size: Int? = nil, bytes: Data = Data()) {
            self.directory = directory; self.method = method
            self.crc = crc ?? PluginElyxArchiveCandidate.crc32(bytes)
            self.size = size ?? bytes.count; self.bytes = bytes
        }
    }

    public static func applying(_ changes: [PluginElyxChange], to source: Data) throws -> Data {
        guard changes.count <= PluginElyxDeveloperRequest.maximumChanges,
              changes.reduce(0, { $0 + $1.content.count }) <= PluginElyxDeveloperRequest.maximumChangedBytes else {
            throw PluginElyxDeveloperError.malformed("change budget exceeded")
        }
        var files = try decode(source)
        func isDirectory(_ path: String) -> Bool {
            files[path]?.directory == true || files.keys.contains { $0.hasPrefix(path + "/") }
        }
        for change in changes {
            let path = change.path
            switch change.kind {
            case .created, .modified:
                if change.directory {
                    guard files[path] == nil || files[path]?.directory == true else { throw PluginElyxDeveloperError.malformed("cannot create a directory over a file: \(path)") }
                    files[path] = Entry(directory: true)
                } else {
                    guard !isDirectory(path) else { throw PluginElyxDeveloperError.malformed("cannot write a file over a directory: \(path)") }
                    try rejectNative(path, bytes: change.content)
                    files[path] = Entry(directory: false, bytes: change.content)
                }
            case .deleted:
                for key in Array(files.keys) where key == path || key.hasPrefix(path + "/") { files[key] = nil }
            case .moved:
                let destination = change.destination!
                let keys = files.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
                guard !keys.isEmpty else { throw PluginElyxDeveloperError.malformed("moved source is missing: \(path)") }
                if path == destination { continue }
                let directory = isDirectory(path)
                guard !destination.hasPrefix(path + "/") else { throw PluginElyxDeveloperError.malformed("cannot move a directory into itself") }
                if directory {
                    guard files[destination] == nil || files[destination]?.directory == true,
                          !files.keys.contains(where: { $0.hasPrefix(destination + "/") }) else {
                        throw PluginElyxDeveloperError.malformed("directory move destination is occupied")
                    }
                } else if isDirectory(destination) { throw PluginElyxDeveloperError.malformed("file move destination is a directory") }
                let moved = keys.map { ($0, files[$0]!) }
                for (key, _) in moved { files[key] = nil }
                files[destination] = nil
                for (key, entry) in moved {
                    let next = destination + key.dropFirst(path.count)
                    try rejectNative(next, bytes: Data())
                    files[next] = entry
                }
            }
            try validateTree(files)
        }
        guard !files.isEmpty else { throw PluginElyxDeveloperError.malformed("changes remove every archive member") }
        return try encode(files)
    }

    private static func validateTree(_ files: [String: Entry]) throws {
        guard files.count <= 2048, files.values.reduce(0, { $0 + $1.size }) <= maximumExpanded else {
            throw PluginElyxDeveloperError.malformed("candidate exceeds archive entry/expanded byte limits")
        }
        var names: [String: (String, Bool)] = [:]
        for (name, entry) in files {
            guard try PluginElyxDeveloperRequest.path(name) == name, entry.size <= 16 * 1024 * 1024 else {
                throw PluginElyxDeveloperError.malformed("candidate path/member exceeds archive limits")
            }
            let parts = name.split(separator: "/")
            for index in parts.indices {
                let spelling = parts[...index].joined(separator: "/")
                let directory = index < parts.count - 1 || entry.directory
                let folded = spelling.precomposedStringWithCanonicalMapping.lowercased()
                if let old = names[folded], old.0 != spelling || old.1 != directory {
                    throw PluginElyxDeveloperError.malformed("case/Unicode alias or file/directory collision")
                }
                names[folded] = (spelling, directory)
            }
        }
    }

    private static func rejectNative(_ name: String, bytes: Data) throws {
        let lower = name.lowercased()
        let magic: [[UInt8]] = [[0x7f, 0x45, 0x4c, 0x46], [0x4d, 0x5a], [0xfe, 0xed, 0xfa, 0xce],
            [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]]
        guard lower.range(of: "\\.(so|pyd|dylib|dll|a|o|fwork)(\\.|$)", options: .regularExpression) == nil,
              !lower.split(separator: "/").contains(where: { $0.hasSuffix(".framework") }),
              !magic.contains(where: { bytes.starts(with: $0) }) else {
            throw PluginElyxDeveloperError.unsupported("unverified native archive content: \(name)")
        }
    }

    private static func decode(_ data: Data) throws -> [String: Entry] {
        guard (22...maximumBytes).contains(data.count) else { throw PluginElyxDeveloperError.malformed("source ZIP exceeds 32 MiB or has no EOCD") }
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset + width <= bytes.count else { throw PluginElyxDeveloperError.malformed("truncated ZIP field") }
            return (0..<width).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try number(offset, 4) == 0x06054b50, offset + 22 + (try number(offset + 20, 2)) == bytes.count { end = offset; break }
        }
        guard let end else { throw PluginElyxDeveloperError.malformed("missing ZIP end record") }
        let count = try number(end + 10, 2), central = try number(end + 16, 4), centralSize = try number(end + 12, 4)
        guard try number(end + 4, 2) == 0, try number(end + 6, 2) == 0, try number(end + 8, 2) == count,
              count <= 2048, centralSize <= 2 * 1024 * 1024, central + centralSize == end else {
            throw PluginElyxDeveloperError.unsupported("ZIP64, multi-disk or over-budget archive")
        }
        var cursor = central
        var files: [String: Entry] = [:]
        var spans: [Range<Int>] = []
        for _ in 0..<count {
            guard cursor + 46 <= end, try number(cursor, 4) == 0x02014b50 else { throw PluginElyxDeveloperError.malformed("invalid ZIP central entry") }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let crc = UInt32(try number(cursor + 16, 4)), compressed = try number(cursor + 20, 4), size = try number(cursor + 24, 4)
            let length = try number(cursor + 28, 2), extra = try number(cursor + 30, 2), comment = try number(cursor + 32, 2)
            let attributes = try number(cursor + 38, 4), local = try number(cursor + 42, 4)
            let next = cursor + 46 + length + extra + comment
            guard next <= end, flags & ~(0x800 | 8 | 6) == 0, method == 0 || method == 8,
                  try number(cursor + 34, 2) == 0, compressed <= maximumBytes, size <= 16 * 1024 * 1024,
                  size <= max(1, compressed) * 200 else { throw PluginElyxDeveloperError.malformed("unsupported flags/compression or ZIP member budget") }
            let rawName = Array(bytes[(cursor + 46)..<(cursor + 46 + length)])
            let name = try decodeName(rawName, utf8: flags & 0x800 != 0)
            let directory = name.hasSuffix("/")
            let path = directory ? String(name.dropLast()) : name
            guard try PluginElyxDeveloperRequest.path(path) == path, files[path] == nil,
                  [0, directory ? 0x4000 : 0x8000].contains((attributes >> 16) & 0xf000),
                  attributes & 0x400 == 0, !directory || size == 0 else { throw PluginElyxDeveloperError.malformed("duplicate, redirected or unsafe ZIP entry") }
            guard local + 30 <= central, try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method else { throw PluginElyxDeveloperError.malformed("invalid ZIP local header") }
            let localLength = try number(local + 26, 2), localExtra = try number(local + 28, 2)
            let start = local + 30 + localLength + localExtra
            guard localLength == length, start + compressed <= central,
                  Array(bytes[(local + 30)..<(local + 30 + localLength)]) == rawName else { throw PluginElyxDeveloperError.malformed("ZIP local/central filename or span mismatch") }
            if flags & 8 == 0 {
                guard try number(local + 14, 4) == Int(crc), try number(local + 18, 4) == compressed,
                      try number(local + 22, 4) == size else { throw PluginElyxDeveloperError.malformed("ZIP local/central size/CRC mismatch") }
            }
            spans.append(local..<(start + compressed))
            files[path] = Entry(directory: directory, method: method, crc: crc, size: size, bytes: Data(bytes[start..<(start + compressed)]))
            cursor = next
        }
        let ordered = spans.sorted { $0.lowerBound < $1.lowerBound }
        guard cursor == end, !zip(ordered, ordered.dropFirst()).contains(where: { $0.0.overlaps($0.1) }) else {
            throw PluginElyxDeveloperError.malformed("overlapping ZIP records or incorrect central count")
        }
        try validateTree(files)
        return files
    }

    private static func decodeName(_ bytes: [UInt8], utf8: Bool) throws -> String {
        if utf8 {
            guard let name = String(bytes: bytes, encoding: .utf8) else { throw PluginElyxDeveloperError.malformed("invalid UTF-8 ZIP filename") }
            return name
        }
        // ZIP's legacy filename encoding is CP437, matching Python zipfile.
        let high = Array("ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ")
        return String(bytes.map { $0 < 128 ? Character(UnicodeScalar($0)) : high[Int($0) - 128] })
    }

    private static func encode(_ files: [String: Entry]) throws -> Data {
        var output = Data(), central = Data()
        for name in files.keys.sorted() {
            let entry = files[name]!
            let path = Data((name + (entry.directory ? "/" : "")).utf8)
            guard output.count + 30 + path.count + entry.bytes.count + central.count + 46 + path.count + 22 <= maximumBytes else {
                throw PluginElyxDeveloperError.malformed("candidate ZIP exceeds 32 MiB")
            }
            let offset = output.count
            append(0x04034b50, 4, to: &output)
            for value in [20, 0x800, entry.method, 0, 0] { append(value, 2, to: &output) }
            for value in [Int(entry.crc), entry.bytes.count, entry.size] { append(value, 4, to: &output) }
            append(path.count, 2, to: &output); append(0, 2, to: &output)
            output.append(path); output.append(entry.bytes)
            append(0x02014b50, 4, to: &central)
            for value in [0x0314, 20, 0x800, entry.method, 0, 0] { append(value, 2, to: &central) }
            for value in [Int(entry.crc), entry.bytes.count, entry.size] { append(value, 4, to: &central) }
            for value in [path.count, 0, 0, 0, 0] { append(value, 2, to: &central) }
            append(entry.directory ? (0o40700 << 16) | 0x10 : 0o100600 << 16, 4, to: &central)
            append(offset, 4, to: &central); central.append(path)
        }
        guard central.count <= 2 * 1024 * 1024 else { throw PluginElyxDeveloperError.malformed("candidate central directory exceeds 2 MiB") }
        let offset = output.count
        output.append(central)
        append(0x06054b50, 4, to: &output)
        for value in [0, 0, files.count, files.count] { append(value, 2, to: &output) }
        append(central.count, 4, to: &output); append(offset, 4, to: &output); append(0, 2, to: &output)
        return output
    }

    private static func append(_ value: Int, _ width: Int, to data: inout Data) {
        for index in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}
