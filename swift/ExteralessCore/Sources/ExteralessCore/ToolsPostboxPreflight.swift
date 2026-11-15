import Foundation

/// Checks the real Postbox key/type/length grammar before a typed legacy Codable
/// decode. It never constructs registered Postbox objects. Counts, signed lengths,
/// nested object boundaries and total work are checked before advancing a cursor.
public enum ToolsPostboxPreflight {
    public static func validate(_ data: Data, maximumBytes: Int, maximumFields: Int = 300_000) throws {
        guard !data.isEmpty, data.count <= maximumBytes, maximumFields > 0 else { throw ToolsError.sizeLimit }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var reader = Reader(bytes: bytes, remainingFields: maximumFields)
            try reader.object(end: bytes.count, depth: 0)
        }
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var remainingFields: Int
        var offset = 0

        mutating func consume(_ count: Int, end: Int) throws {
            guard count >= 0, offset <= end, count <= end - offset else { throw ToolsError.invalidArchive("Truncated cached Postbox record.") }
            offset += count
        }
        mutating func byte(end: Int) throws -> UInt8 {
            guard offset < end else { throw ToolsError.invalidArchive("Truncated cached Postbox record.") }
            defer { offset += 1 }
            return bytes[offset]
        }
        mutating func length(end: Int) throws -> Int {
            let start = offset
            try consume(4, end: end)
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[start + i]) << UInt32(i * 8) }
            let signed = Int32(bitPattern: value)
            guard signed >= 0 else { throw ToolsError.invalidArchive("Negative cached Postbox length/count.") }
            return Int(signed)
        }
        mutating func field() throws {
            guard remainingFields > 0 else { throw ToolsError.sizeLimit }
            remainingFields -= 1
        }
        mutating func string(end: Int) throws {
            let count = try length(end: end)
            let start = offset
            try consume(count, end: end)
            guard String(bytes: bytes[start..<offset], encoding: .utf8) != nil else { throw ToolsError.invalidArchive("Invalid cached UTF-8.") }
        }
        mutating func nested(end: Int, depth: Int) throws {
            try consume(4, end: end) // Type hash is data, never an executable type lookup.
            let count = try length(end: end)
            guard count <= end - offset else { throw ToolsError.invalidArchive("Truncated cached object.") }
            try object(end: offset + count, depth: depth + 1)
        }
        mutating func object(end: Int, depth: Int) throws {
            guard depth <= 24 else { throw ToolsError.sizeLimit }
            var keys = Set<String>()
            while offset < end {
                try field()
                let count = Int(try byte(end: end))
                guard count <= 127 else { throw ToolsError.invalidArchive("Invalid cached key length.") }
                let start = offset
                try consume(count, end: end)
                guard let key = String(bytes: bytes[start..<offset], encoding: .utf8), keys.insert(key).inserted else { throw ToolsError.invalidArchive("Duplicate/invalid cached key.") }
                switch try byte(end: end) {
                case 0: try consume(4, end: end)
                case 1, 3: try consume(8, end: end)
                case 2:
                    guard try byte(end: end) <= 1 else { throw ToolsError.invalidArchive("Invalid cached boolean.") }
                case 4: try string(end: end)
                case 5: try nested(end: end, depth: depth)
                case 6, 7:
                    let type = bytes[offset - 1]
                    let count = try length(end: end), width = type == 6 ? 4 : 8
                    guard count <= remainingFields, count <= (end - offset) / width else { throw ToolsError.sizeLimit }
                    remainingFields -= count
                    try consume(count * width, end: end)
                case 8, 9:
                    let type = bytes[offset - 1]
                    let count = try length(end: end), multiplier = type == 9 ? 2 : 1
                    guard count <= remainingFields / multiplier, count <= (end - offset) / (8 * multiplier) else { throw ToolsError.sizeLimit }
                    for _ in 0..<(count * multiplier) { try field(); try nested(end: end, depth: depth) }
                case 10:
                    let count = try length(end: end)
                    try consume(count, end: end)
                case 11: break
                case 12, 13:
                    let type = bytes[offset - 1]
                    let count = try length(end: end)
                    guard count <= remainingFields, count <= (end - offset) / 4 else { throw ToolsError.sizeLimit }
                    for _ in 0..<count {
                        try field()
                        if type == 12 { try string(end: end) }
                        else { let size = try length(end: end); try consume(size, end: end) }
                    }
                default: throw ToolsError.invalidArchive("Unknown cached Postbox value type.")
                }
            }
            guard offset == end else { throw ToolsError.invalidArchive("Invalid cached object boundary.") }
        }
    }
}
