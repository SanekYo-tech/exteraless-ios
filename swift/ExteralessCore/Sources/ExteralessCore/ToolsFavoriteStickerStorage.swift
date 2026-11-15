import Foundation

/// Own preference payload, passed directly to PreferencesEntry(data:). Its decoder
/// receives bounded JSON bytes, never a generic Postbox or FlatBuffer object.
public enum ToolsFavoriteStickerStorage {
    private struct Record: Codable {
        let format: String
        let version: Int
        let userId: Int64
        let stickers: [ToolsFavoriteSticker]
    }

    public static func encode(_ stickers: [ToolsFavoriteSticker], userId: Int64) throws -> Data {
        try ToolsFavoriteStickerArchive(accounts: [String(userId): stickers]).validate()
        var writer = ToolsBoundedJSONWriter(maximumBytes: ToolsFavoriteStickerArchive.maximumBytes)
        try writer.literal("{\"format\":\"exteraless.favorite-store\",\"version\":2,\"userId\":\(userId),\"stickers\":[")
        for (index, sticker) in stickers.enumerated() {
            if index != 0 { try writer.literal(",") }
            try append(sticker, to: &writer)
        }
        try writer.literal("]}")
        return writer.data
    }

    static func append(_ sticker: ToolsFavoriteSticker, to writer: inout ToolsBoundedJSONWriter) throws {
        try sticker.validate()
        let strings = [sticker.mimeType, sticker.fileName, sticker.displayText, sticker.pack?.name ?? ""]
        let stringBytes = strings.reduce(0) { $0 + $1.utf8.count } + sticker.aliases.reduce(0) { $0 + $1.utf8.count }
        // Includes all fixed field names/numbers and worst-case JSON escapes.
        // Validated DTO bounds make this calculation small and non-overflowing.
        let upperBound = 1_024 + stringBytes * 6 + (((sticker.fileReference?.count ?? 0) + 2) / 3) * 4
        guard upperBound <= writer.remaining else { throw ToolsError.sizeLimit }
        try writer.append(ToolsFileSafety.encode(sticker))
    }

    public static func decode(_ data: Data, userId: Int64) throws -> [ToolsFavoriteSticker] {
        try ToolsFileSafety.checkJSON(data, maximumBytes: ToolsFavoriteStickerArchive.maximumBytes, maximumSeparators: 1_500_000)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.format == "exteraless.favorite-store", record.version == 2, record.userId == userId else {
            throw ToolsError.invalidArchive("Invalid local favorite-sticker version/account. Original bytes are retained.")
        }
        try ToolsFavoriteStickerArchive(accounts: [String(userId): record.stickers]).validate()
        return record.stickers
    }
}
