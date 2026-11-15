import Foundation

/// Data-only cloud sticker metadata. Untrusted archives never instantiate arbitrary
/// Postbox/FlatBuffer/TL object types or refer to local filesystem resources.
public struct ToolsFavoriteSticker: Codable, Equatable, Sendable {
    public struct Pack: Codable, Equatable, Sendable {
        public let id: Int64?
        public let accessHash: Int64?
        public let name: String?
        public init(id: Int64, accessHash: Int64) { self.id = id; self.accessHash = accessHash; self.name = nil }
        public init(name: String) { self.id = nil; self.accessHash = nil; self.name = name }
    }
    public let id: Int64
    public let datacenterId: Int32
    public let accessHash: Int64
    public let fileReference: Data?
    public let size: Int64?
    public let mimeType: String
    public let fileName: String
    public let displayText: String
    public let width: Int32
    public let height: Int32
    public let pack: Pack?
    public let duration: Double?
    public let premium: Bool
    public let noPremium: Bool
    public let aliases: [String]

    public init(id: Int64, datacenterId: Int32, accessHash: Int64, fileReference: Data?, size: Int64?, mimeType: String,
                fileName: String, displayText: String, width: Int32, height: Int32, pack: Pack? = nil,
                duration: Double? = nil, premium: Bool = false, noPremium: Bool = false, aliases: [String] = []) {
        self.id = id; self.datacenterId = datacenterId; self.accessHash = accessHash; self.fileReference = fileReference
        self.size = size; self.mimeType = mimeType; self.fileName = fileName; self.displayText = displayText
        self.width = width; self.height = height; self.pack = pack; self.duration = duration
        self.premium = premium; self.noPremium = noPremium; self.aliases = aliases
    }

    public func validate() throws {
        guard id != 0, (1...1_000).contains(datacenterId), (fileReference?.count ?? 0) <= 4_096,
              size.map({ $0 > 0 && $0 <= 64 * 1_024 * 1_024 }) ?? true,
              ["image/webp", "application/x-tgsticker", "video/webm"].contains(mimeType),
              !fileName.isEmpty, fileName.utf8.count <= 240, !fileName.contains("\0"),
              !fileName.contains("/"), !fileName.contains("\\"), fileName != ".", fileName != "..",
              displayText.utf8.count <= 512, (1...8_192).contains(width), (1...8_192).contains(height),
              duration.map({ $0.isFinite && $0 >= 0 && $0 <= 60 }) ?? true,
              aliases.count <= 32, aliases.allSatisfy({ $0.utf8.count <= 128 && !$0.contains("\0") }) else {
            throw ToolsError.invalidArchive("Invalid favorite-sticker metadata.")
        }
        if let pack {
            if let id = pack.id {
                guard id > 0, pack.accessHash != nil, pack.name == nil else { throw ToolsError.invalidArchive("Invalid sticker pack reference.") }
            } else {
                guard let name = pack.name, !name.isEmpty, name.utf8.count <= 128, pack.accessHash == nil,
                      name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
                    throw ToolsError.invalidArchive("Invalid sticker pack name.")
                }
            }
        }
    }
}

public struct ToolsFavoriteStickerArchive: Codable, Equatable, Sendable {
    public static let maximumPerAccount = 10_000
    public static let maximumBytes = 24 * 1_024 * 1_024
    public let version: Int
    /// Original FaveStickersBackup uses Telegram user IDs, not local account slots.
    public let accounts: [String: [ToolsFavoriteSticker]]
    public init(accounts: [String: [ToolsFavoriteSticker]]) { self.version = 1; self.accounts = accounts }

    public func validate() throws {
        guard version == 1, !accounts.isEmpty, accounts.count <= 8 else { throw ToolsError.invalidArchive("Invalid favorite-sticker archive version/accounts.") }
        for (key, stickers) in accounts {
            guard let id = Int64(key), id > 0, String(id) == key, stickers.count <= Self.maximumPerAccount else { throw ToolsError.sizeLimit }
            var seen = Set<Int64>()
            for sticker in stickers {
                try sticker.validate()
                guard seen.insert(sticker.id).inserted else { throw ToolsError.invalidArchive("Duplicate favorite sticker.") }
            }
        }
    }

    public func stickers(for userId: Int64) throws -> [ToolsFavoriteSticker] {
        try validate()
        guard let value = accounts[String(userId)] else { throw ToolsError.invalidArchive("This archive has no favorites for the selected Telegram account.") }
        return value
    }

    public static func merge(current: [ToolsFavoriteSticker], incoming: [ToolsFavoriteSticker]) throws -> [ToolsFavoriteSticker] {
        var seen = Set<Int64>(), merged: [ToolsFavoriteSticker] = []
        for sticker in current + incoming {
            try sticker.validate()
            if seen.insert(sticker.id).inserted { merged.append(sticker) }
        }
        guard merged.count <= maximumPerAccount else { throw ToolsError.sizeLimit }
        return merged
    }

    private struct Envelope: Codable { let format: String; let payload: Data; let sha256: String }
    public func encode() throws -> Data {
        try validate()
        var payload = ToolsBoundedJSONWriter(maximumBytes: (Self.maximumBytes / 4) * 3 - 256)
        try payload.literal("{\"version\":1,\"accounts\":{")
        for (index, account) in accounts.keys.sorted().enumerated() {
            if index != 0 { try payload.literal(",") }
            try payload.string(account); try payload.literal(":[")
            for (index, sticker) in (accounts[account] ?? []).enumerated() {
                if index != 0 { try payload.literal(",") }
                try ToolsFavoriteStickerStorage.append(sticker, to: &payload)
            }
            try payload.literal("]")
        }
        try payload.literal("}}")
        var envelope = ToolsBoundedJSONWriter(maximumBytes: Self.maximumBytes)
        try envelope.literal("{\"format\":\"exteraless.local-favorite-stickers\",\"sha256\":")
        try envelope.string(ToolsSHA256.hex(payload.data)); try envelope.literal(",\"payload\":\"")
        guard ((payload.data.count + 2) / 3) * 4 <= envelope.remaining - 2 else { throw ToolsError.sizeLimit }
        try envelope.append(payload.data.base64EncodedData()); try envelope.literal("\"}")
        return envelope.data
    }
    public static func decode(_ data: Data) throws -> Self {
        try ToolsFileSafety.checkJSON(data, maximumBytes: maximumBytes)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == "exteraless.local-favorite-stickers", envelope.payload.count <= maximumBytes,
              envelope.sha256 == ToolsSHA256.hex(envelope.payload) else { throw ToolsError.checksumMismatch }
        try ToolsFileSafety.checkJSON(envelope.payload, maximumBytes: maximumBytes, maximumSeparators: 1_500_000)
        let archive = try JSONDecoder().decode(Self.self, from: envelope.payload)
        try archive.validate()
        return archive
    }
}
