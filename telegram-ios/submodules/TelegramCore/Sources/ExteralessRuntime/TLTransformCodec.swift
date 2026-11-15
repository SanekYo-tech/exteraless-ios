import Foundation

/// Validation shared by RPC and accepted-update barriers. It produces actual TL
/// bytes; the original TelegramApi response/parser remains the final type authority.
public enum ExteralessTLTransformCodec {
    public static let continuityFields: Set<String> = ["pts", "pts_count", "qts", "seq", "seq_start", "state", "intermediate_state"]
    // Constructor/field roles, audited against ApiUtils/{StoreMessage_Telegram,
    // TelegramMediaAction,Cached*Participants,ApiGroupOrChannel,TelegramUser},
    // State/AccountStateManagementUtils and the matching swift_scheme.tl records.
    // A long/document/random id is NOT implicitly a PeerId. New constructors do
    // not acquire roles merely by spelling a field "id" or "users".
    static let peerReferenceFields: [String: Set<String>] = {
        let columns: [String: String] = [
            "id": "userEmpty user chatEmpty chat chatForbidden channel channelForbidden communityForbidden community chatFull channelFull communityFull userFull encryptedChatEmpty encryptedChatWaiting encryptedChatRequested encryptedChat encryptedChatDiscarded contacts.editCloseFriends messages.getChats",
            "user_id": "inputPeerUser inputPeerUserFromMessage inputUser inputUserFromMessage peerUser chatParticipant chatParticipantCreator chatParticipantAdmin messageMediaContact messageActionChatDeleteUser contact importedContact contactStatus updateUserTyping updateUserStatus updateUserName updateChatParticipantAdd updateChatParticipantDelete updateUserPhone updateChatParticipantAdmin updateBotInlineQuery updateBotInlineSend updateBotCallbackQuery updateInlineBotCallbackQuery updateBotShippingQuery updateBotPrecheckoutQuery updateChatParticipant updateChannelParticipant updateBotStopped updateBotChatInviteRequester updateUserEmojiStatus updateUser updateBusinessBotCallbackQuery updateBotPurchasedPaidMedia updateChatParticipantRank updateManagedBot updateEphemeralBotCallbackQuery updateBotStarsSubscription updateShortMessage botInfo messageEntityMentionName channelParticipant channelParticipantSelf channelParticipantCreator channelParticipantAdmin highScore textMentionName channelAdminLogEventActionParticipantEditRank channelAdminLogEvent recentMeUrlUser statsGroupTopPoster statsGroupTopAdmin statsGroupTopInviter chatInviteImporter readParticipantDate storyView boost botBusinessConnection missingInvitee requestedPeerUser inlineButtonTypeUserProfile walletUserAddress walletTransactionPeerUser",
            "chat_id": "inputPeerChat peerChat chatParticipantsForbidden chatParticipants messageActionChannelMigrateFrom updateChatUserTyping updateChatParticipantAdd updateChatParticipantDelete updateChatParticipantAdmin updateChat updateChatParticipant updateChatParticipantRank updateShortChatMessage recentMeUrlChat requestedPeerChat messages.getFullChat messages.editChatTitle messages.editChatPhoto messages.addChatUser messages.deleteChatUser messages.editChatAdmin messages.migrateChat messages.deleteChat messages.discardEncryption inputEncryptedChat encryptedMessage encryptedMessageService updateEncryptedChatTyping updateEncryptedMessagesRead",
            "channel_id": "inputPeerChannel inputPeerChannelFromMessage peerChannel messageMediaGiveawayResults messageActionChatMigrateTo updateChannelTooLong updateChannel updateReadChannelInbox updateDeleteChannelMessages updateChannelMessageViews updateReadChannelOutbox updateChannelWebPage updateChannelReadMessagesContents updateChannelAvailableMessages updateChannelMessageForwards updateReadChannelDiscussionInbox updateReadChannelDiscussionOutbox updateChannelUserTyping updatePinnedChannelMessages updateChannelParticipant updateChannelViewForumAsMessages updateReadMonoForumInbox updateReadMonoForumOutbox updateMonoForumNoPaidException inputChannel inputChannelFromMessage messageReplies mediaAreaChannelPost requestedPeerChannel walletTransactionPeerChannel",
            "inviter_id": "chatParticipant chatParticipantAdmin messageActionChatJoinedByLink updateChatParticipantAdd channelParticipantSelf channelParticipantAdmin",
            "actor_id": "updateChatParticipant updateChannelParticipant",
            "admin_id": "encryptedChatWaiting encryptedChatRequested encryptedChat chatInviteExported phoneCallWaiting phoneCallRequested phoneCallAccepted phoneCall chatAdminWithInvites",
            "participant_id": "encryptedChatWaiting encryptedChatRequested encryptedChat phoneCallWaiting phoneCallRequested phoneCallAccepted phoneCall",
            "bot_id": "messageActionManagedBotCreated updateBotCommands updateBotMenuButton updateManagedBot updateNewBotConnection payments.paymentForm payments.paymentFormStars payments.paymentReceipt payments.paymentReceiptStars webAuthorization attachMenuBot connectedBot starRefProgram connectedBotStarRef botVerification messages.chatInviteJoinResultWebView account.getAuthorizationForm account.acceptAuthorization",
            "users": "messageActionChatCreate messageActionChatAddUser messageActionInviteToGroupCall privacyValueAllowUsers privacyValueDisallowUsers businessRecipients businessBotRecipients",
            "chats": "inputPrivacyValueAllowChatParticipants inputPrivacyValueDisallowChatParticipants privacyValueAllowChatParticipants privacyValueDisallowChatParticipants",
            "channels": "messageMediaGiveaway",
            "winners": "messageMediaGiveawayResults",
            "recent_requesters": "chatFull channelFull updatePendingJoinRequests",
            "recent_viewers": "storyViews",
            "exclude_users": "businessBotRecipients",
            "joined_chat_ids": "communities.participantJoinedChats",
            "creator_chat_ids": "communities.participantJoinedChats",
            "other_uids": "account.registerDevice account.unregisterDevice",
            "except_ids": "auth.exportLoginToken auth.initFirebasePnvLogin",
            "top_bidders": "starGiftAuctionState",
            "kicked_by": "channelParticipantBanned",
            "promoted_by": "channelParticipantAdmin",
            "approved_by": "channelAdminLogEventActionParticipantJoinByRequest chatInviteImporter",
            "requested_by": "communityPeerRequest",
            "new_creator_id": "messageActionNewCreatorPending messageActionChangeCreator",
            "auto_setting_from": "messageActionSetMessagesTTL",
            "via_bot_id": "message updateShortMessage updateShortChatMessage",
            "via_business_bot_id": "message",
            "from_id": "updateShortChatMessage",
            "receiver_id": "ephemeralMessage",
            "owner_id": "inputBotInlineMessageID64",
            "author_id": "aiComposeTone",
            "provider_id": "payments.paymentForm payments.paymentReceipt",
            "contact_id": "contactBirthday",
            "user_id_hint": "urlAuthResultRequest",
            "to_id": "payments.checkedGiftCode",
            "business_bot_id": "peerSettings",
            "bot_manager_id": "userFull",
            "guard_bot_id": "channelFull",
            "broadcast_id": "updateReadChannelDiscussionInbox",
            "personal_channel_id": "userFull",
            "migrated_from_chat_id": "channelFull",
            "linked_chat_id": "channelFull",
            "linked_community_id": "user channel",
            "linked_monoforum_id": "channel",
            "community_id": "messageActionChangeCommunity messageActionChatJoinedViaCommunity dialogCommunity notifyCommunity dialogPeerCommunity",
            "admin_disallowed_chat_id": "payments.giveawayInfo",
            "prev_value": "channelAdminLogEventActionChangeLinkedChat",
            "new_value": "channelAdminLogEventActionChangeLinkedChat"
        ]
        var result: [String: Set<String>] = [:]
        for (field, names) in columns {
            for name in names.split(separator: " ") { result[String(name), default: []].insert(field) }
        }
        return result
    }()

