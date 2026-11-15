import Foundation

public enum IdentityArchive {
    public static func encode(_ state: IdentityAccountState) throws -> Data {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= IdentityAccountState.maximumEncodedBytes else { throw IdentityError.quotaExceeded }
        return data
    }

    public static func decode(_ data: Data, owner: IdentityAccountId) throws -> IdentityAccountState {
        guard data.count <= IdentityAccountState.maximumEncodedBytes else { throw IdentityError.quotaExceeded }
        let state: IdentityAccountState
        do { state = try JSONDecoder().decode(IdentityAccountState.self, from: data) }
        catch { throw IdentityError.invalidData }
        try state.validate(owner: owner)
        return state
    }

    /// An explicit one-account import, never fan-out of Android's old global
    /// fallback into every logged-in account. These records contain no RPC data.
    public static func importAndroid(statusJSON: String?, colorsJSON: String?, into state: IdentityAccountState) throws -> IdentityAccountState {
        var result = state
        if let text = statusJSON {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.emojiStatus = nil
            } else {
                let value = try object(text, allowed: ["documentId", "until"])
                let id = try optionalInteger(value["documentId"])
                let until = try optionalInteger(value["until"])
                if let until, Int32(exactly: until) == nil || until < 0 { throw IdentityError.invalidData }
                result.emojiStatus = id.flatMap { $0 == 0 ? nil : IdentityEmojiStatus(documentId: $0, until: until.flatMap(Int32.init(exactly:))) }
            }
        }
        if let text = colorsJSON {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.colors = nil
            } else {
                let value = try object(text, allowed: ["colorId", "emojiId", "profileColorId", "profileEmojiId"])
                let color = try optionalInteger(value["colorId"])
                let profile = try optionalInteger(value["profileColorId"])
                guard color == nil || (color! >= 0 && Int32(exactly: color!) != nil),
                      profile == nil || (profile! >= -1 && Int32(exactly: profile!) != nil) else { throw IdentityError.invalidData }
                result.colors = IdentityPeerColors(colorId: color.map(Int32.init), emojiId: try optionalInteger(value["emojiId"]),
                    profileColorId: profile.map(Int32.init), profileEmojiId: try optionalInteger(value["profileEmojiId"]))
            }
        }
        try result.validate()
        return result
    }

    /// Lossless Int64 JSON: using ClientSettingValue avoids JSONSerialization's
    /// NSNumber/Double coercion of document IDs above 2^53.
    private static func object(_ text: String, allowed: Set<String>) throws -> [String: ClientSettingValue] {
        guard text.utf8.count <= 4096 else { throw IdentityError.quotaExceeded }
        guard let value = try? JSONDecoder().decode(ClientSettingValue.self, from: Data(text.utf8)),
              case let .object(object) = value, Set(object.keys).isSubset(of: allowed) else { throw IdentityError.invalidData }
        return object
    }

    private static func optionalInteger(_ value: ClientSettingValue?) throws -> Int64? {
        switch value {
        case nil, .null?: return nil
        case let .integer(value)?: return value
        case let .string(value)?:
            guard let integer = Int64(value), String(integer) == value else { throw IdentityError.invalidData }
            return integer
        default: throw IdentityError.invalidData
        }
    }
}
