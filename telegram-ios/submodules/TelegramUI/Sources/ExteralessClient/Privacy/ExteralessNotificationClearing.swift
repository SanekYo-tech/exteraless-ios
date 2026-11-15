import ExteralessCore
import Foundation
import TelegramCore
import UserNotifications

/// The OS is the durable source of posted/pending IDs. Every match includes the
/// receiving account; a message ID from one account never clears another's alert.
enum ExteralessNotificationClearing {
    static func removeReadMessages(accountId: Int64, ids: [EngineMessage.Id]) { remove(accountId: accountId, ids: ids, exact: false) }
    static func removeDeletedMessages(accountId: Int64, ids: [EngineMessage.Id]) { remove(accountId: accountId, ids: ids, exact: true) }
    static func clearAll(accountId: Int64) {
        clear { request in accountIdFromContent(request.content) == accountId }
        PrivacyNotificationDiagnostics.shared.removeAccount(accountId)
    }

    static func hideMessagePreviews() {
        // The app's passcode covers all its accounts. iOS cannot silently edit a
        // delivered APNs alert; remove old message alerts instead of reposting them
        // as new local notifications (which would re-alert watches/accessories).
        let messageCategories: Set<String> = ["unknown", "r", "m", "gr", "gm", "c", "t", "st", "str"]
        clear { request in messageCategories.contains(request.content.categoryIdentifier) || identity(request) != nil }
    }

    private static func remove(accountId: Int64, ids: [EngineMessage.Id], exact: Bool) {
        guard !ids.isEmpty else { return }
        let marks = ids.map { PrivacyNotificationIdentity(accountId: accountId, peerId: $0.peerId.toInt64(), namespace: $0.namespace, messageId: $0.id) }
        clear { request in
            guard let identity = identity(request) else { return false }
            return marks.contains { identity.isCleared(by: $0, exact: exact) }
        }
    }

    private static func number(_ value: Any?) -> Int64? {
        if let string = value as? String { return Int64(string) }
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
    private static func accountIdFromContent(_ content: UNNotificationContent) -> Int64? { number(content.userInfo["accountId"]) }

    private static func identity(_ request: UNNotificationRequest) -> PrivacyNotificationIdentity? {
        guard let accountId = accountIdFromContent(request.content) else { return nil }
        if case let .messageId(id)? = NotificationManagedNotificationRequestId(string: request.identifier) {
            return PrivacyNotificationIdentity(accountId: accountId, peerId: id.peerId.toInt64(), namespace: id.namespace, messageId: id.id)
        }
        let payload = request.content.userInfo
        let peerId: EnginePeer.Id?
        if let value = number(payload["peerId"]) { peerId = EnginePeer.Id(value) }
        else if let value = number(payload["from_id"]) { peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(value)) }
        else if let value = number(payload["chat_id"]) { peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(value)) }
        else if let value = number(payload["channel_id"]) { peerId = EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(value)) }
        else { peerId = nil }
        guard let peerId, let rawId = number(payload["msg_id"]), let id = Int32(exactly: rawId) else { return nil }
        return PrivacyNotificationIdentity(accountId: accountId, peerId: peerId.toInt64(), namespace: Namespaces.Message.Cloud, messageId: id)
    }

    private static func clear(matching: @escaping (UNNotificationRequest) -> Bool) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications.compactMap { matching($0.request) ? $0.request.identifier : nil }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
        center.getPendingNotificationRequests { requests in
            let ids = requests.compactMap { matching($0) ? $0.identifier : nil }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }
}
