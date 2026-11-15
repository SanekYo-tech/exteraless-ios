import Foundation

/// Checked wrapper fields only; native code still verifies the embedded FlatBuffer.
public struct ToolsCloudFavoriteWire: Sendable {
    public let fileData: Data
    public let aliases: [String]
}

extension ToolsFavoriteStickerStorage {
    /// Real legacy v1 wire format, decoded without Postbox's wire-selected generic
    /// containers/as! casts. Every accessor enforces its expected scalar/array shape.
    public static func decodeLegacyPostbox(_ data: Data, userId: Int64) throws -> [ToolsFavoriteSticker] {
        let reader = try ToolsFavoritePostboxReader(data, maximumBytes: ToolsFavoriteStickerArchive.maximumBytes)
        let root = try reader.root()
        try reader.keys(root, allowed: ["version", "userId", "stickers"])
        guard try reader.integer(root, "version") == 1, try reader.integer(root, "userId") == userId else {
            throw ToolsError.invalidArchive("Invalid legacy favorite version/account. Original bytes are retained.")
        }
        let objects = try reader.objects(reader.required(root, "stickers"), maximum: ToolsFavoriteStickerArchive.maximumPerAccount)
        let stickers = try objects.map { try reader.sticker($0) }
        try ToolsFavoriteStickerArchive(accounts: [String(userId): stickers]).validate()
        return stickers
    }

    /// Accepts only the current fd/sr wrapper, without generic Postbox construction.
    public static func decodeCloudPostbox(_ data: Data) throws -> ToolsCloudFavoriteWire {
        let reader = try ToolsFavoritePostboxReader(data, maximumBytes: 1_024 * 1_024, maximumFields: 4_096)
        let root = try reader.root()
        try reader.keys(root, allowed: ["fd", "sr"])
        return try .init(fileData: reader.data(reader.required(root, "fd"), maximum: 1_024 * 1_024),
                         aliases: reader.strings(reader.required(root, "sr"), maximum: 32, stringBytes: 128))
    }
}

private struct ToolsFavoritePostboxReader {
    struct Field {
        let type: UInt8
        let range: Range<Int>
    }
    typealias Object = [String: Field]
    private let bytes: [UInt8]

    init(_ data: Data, maximumBytes: Int, maximumFields: Int = 300_000) throws {
        try ToolsPostboxPreflight.validate(data, maximumBytes: maximumBytes, maximumFields: maximumFields)
        bytes = Array(data)
    }

    private var invalid: ToolsError { .invalidArchive("The cached favorite record has an invalid typed wire shape. Original bytes are retained.") }

    private struct Cursor {
        let bytes: [UInt8]
        let end: Int
        var offset: Int
        mutating func take(_ count: Int) throws -> Range<Int> {
            guard count >= 0, offset <= end, count <= end - offset else { throw ToolsError.invalidArchive("Truncated cached favorite field.") }
            let range = offset..<(offset + count)
            offset += count
            return range
        }
        mutating func byte() throws -> UInt8 {
            let range = try take(1)
            return bytes[range.lowerBound]
        }
        mutating func unsigned(_ count: Int) throws -> UInt64 {
            let range = try take(count)
            var value: UInt64 = 0
            for (index, offset) in range.enumerated() { value |= UInt64(bytes[offset]) << UInt64(index * 8) }
            return value
        }
        mutating func length() throws -> Int {
            let value = Int32(bitPattern: UInt32(try unsigned(4)))
            guard value >= 0 else { throw ToolsError.invalidArchive("Negative cached favorite length.") }
            return Int(value)
        }
        mutating func objectRange() throws -> Range<Int> {
            _ = try take(4) // Type hash is not a type-construction capability.
            let count = try length()
            return try take(count)
        }
        mutating func skip(_ type: UInt8) throws {
            switch type {
            case 0: _ = try take(4)
            case 1, 3: _ = try take(8)
            case 2: _ = try take(1)
            case 4, 10:
                let count = try length()
                _ = try take(count)
            case 5: _ = try objectRange()
            case 6, 7:
                let count = try length(), width = type == 6 ? 4 : 8
                guard count <= (end - offset) / width else { throw ToolsError.sizeLimit }
                _ = try take(count * width)
            case 8, 9:
                let count = try length(), multiplier = type == 9 ? 2 : 1
                guard count <= (end - offset) / (8 * multiplier) else { throw ToolsError.sizeLimit }
                for _ in 0..<(count * multiplier) { _ = try objectRange() }
            case 11: break
            case 12, 13:
                let count = try length()
                guard count <= (end - offset) / 4 else { throw ToolsError.sizeLimit }
                for _ in 0..<count {
                    let size = try length()
                    _ = try take(size)
                }
            default: throw ToolsError.invalidArchive("Invalid cached field type.")
            }
        }
    }

