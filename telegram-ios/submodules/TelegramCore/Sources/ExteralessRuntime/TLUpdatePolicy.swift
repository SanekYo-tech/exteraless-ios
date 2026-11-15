import Foundation

/// Pure continuity policy used by the state barrier and loginless fixtures.
public enum ExteralessTLUpdatePolicy {
    // Actual control consumers: State/AccountStateManagementUtils, SecretChats,
    // CallSessionManager and Network (DC/config/auth/key negotiation).
    private static let protocolTypes: Set<String> = ["EncryptedMessage", "EncryptedChat", "EncryptedFile",
        "messages.DhConfig", "messages.SentEncryptedMessage", "PhoneCall", "PhoneCallProtocol", "PhoneConnection",
        "Config", "DcOption", "updates.State", "auth.ExportedAuthorization", "auth.Authorization", "auth.LoginToken",
        "SecureValue", "SecureData", "SecureFile", "SecureCredentialsEncrypted"]
    private static let protocolConstructors: Set<String> = ["updateNewEncryptedMessage", "updateEncryptedChatTyping",
        "updateEncryption", "updateEncryptedMessagesRead", "updateGroupCallEncryptedMessage",
        "updatePhoneCall", "updatePhoneCallSignalingData", "updateChannelTooLong", "updatePtsChanged",
        "updateConfig", "updateDcOptions", "updateLoginToken", "upload.fileCdnRedirect"]

    public static func isProtocolConstructor(_ name: String) -> Bool {
        return self.protocolConstructors.contains(name)
            || ExteralessTLCodec.shared.typeOfConstructor(name).map(self.protocolTypes.contains) == true
    }
    private static let channelCounterNames: Set<String> = ["updateDeleteChannelMessages", "updateNewChannelMessage", "updateEditChannelMessage", "updateChannelWebPage", "updatePinnedChannelMessages"]
    public struct ChannelCounter: Equatable, Sendable {
        public let channelId: Int64
        public let pts: Int32
        public let count: Int32
    }

    public static func channelCounter(_ value: ExteralessTLValue) -> ChannelCounter? {
        guard let name = value["_"]?.stringValue,
              self.channelCounterNames.contains(name),
              let pts = value["pts"]?.integerValue.flatMap(Int32.init(exactly:)),
              let count = value["pts_count"]?.integerValue.flatMap(Int32.init(exactly:)) else { return nil }
        let channelId = value["channel_id"]?.integerValue ?? value["message"]?["peer_id"]?["channel_id"]?.integerValue
        guard let channelId, channelId > 0, channelId <= 0x00ff_ffff_ffff_ffff else { return nil }
        return ChannelCounter(channelId: channelId, pts: pts, count: count)
    }

    public static func canMutate(_ value: ExteralessTLValue) -> Bool {
        guard value["_"]?.stringValue != nil else { return false }
        if self.isCounterOnly(value) { return false }
        // Dropping ciphertext consumes qts but also loses a secret-chat sequence or
        // key-exchange step; these are protocol control, not deletable UI effects.
        return !ExteralessTLTransformCodec.hasProtocolSubtree(value)
    }

    public static func isCounterOnly(_ value: ExteralessTLValue) -> Bool {
        guard ["updateDeleteChannelMessages", "updateDeleteMessages"].contains(value["_"]?.stringValue ?? ""),
              case let .array(messages)? = value["messages"] else { return false }
        return messages.isEmpty
    }

    /// Global pts/qts/seq were accepted by finalStateWithUpdateGroups. Channel pts
    /// are accepted later, so preview precisely that ledger before invoking plugins.
    public static func acceptChannel(_ value: ExteralessTLValue, ledger: inout [Int64: Int32]) -> Bool {
        guard let counter = self.channelCounter(value) else {
            return !self.channelCounterNames.contains(value["_"]?.stringValue ?? "")
        }
        guard let previous = ledger[counter.channelId], counter.pts > previous,
              Int64(previous) + Int64(counter.count) == Int64(counter.pts) else { return false }
        ledger[counter.channelId] = counter.pts
        return true
    }

    /// Existing Core represents .updateChannelPts with exactly this native
    /// counter-only update. Empty messages cancel deletion/new/edit semantics while
    /// the SAME original pts and pts_count still traverse Core's continuity check.
    public static func cancelledValue(_ original: ExteralessTLValue) throws -> ExteralessTLValue? {
        guard self.canMutate(original) else { throw ExteralessTLError(.unsupported, "Protocol/encrypted update cancellation is unsupported") }
        guard let counter = self.channelCounter(original) else { return nil }
        return .object(["_": .string("updateDeleteChannelMessages"), "channel_id": .integer(counter.channelId),
            "messages": .array([]), "pts": .integer(Int64(counter.pts)), "pts_count": .integer(Int64(counter.count))])
    }

    /// Container array filtering is an order-preserving subsequence. Counter and
    /// reference identity select the original member; ambiguous changed duplicates
    /// are rejected instead of silently assigning another update's identity.
    public static func matchMembers(original: [ExteralessTLValue], changed: [ExteralessTLValue]) throws -> [Int: ExteralessTLValue] {
        var result: [Int: ExteralessTLValue] = [:]
        var cursor = 0
        for value in changed {
            try ExteralessTLTransformCodec.validateNativeValues(value)
            var candidates: [Int] = []
            for index in cursor ..< original.count {
                if original[index]["_"] != value["_"] { continue }
                do {
                    try ExteralessTLTransformCodec.preserveContinuity(original[index], value)
                    try ExteralessTLTransformCodec.preserveProtocolSubtrees(original[index], value)
                    try ExteralessTLTransformCodec.preserveReferences(original[index], value)
                    candidates.append(index)
                } catch {}
            }
            let exact = candidates.filter { original[$0] == value }
            guard let index = exact.first ?? (candidates.count == 1 ? candidates.first : nil) else {
                throw ExteralessTLError(.malformed, "Container mutation reordered/retargeted or ambiguously matched an update")
            }
            if !self.canMutate(original[index]), original[index] != value {
                throw ExteralessTLError(.unsupported, "Protocol/encrypted update is read-only")
            }
            result[index] = value
            cursor = index + 1
        }
        for index in original.indices where result[index] == nil {
            guard self.canMutate(original[index]) else { throw ExteralessTLError(.unsupported, "Container cannot drop a protocol/encrypted update") }
        }
        return result
    }
}
