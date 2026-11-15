import Foundation

public enum StickerPinnedReaction: Hashable, Sendable {
    case emoji(String)
    case custom(Int64)

    public var label: String {
        switch self { case let .emoji(value): return value; case let .custom(id): return "Custom emoji \(id)" }
    }
}

public enum StickerReactionPolicy {
    public static let maximumPinnedCount = 7
    public static let maximumJSONBytes = 8192

    public static func isEmoji(_ value: String) -> Bool {
        guard value.count == 1, value.utf16.count <= 32,
              let first = value.unicodeScalars.first, first.properties.isEmoji else { return false }
        return first.value > 127 || value.unicodeScalars.contains(where: { $0.value == 0x20e3 })
    }

    /// Reads the original schema, tolerating individual obsolete entries but
    /// never converting a JSON floating-point ID to an imprecise Int64.
    public static func decode(_ text: String) -> [StickerPinnedReaction] {
        guard text.utf8.count <= maximumJSONBytes,
              let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([ClientSettingValue].self, from: data), values.count <= 64 else { return [] }
        var result: [StickerPinnedReaction] = []
        var seen = Set<StickerPinnedReaction>()
        for value in values {
            guard case let .object(object) = value else { continue }
            let reaction: StickerPinnedReaction
            if case let .string(emoji) = object["emoticon"], isEmoji(emoji) {
                reaction = .emoji(emoji)
            } else if case let .integer(id) = object["document_id"], id > 0 {
                reaction = .custom(id)
            } else if case let .string(text) = object["document_id"], let id = Int64(text), id > 0, String(id) == text {
                reaction = .custom(id)
            } else { continue }
            if seen.insert(reaction).inserted { result.append(reaction) }
            if result.count == maximumPinnedCount { break }
        }
        return result
    }

    public static func encode(_ reactions: [StickerPinnedReaction]) throws -> String {
        guard reactions.count <= maximumPinnedCount, Set(reactions).count == reactions.count else { throw EmojiPackError.invalidReactions }
        let values = try reactions.map { reaction -> ClientSettingValue in
            switch reaction {
            case let .emoji(value):
                guard isEmoji(value) else { throw EmojiPackError.invalidReactions }
                return .object(["emoticon": .string(value)])
            case let .custom(id):
                guard id > 0 else { throw EmojiPackError.invalidReactions }
                return .object(["document_id": .integer(id)])
            }
        }
        let data = try JSONEncoder().encode(values)
        guard let result = String(data: data, encoding: .utf8) else { throw EmojiPackError.invalidReactions }
        return result
    }

    public static func pins(isChannel: Bool, settings: ClientSettings = .shared) -> [StickerPinnedReaction] {
        let suffix = isChannel ? "Channels" : "Chats"
        guard settings.bool("chats.usePinnedReactions\(suffix)") else { return [] }
        return decode(settings.string("chats.pinnedReactions\(suffix)", default: "[]"))
    }

    /// Permission filtering happens before ordering, including custom-emoji
    /// entitlement and the message's maximum distinct-reaction constraint.
    public static func ordered(available: [StickerPinnedReaction], pins: [StickerPinnedReaction], allowed: Set<StickerPinnedReaction>?, canUseCustom: Bool) -> [StickerPinnedReaction] {
        var result: [StickerPinnedReaction] = []
        var seen = Set<StickerPinnedReaction>()
        let availableSet = Set(available)
        for reaction in pins + available {
            guard availableSet.contains(reaction), allowed?.contains(reaction) ?? true else { continue }
            if case .custom = reaction, !canUseCustom { continue }
            if seen.insert(reaction).inserted { result.append(reaction) }
        }
        return result
    }
}