    private static let opaqueIdentityTypes: Set<String> = ["Message", "Document", "Photo", "InputDocument", "InputPhoto"]
    private static let peerReferenceTypes: Set<String> = ["Peer", "InputPeer", "InputUser", "InputChannel", "InputEncryptedChat"]
    private static let messageReferenceFields: Set<String> = ["msg_id", "top_msg_id", "reply_to_msg_id"]

    public static func candidate(_ json: String, metadata: ExteralessTLValue, phase: String, canCancel: Bool = true) throws -> ExteralessTLValue {
        guard json.utf8.count <= ExteralessTLCodec.maximumJSONBytes else { throw ExteralessTLError(.limit, "TL hook result exceeds 16 MiB") }
        let value = try ExteralessTLValue(jsonObject: JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]))
        if case let .object(fields) = value, let tl = fields["tl"] {
            let allowed: Set<String> = ["schemaVersion", "observational", "phase", "metadata", "tl", "canCancel", "tlError"]
            guard Set(fields.keys).isSubset(of: allowed), fields["metadata"] == nil || fields["metadata"] == metadata,
                  fields["schemaVersion"] == nil || fields["schemaVersion"] == .integer(1),
                  fields["observational"] == nil || fields["observational"] == .bool(false),
                  fields["phase"] == nil || fields["phase"] == .string(phase),
                  fields["canCancel"] == nil || fields["canCancel"] == .bool(canCancel), fields["tlError"] == nil else {
                throw ExteralessTLError(.malformed, "TL hook attempted to change read-only context/error metadata")
            }
            try self.validateNativeValues(tl)
            return tl
        }
        try self.validateNativeValues(value)
        return value
    }

    public static func request(_ json: String, original: ExteralessTLRequest, metadata: ExteralessTLValue) throws -> ExteralessTLRequest {
        let value = try self.candidate(json, metadata: metadata, phase: "preRequest")
        let result = try ExteralessTLCodec.shared.encodeRequest(value)
        guard result.methodName == original.methodName, result.resultType == original.resultType else {
            throw ExteralessTLError(.malformed, "TL pre hook may not change the method or response type")
        }
        return result
    }

    public static func response(_ json: String, original: ExteralessTLValue, type: String, metadata: ExteralessTLValue) throws -> Data {
        let candidate = try self.candidate(json, metadata: metadata, phase: "postRequest", canCancel: self.canCancelResponse(original))
        let value = try ExteralessTLCodec.shared.normalize(candidate, as: type)
        try self.preserveContinuity(original, value)
        try self.preserveProtocolSubtrees(original, value)
        // Ordinary counter-free RPC vectors have no accepted state snapshot:
        // their schema-valid items may be appended/removed by post hooks.
        if self.hasContinuity(original) || self.hasStateContext(original) {
            try self.preserveReferences(original, value)
        }
        return try ExteralessTLCodec.shared.encode(value, as: type)
    }

    public static func update(_ json: String, original: ExteralessTLValue, metadata: ExteralessTLValue) throws -> Data {
        let candidate = try self.candidate(json, metadata: metadata, phase: "update")
        let value = try ExteralessTLCodec.shared.normalize(candidate, as: "Update")
        guard value["_"] == original["_"] else { throw ExteralessTLError(.malformed, "Update constructor is read-only") }
        try self.preserveContinuity(original, value)
        try self.preserveProtocolSubtrees(original, value)
        try self.preserveReferences(original, value)
        return try ExteralessTLCodec.shared.encode(value, as: "Update")
    }

    public static func canCancelResponse(_ value: ExteralessTLValue) -> Bool {
        return !self.hasContinuity(value) && !self.hasProtocolSubtree(value)
    }

    private static func hasStateContext(_ value: ExteralessTLValue) -> Bool {
        switch value {
        case let .object(fields):
            let type = fields["_"]?.stringValue.flatMap { ExteralessTLCodec.shared.typeOfConstructor($0) }
            if ["Update", "Updates", "updates.State", "updates.Difference", "updates.ChannelDifference"].contains(type ?? "") { return true }
            return fields.values.contains(where: self.hasStateContext)
        case let .array(values): return values.contains(where: self.hasStateContext)
        default: return false
        }
    }

    /// Numeric qts is not a substitute for the secret operation which consumes it.
    /// This runs in post validation, before the caller's original native parser.
    public static func hasProtocolSubtree(_ value: ExteralessTLValue) -> Bool {
        switch value {
        case let .object(fields):
            if let name = fields["_"]?.stringValue, ExteralessTLUpdatePolicy.isProtocolConstructor(name) { return true }
            return fields.values.contains(where: self.hasProtocolSubtree)
        case let .array(values): return values.contains(where: self.hasProtocolSubtree)
        default: return false
        }
    }

    public static func preserveProtocolSubtrees(_ original: ExteralessTLValue, _ replacement: ExteralessTLValue) throws {
        guard self.hasProtocolSubtree(original) || self.hasProtocolSubtree(replacement) else { return }
        switch (original, replacement) {
        case let (.object(old), .object(new)):
            if old["_"]?.stringValue.map(ExteralessTLUpdatePolicy.isProtocolConstructor) == true
                || new["_"]?.stringValue.map(ExteralessTLUpdatePolicy.isProtocolConstructor) == true {
                guard original == replacement else { throw ExteralessTLError(.unsupported, "Encrypted/protocol payload is read-only") }
                return
            }
            for key in Set(old.keys).union(new.keys) {
                try self.preserveProtocolSubtrees(old[key] ?? .null, new[key] ?? .null)
            }
        case let (.array(old), .array(new)):
            guard old.count == new.count else { throw ExteralessTLError(.unsupported, "Protocol operation vector size is read-only") }
            for (before, after) in zip(old, new) { try self.preserveProtocolSubtrees(before, after) }
        default: throw ExteralessTLError(.unsupported, "Protocol operation was inserted or removed")
        }
    }

    public static func hasContinuity(_ value: ExteralessTLValue) -> Bool {
        switch value {
        case let .object(fields):
            return !Set(fields.keys).isDisjoint(with: self.continuityFields) || fields.values.contains(where: self.hasContinuity)
        case let .array(values): return values.contains(where: self.hasContinuity)
        default: return false
        }
    }

    /// Never let a post hook erase/reorder a counter-bearing node, including a
    /// whole Updates/Difference response. Semantic cancellation belongs after the
    /// state manager's continuity acceptance, not in the raw RPC response channel.
    public static func preserveContinuity(_ original: ExteralessTLValue, _ replacement: ExteralessTLValue) throws {
        switch (original, replacement) {
        case let (.object(fields), .object(changed)):
            if self.hasContinuity(original) || self.hasContinuity(replacement) {
                guard fields["_"] == changed["_"] else {
                    throw ExteralessTLError(.malformed, "TL continuity constructor is read-only")
                }
            }
            for key in Set(fields.keys).union(changed.keys) {
                if self.continuityFields.contains(key) {
                    guard changed[key] == fields[key] else { throw ExteralessTLError(.malformed, "TL continuity field \(key) is read-only") }
                } else if fields[key].map(self.hasContinuity) == true || changed[key].map(self.hasContinuity) == true {
                    guard let previous = fields[key], let next = changed[key] else {
                        throw ExteralessTLError(.malformed, "TL continuity subtree was added or removed")
                    }
                    try self.preserveContinuity(previous, next)
                }
            }
        case let (.array(values), .array(changed)) where values.contains(where: self.hasContinuity) || changed.contains(where: self.hasContinuity):
            guard changed.count == values.count else {
                throw ExteralessTLError(.malformed, "TL continuity vector size is read-only")
            }
            for (old, new) in zip(values, changed) {
                try self.preserveContinuity(old, new)
                if self.hasContinuity(old) || self.hasContinuity(new) { try self.preserveReferences(old, new) }
            }
        default:
            if self.hasContinuity(original) || self.hasContinuity(replacement) {
                throw ExteralessTLError(.malformed, "TL continuity value was added or removed")
            }
        }
    }

    /// Update state was initialized from the ORIGINAL references. Retargeting a
    /// peer/message after that snapshot would bypass peer resolution/version checks.
    public static func preserveReferences(_ original: ExteralessTLValue, _ replacement: ExteralessTLValue) throws {
        guard self.referenceShape(original) == self.referenceShape(replacement) else {
            throw ExteralessTLError(.malformed, "Native peer/message/media reference roles are read-only")
        }
    }

    private static func referenceShape(_ value: ExteralessTLValue) -> ExteralessTLValue? {
        switch value {
        case let .object(fields):
            let name = fields["_"]?.stringValue ?? ""
            let type = ExteralessTLCodec.shared.typeOfConstructor(name)
            // Self/empty references have no numeric id but still select a distinct
            // native reference role; access hashes/from-message paths belong to it.
            if self.peerReferenceTypes.contains(type ?? "") { return value }
            var roles = self.peerReferenceFields[name] ?? []
            if self.opaqueIdentityTypes.contains(type ?? "") { roles.insert("id") }
            roles.formUnion(self.messageReferenceFields)
            var result: [String: ExteralessTLValue] = [:]
            for (key, child) in fields where key != "_" {
                if roles.contains(key) { result[key] = child }
                else if let nested = self.referenceShape(child) { result[key] = nested }
            }
            guard !result.isEmpty else { return nil }
            result["_"] = fields["_"]
            return .object(result)
        case let .array(values):
            let result = values.map(self.referenceShape)
            return result.contains(where: { $0 != nil }) ? .array(result.map { $0 ?? .null }) : nil
        default: return nil
        }
    }

    private static func validatePeerRole(_ value: ExteralessTLValue) throws {
        switch value {
        case let .integer(id):
            // Postbox's negative branch uses 55 magnitude bits; never abs(Int64.min).
            guard id >= -0x007f_ffff_ffff_ffff, id <= 0x00ff_ffff_ffff_ffff else {
                throw ExteralessTLError(.malformed, "TL peer role exceeds native PeerId range")
            }
        case let .array(values):
            for value in values { try self.validatePeerRole(value) }
        default: throw ExteralessTLError(.malformed, "TL peer role must contain integer ids")
        }
    }

    /// Edit DTOs may omit caption: validate structure now, then validate ranges
    /// against the actual cached text in the native edit transaction's continuation.
    /// nil means unknown text, while "" is an explicitly empty caption.
    public static func mediaEntityBodies(_ values: [ExteralessTLValue], caption: String?) throws -> [Data] {
        guard values.count <= 100, (caption?.utf16.count ?? 0) <= 4096 else {
            throw ExteralessTLError(.limit, "Media caption/entity count exceeds its limit")
        }
        let supported: Set<String> = ["messageEntityMention", "messageEntityHashtag", "messageEntityBotCommand",
            "messageEntityUrl", "messageEntityEmail", "messageEntityBold", "messageEntityItalic", "messageEntityCode",
            "messageEntityPre", "messageEntityTextUrl", "messageEntityMentionName", "messageEntityUnderline",
            "messageEntityStrike", "messageEntityBlockquote", "messageEntityBankCard", "messageEntityTonAddress",
            "messageEntitySpoiler", "messageEntityCustomEmoji", "messageEntityFormattedDate"]
        let utf16 = caption.map { Array($0.utf16) }
        return try values.map { value in
            guard let name = value["_"]?.stringValue, supported.contains(name) else {
                throw ExteralessTLError(.unsupported, "Unsupported or receive-only MessageEntity")
            }
            guard let offset = value["offset"]?.integerValue, let length = value["length"]?.integerValue,
                  offset >= 0, length > 0, offset <= Int64(Int32.max), length <= Int64(Int32.max) - offset else {
                throw ExteralessTLError(.malformed, "Media entity range exceeds native Int32 range")
            }
            if let utf16 {
                func boundary(_ i: Int) -> Bool { i == 0 || i == utf16.count || !(0xdc00 ... 0xdfff).contains(utf16[i]) }
                guard offset <= Int64(utf16.count), length <= Int64(utf16.count) - offset,
                      boundary(Int(offset)), boundary(Int(offset + length)) else {
                    throw ExteralessTLError(.malformed, "Media entity range is outside the caption/UTF-16 boundary")
                }
            }
            try self.validateNativeValues(value)
            let data = try ExteralessTLCodec.shared.encode(value, as: "MessageEntity")
            if name == "messageEntityFormattedDate" {
                let normalized = try ExteralessTLCodec.shared.decode(data, as: "MessageEntity")
                let flags = normalized["flags"]?.integerValue ?? 0
                guard (flags & 1 == 0 || flags & ~1 == 0), flags & 6 != 6, flags & 24 != 24 else {
                    throw ExteralessTLError(.malformed, "Conflicting formatted-date flags")
                }
            }
            return data
        }
    }

    /// These schema-valid values otherwise reach Swift conversions which assert
    /// PeerId's 56-bit range or add entity offsets with trapping Int32 arithmetic.
    public static func validateNativeValues(_ value: ExteralessTLValue) throws {
        switch value {
        case var .object(fields):
            let name = fields["_"]?.stringValue ?? ""
            let type = ExteralessTLCodec.shared.typeOfConstructor(name)
            if (self.peerReferenceFields[name] ?? []).contains(where: { fields[$0] == .null }) {
                // Resolve optional absence through the REAL declared flags first.
                // Required null and enabled-bit+null still fail in the codec;
                // there is no blanket null exemption in the peer-role validator.
                let codec = ExteralessTLCodec.shared
                let normalized: ExteralessTLValue
                if let type {
                    normalized = try codec.normalize(.object(fields), as: type)
                } else {
                    normalized = try codec.decodeRequest(codec.encodeRequest(.object(fields)).body)
                }
                guard case let .object(canonical) = normalized else { throw ExteralessTLError(.malformed, "TL reference object normalization failed") }
                fields = canonical
            }
            for field in self.peerReferenceFields[name] ?? [] {
                if let value = fields[field] { try self.validatePeerRole(value) }
            }
            if ["User", "Chat"].contains(type ?? ""), let id = fields["id"]?.integerValue,
               id <= 0 || id > 0x00ff_ffff_ffff_ffff {
                throw ExteralessTLError(.malformed, "TL peer object exceeds native PeerId range")
            }
            if ["Peer", "InputPeer", "InputUser", "InputChannel"].contains(type ?? "") {
                for key in ["user_id", "chat_id", "channel_id"] {
                    if let id = fields[key]?.integerValue, id <= 0 || id > 0x00ff_ffff_ffff_ffff {
                        throw ExteralessTLError(.malformed, "TL peer reference exceeds native PeerId range")
                    }
                }
            }
            if type == "MessageEntity", let offset = fields["offset"]?.integerValue, let length = fields["length"]?.integerValue {
                guard offset >= 0, length >= 0, offset <= Int64(Int32.max), length <= Int64(Int32.max) - offset else {
                    throw ExteralessTLError(.malformed, "TL entity range exceeds native Int32 range")
                }
                if let userId = fields["user_id"]?.integerValue, userId <= 0 || userId > 0x00ff_ffff_ffff_ffff {
                    throw ExteralessTLError(.malformed, "TL mention id exceeds native PeerId range")
                }
            }
            for child in fields.values { try self.validateNativeValues(child) }
        case let .array(values):
            for child in values { try self.validateNativeValues(child) }
        default: break
        }
    }
}
