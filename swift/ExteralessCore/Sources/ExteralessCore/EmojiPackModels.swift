import Foundation

public enum EmojiPackError: Error, Equatable, LocalizedError, Sendable {
    case invalidFont(String), incompatibleFont, registrationFailed, invalidCatalog, invalidURL
    case tooLarge, checksumMismatch, invalidCache, quota, sourceUnavailable, downloadsDisabled
    case http(Int), network, storage, cancelled, invalidReactions, invalidMedia

    public var errorDescription: String? {
        switch self {
        case let .invalidFont(reason): return "Invalid emoji font: \(reason)."
        case .incompatibleFont: return "This font format cannot be rendered by the supported iOS font pipeline. Use a TrueType/OpenType outline, sbix, or COLR v0 font."
        case .registrationFailed: return "CoreText could not register this emoji font or render its emoji glyphs. It was not installed."
        case .invalidCatalog: return "The emoji catalog is invalid. The last valid catalog has been kept."
        case .invalidURL: return "Choose an HTTPS .ttf or .otf URL without credentials or a fragment."
        case .tooLarge: return "The font or metadata exceeds its size limit."
        case .checksumMismatch: return "The font SHA-256 does not match. The existing pack has been kept."
        case .invalidCache: return "Stored emoji data is invalid. It has not been overwritten."
        case .quota: return "The local library is full. Remove an item before adding another."
        case .sourceUnavailable: return "The selected emoji source is unavailable."
        case .downloadsDisabled: return "Enable Download Emoji Packs to use remote sources."
        case let .http(status): return "The font server returned HTTP \(status)."
        case .network: return "The download failed. Try again when a connection is available."
        case .storage: return "The local sticker library could not be saved."
        case .cancelled: return "The operation was cancelled."
        case .invalidReactions: return "Choose up to seven different emoji reactions."
        case .invalidMedia: return "This file cannot be used as a sticker or saved GIF."
        }
    }
}

public enum EmojiPackLimits {
    public static let fontBytes = 32 * 1024 * 1024
    public static let catalogBytes = 256 * 1024
    public static let catalogCount = 64
    public static let installedCount = 16
    public static let libraryBytes = 96 * 1024 * 1024
}

public struct EmojiCatalogEntry: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: Int
    public let file: Int32
    public let preview: Int32?
    public let sha256: String?

    public init(id: String, name: String, version: Int, file: Int32, preview: Int32? = nil, sha256: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.file = file; self.preview = preview; self.sha256 = sha256
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 80,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              (1...1_000_000).contains(version), file > 0, preview == nil || preview! > 0,
              sha256 == nil || EmojiFontInspection.isSHA256(sha256!) else { throw EmojiPackError.invalidCatalog }
    }
}

public struct EmojiCatalog: Codable, Equatable, Sendable {
    public static let source = "nagramx_remote_metadata"
    public static let channelId: Int64 = 2_477_822_904
    public let source: String
    public let fetchedAt: Date
    public let entries: [EmojiCatalogEntry]

    public init(source: String = EmojiCatalog.source, fetchedAt: Date, entries: [EmojiCatalogEntry]) throws {
        self.source = source; self.fetchedAt = fetchedAt; self.entries = entries
        try self.validate()
    }

    public func validate() throws {
        guard source == Self.source, fetchedAt.timeIntervalSince1970.isFinite,
              entries.count <= EmojiPackLimits.catalogCount, Set(entries.map(\.id)).count == entries.count else { throw EmojiPackError.invalidCatalog }
        try entries.forEach { try $0.validate() }
    }

    public static func parse(message: String, now: Date = Date()) throws -> EmojiCatalog {
        guard message.hasPrefix("#emojiv2"), message.utf8.count <= EmojiPackLimits.catalogBytes else { throw EmojiPackError.invalidCatalog }
        let body = String(message.dropFirst("#emojiv2".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        struct Root: Decodable { let emojis: [EmojiCatalogEntry] }
        guard let data = body.data(using: .utf8), let root = try? JSONDecoder().decode(Root.self, from: data) else { throw EmojiPackError.invalidCatalog }
        return try EmojiCatalog(fetchedAt: now, entries: root.emojis)
    }
}

public enum EmojiFontOrigin: Codable, Equatable, Sendable {
    case imported
    case https(String)
    case telegram(source: String, messageId: Int32)
    case bundled(source: String, license: String)

    public var label: String {
        switch self {
        case .imported: return "Imported from Files"
        case let .https(url): return url
        case let .telegram(source, id): return "https://t.me/\(source)/\(id)"
        case let .bundled(source, license): return "\(source) · \(license)"
        }
    }
}

/// Describes stored bytes, not an assertion of successful registration on the
/// current OS. The renderer is the only authority for an applied font.
public struct EmojiStoredPack: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: Int
    public let sha256: String
    public let byteCount: Int
    public let fileExtension: String
    public let origin: EmojiFontOrigin
    public let license: String?
    public let addedAt: Date
}
