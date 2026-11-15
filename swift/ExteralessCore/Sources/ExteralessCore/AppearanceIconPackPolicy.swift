import Foundation

public enum AppearanceIconPackError: Error, LocalizedError, Equatable, Sendable {
    case invalidArchive, unsafePath, sizeLimit, unsupportedCompression, checksum, invalidMetadata
    case alreadyInstalled, missingPack, unsupportedImage

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The icon archive is malformed."
        case .unsafePath: return "The icon pack contains an unsafe or duplicate path."
        case .sizeLimit: return "The icon pack exceeds the supported size limits."
        case .unsupportedCompression: return "This archive compression is not supported."
        case .checksum: return "An icon-pack file failed its checksum."
        case .invalidMetadata: return "The icon pack needs valid schema-version-1 metadata.json."
        case .alreadyInstalled: return "A pack with this ID is already installed. Remove it before importing a replacement."
        case .missingPack: return "The selected icon pack is no longer installed."
        case .unsupportedImage: return "Use a PNG, JPEG, WebP or SVG image for an in-app icon."
        }
    }
}

/// Byte-compatible with app.exteraless.icons.IconPack.toJson().
public struct AppearanceIconPackMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var packId: String
    public var packName: String
    public var author: String
    public var version: String
    public var icons: [String: String]

    public init(packId: String, packName: String, author: String = "", version: String = "1.0", icons: [String: String] = [:]) {
        self.schemaVersion = 1
        self.packId = packId
        self.packName = packName
        self.author = author
        self.version = version
        self.icons = icons
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, packId, packName, author, version, icons }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        packId = try values.decode(String.self, forKey: .packId)
        packName = try values.decode(String.self, forKey: .packName)
        author = try values.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        icons = try values.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
    }

    public func validate() throws {
        guard schemaVersion == 1, Self.isIdentifier(packId), !packName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              packName.utf8.count <= 256, author.utf8.count <= 256, version.utf8.count <= 128,
              icons.count <= 2000 else { throw AppearanceIconPackError.invalidMetadata }
        for (key, path) in icons {
            guard !key.isEmpty, key.utf8.count <= 256, !key.contains("\0") else { throw AppearanceIconPackError.invalidMetadata }
            try AppearanceIconArchive.validatePath(path)
            guard ["png", "jpg", "jpeg", "webp", "svg"].contains((path as NSString).pathExtension.lowercased()) else {
                throw AppearanceIconPackError.unsupportedImage
            }
        }
    }

    public static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }
}

public enum AppearanceIconPackPolicy {
    public static func activeIds(_ raw: String) -> [String] {
        var result: [String] = []
        for token in raw.prefix(8192).split(separator: ",").prefix(100) {
            let id = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if AppearanceIconPackMetadata.isIdentifier(id), !result.contains(id) { result.append(id) }
        }
        return result
    }

    /// First active pack wins per resource; missing resources fall through to the
    /// next pack, then the native base icon. Never replace the default globally.
    public static func owners(activeIds: [String], packs: [AppearanceIconPackMetadata], enabled: Bool) -> [String: String] {
        guard enabled else { return [:] }
        var result: [String: String] = [:]
        for id in activeIds {
            guard let pack = packs.first(where: { $0.packId == id }) else { continue }
            for key in pack.icons.keys {
                let canonical = AppearanceIconNames.mapping(for: key)?.asset ?? key
                if result[canonical] == nil { result[canonical] = id }
            }
        }
        return result
    }

    public static func toggled(_ id: String, in ids: [String]) -> [String] {
        if ids.contains(id) { return ids.filter { $0 != id } }
        return [id] + ids
    }
}

/// Explicit Android drawable -> live iOS asset mapping. Unknown Android resources
/// stay in imported metadata/export, but are not reported as working replacements.
public enum AppearanceIconNames {
    public struct Mapping: Sendable {
        public let asset: String
        public let android: String
        public let symbol: String
    }