    private func cursor(_ range: Range<Int>) -> Cursor { Cursor(bytes: bytes, end: range.upperBound, offset: range.lowerBound) }
    private func object(_ range: Range<Int>) throws -> Object {
        var c = cursor(range), result: Object = [:]
        while c.offset < c.end {
            guard result.count < 32 else { throw ToolsError.sizeLimit }
            let count = Int(try c.byte())
            let keyBytes = try c.take(count)
            guard let key = String(bytes: bytes[keyBytes], encoding: .utf8), result[key] == nil else { throw invalid }
            let type = try c.byte(), start = c.offset
            try c.skip(type)
            result[key] = Field(type: type, range: start..<c.offset)
        }
        guard c.offset == c.end else { throw invalid }
        return result
    }
    private func object(_ field: Field) throws -> Object {
        guard field.type == 5 else { throw invalid }
        var c = cursor(field.range)
        let range = try c.objectRange()
        guard c.offset == c.end else { throw invalid }
        return try object(range)
    }
    func root() throws -> Object {
        let outer = try object(0..<bytes.count)
        try keys(outer, allowed: ["_"])
        return try object(required(outer, "_"))
    }
    func keys(_ object: Object, allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw invalid }
    }
    func required(_ object: Object, _ key: String) throws -> Field {
        guard let field = object[key], field.type != 11 else { throw invalid }
        return field
    }
    private func optional(_ object: Object, _ key: String) -> Field? {
        guard let field = object[key], field.type != 11 else { return nil }
        return field
    }

    private func integer(_ field: Field) throws -> Int64 {
        var c = cursor(field.range)
        switch field.type {
        case 0: return Int64(Int32(bitPattern: UInt32(try c.unsigned(4))))
        case 1: return Int64(bitPattern: try c.unsigned(8))
        default: throw invalid
        }
    }
    func integer(_ object: Object, _ key: String) throws -> Int64 { try integer(required(object, key)) }
    private func int32(_ object: Object, _ key: String) throws -> Int32 {
        guard let value = Int32(exactly: try integer(object, key)) else { throw invalid }
        return value
    }
    private func bool(_ object: Object, _ key: String) throws -> Bool {
        let field = try required(object, key)
        guard field.type == 2 else { throw invalid }
        var c = cursor(field.range)
        let value = try c.byte()
        guard value <= 1 else { throw invalid }
        return value == 1
    }
    private func string(_ field: Field, maximum: Int) throws -> String {
        guard field.type == 4 else { throw invalid }
        var c = cursor(field.range)
        let count = try c.length()
        guard count <= maximum else { throw ToolsError.sizeLimit }
        let range = try c.take(count)
        guard c.offset == c.end, let value = String(bytes: bytes[range], encoding: .utf8) else { throw invalid }
        return value
    }
    private func string(_ object: Object, _ key: String, maximum: Int) throws -> String { try string(required(object, key), maximum: maximum) }
    func data(_ field: Field, maximum: Int) throws -> Data {
        guard field.type == 10 else { throw invalid }
        var c = cursor(field.range)
        let count = try c.length()
        guard count <= maximum else { throw ToolsError.sizeLimit }
        let range = try c.take(count)
        guard c.offset == c.end else { throw invalid }
        return Data(bytes[range])
    }
    private func canonicalEmptyArray(_ field: Field) throws -> Bool {
        // The actual AdaptedPostbox encoder uses Int32Array(count: 0) for EVERY
        // empty array. Nonempty primitive arrays are never object/string arrays.
        guard field.type == 6 else { return false }
        var c = cursor(field.range)
        return try c.length() == 0 && c.offset == c.end
    }
    func objects(_ field: Field, maximum: Int) throws -> [Object] {
        if try canonicalEmptyArray(field) { return [] }
        guard field.type == 8 else { throw invalid }
        var c = cursor(field.range)
        let count = try c.length()
        guard count <= maximum else { throw ToolsError.sizeLimit }
        var result: [Object] = []
        for _ in 0..<count { result.append(try object(c.objectRange())) }
        guard c.offset == c.end else { throw invalid }
        return result
    }
    func strings(_ field: Field, maximum: Int, stringBytes: Int) throws -> [String] {
        if try canonicalEmptyArray(field) { return [] }
        guard field.type == 12 else { throw invalid }
        var c = cursor(field.range)
        let count = try c.length()
        guard count <= maximum else { throw ToolsError.sizeLimit }
        var result: [String] = []
        for _ in 0..<count {
            let length = try c.length()
            guard length <= stringBytes else { throw ToolsError.sizeLimit }
            guard let value = String(bytes: bytes[try c.take(length)], encoding: .utf8) else { throw invalid }
            result.append(value)
        }
        guard c.offset == c.end else { throw invalid }
        return result
    }

    func sticker(_ value: Object) throws -> ToolsFavoriteSticker {
        try keys(value, allowed: ["id", "datacenterId", "accessHash", "fileReference", "size", "mimeType", "fileName",
                                  "displayText", "width", "height", "pack", "duration", "premium", "noPremium", "aliases"])
        let pack: ToolsFavoriteSticker.Pack?
        if let field = optional(value, "pack") {
            let object = try self.object(field)
            try keys(object, allowed: ["id", "accessHash", "name"])
            let id = try optional(object, "id").map { try integer($0) }
            let hash = try optional(object, "accessHash").map { try integer($0) }
            let name = try optional(object, "name").map { try string($0, maximum: 128) }
            if let id, let hash, name == nil { pack = .init(id: id, accessHash: hash) }
            else if let name, id == nil, hash == nil { pack = .init(name: name) }
            else { throw invalid }
        } else { pack = nil }
        let duration: Double?
        if let field = optional(value, "duration") {
            guard field.type == 3 else { throw invalid }
            var c = cursor(field.range)
            let number = Double(bitPattern: try c.unsigned(8))
            guard number.isFinite else { throw invalid }
            duration = number
        } else { duration = nil }
        let result = try ToolsFavoriteSticker(id: integer(value, "id"), datacenterId: int32(value, "datacenterId"),
            accessHash: integer(value, "accessHash"), fileReference: optional(value, "fileReference").map { try data($0, maximum: 4_096) },
            size: optional(value, "size").map { try integer($0) }, mimeType: string(value, "mimeType", maximum: 64),
            fileName: string(value, "fileName", maximum: 240), displayText: string(value, "displayText", maximum: 512),
            width: int32(value, "width"), height: int32(value, "height"), pack: pack, duration: duration,
            premium: bool(value, "premium"), noPremium: bool(value, "noPremium"),
            aliases: strings(required(value, "aliases"), maximum: 32, stringBytes: 128))
        try result.validate()
        return result
    }
}