    public static let mappings: [Mapping] = [
        .init(asset: "Chat List/Tabs/IconChats", android: "msg_discussion", symbol: "bubble.left.and.bubble.right"),
        .init(asset: "Chat List/Tabs/IconContacts", android: "msg_contacts", symbol: "person.crop.circle"),
        .init(asset: "Chat List/Tabs/IconCalls", android: "msg_calls", symbol: "phone"),
        .init(asset: "Chat List/Tabs/IconSettings", android: "msg_settings", symbol: "gearshape"),
        .init(asset: "Chat/Context Menu/Delete", android: "msg_delete", symbol: "trash"),
        .init(asset: "Chat/Context Menu/Copy", android: "msg_copy", symbol: "doc.on.doc"),
        .init(asset: "Chat/Context Menu/Edit", android: "msg_edit", symbol: "pencil"),
        .init(asset: "Chat/Context Menu/Reply", android: "msg_reply", symbol: "arrowshape.turn.up.left"),
        .init(asset: "Chat/Context Menu/Forward", android: "msg_forward", symbol: "arrowshape.turn.up.right"),
        .init(asset: "Chat/Context Menu/Share", android: "msg_share", symbol: "square.and.arrow.up"),
        .init(asset: "Chat/Context Menu/Select", android: "msg_select", symbol: "checkmark.circle"),
        .init(asset: "Chat/Context Menu/Search", android: "msg_search", symbol: "magnifyingglass"),
        .init(asset: "Chat/Context Menu/Pin", android: "msg_pin", symbol: "pin"),
        .init(asset: "Chat/Context Menu/Unpin", android: "msg_unpin", symbol: "pin.slash"),
        .init(asset: "Chat/Context Menu/MarkAsRead", android: "msg_markread", symbol: "checkmark.bubble"),
        .init(asset: "Chat/Context Menu/MarkAsUnread", android: "msg_markunread", symbol: "bubble.left.badge.exclamationmark"),
        .init(asset: "Chat/Context Menu/Archive", android: "msg_archive", symbol: "archivebox"),
        .init(asset: "Chat/Context Menu/Unarchive", android: "msg_unarchive", symbol: "tray.and.arrow.up"),
        .init(asset: "Chat/Context Menu/Muted", android: "msg_mute", symbol: "bell.slash"),
        .init(asset: "Chat/Context Menu/Unmute", android: "msg_unmute", symbol: "bell"),
        .init(asset: "Chat/Context Menu/Info", android: "msg_info", symbol: "info.circle"),
        .init(asset: "Chat/Context Menu/Statistics", android: "msg_stats", symbol: "chart.bar"),
        .init(asset: "Chat/Context Menu/Report", android: "msg_report", symbol: "exclamationmark.bubble"),
        .init(asset: "Chat/Context Menu/Schedule", android: "input_schedule", symbol: "clock"),
        .init(asset: "Chat/Context Menu/Calendar", android: "msg_calendar", symbol: "calendar"),
        .init(asset: "Chat/Context Menu/Resend", android: "msg_retry", symbol: "arrow.clockwise"),
        .init(asset: "Chat/Context Menu/User", android: "msg_openprofile", symbol: "person"),
        .init(asset: "Chat/Context Menu/AddUser", android: "msg_contact_add", symbol: "person.badge.plus"),
        .init(asset: "Chat/Context Menu/Call", android: "profile_phone", symbol: "phone"),
        .init(asset: "Chat/Context Menu/VideoCall", android: "profile_video", symbol: "video"),
        .init(asset: "Chat/Context Menu/Link", android: "msg_link", symbol: "link"),
        .init(asset: "Chat/Context Menu/Browser", android: "msg_instant", symbol: "safari"),
        .init(asset: "Chat/Context Menu/Globe", android: "msg_language", symbol: "globe"),
        .init(asset: "Chat/Context Menu/Save", android: "msg_saved", symbol: "bookmark"),
        .init(asset: "Chat/Context Menu/Fave", android: "msg_fave", symbol: "star"),
        .init(asset: "Chat/Context Menu/Unfave", android: "msg_unfave", symbol: "star.slash"),
        .init(asset: "Chat/Context Menu/Sticker", android: "msg_sticker", symbol: "face.smiling"),
        .init(asset: "Chat/Context Menu/Translate", android: "msg_translate", symbol: "character.bubble")
    ]

    public static func mapping(for name: String) -> Mapping? {
        mappings.first { $0.asset == name || $0.android == name }
    }
}
