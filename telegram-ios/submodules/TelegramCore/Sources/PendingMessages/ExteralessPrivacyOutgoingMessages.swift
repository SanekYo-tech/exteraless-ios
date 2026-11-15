import ExteralessCore
import Foundation
import Postbox

/// Called once on the native enqueue transaction, after plugin decisions and before
/// enqueueMessages. Original media, rich text, grouping, replies and correlation IDs survive.
func exteralessPrivacyOutgoingMessages(transaction: Transaction, account: Account, peerId: PeerId, messages: [(Bool, EnqueueMessage)]) -> [(Bool, EnqueueMessage)] {
    guard ClientSettings.shared.bool("privacy.ghostScheduledSend") else { return messages }
    let policy = PrivacyPolicy.current
    let peer = transaction.getPeer(peerId)
    let now = Int32(clamping: Int64(account.network.globalTime))
    let isBotOrUnknownUser: Bool
    if peerId.namespace == Namespaces.Peer.CloudUser {
        if let user = peer as? TelegramUser { isBotOrUnknownUser = user.botInfo != nil }
        else { isBotOrUnknownUser = true }
    } else { isBotOrUnknownUser = false }
    return messages.map { transformed, message in
        var special = peer?.isMonoForum == true
        if case let .message(_, _, _, reference, _, _, replyToStoryId, _, _, _) = message {
            if let media = reference?.media, media is TelegramMediaInvoice || media is TelegramMediaGame || media is TelegramMediaStory || media is TelegramMediaPaidContent { special = true }
            if replyToStoryId != nil { special = true }
        }
        for attribute in message.attributes {
            if attribute is OutgoingQuickReplyMessageAttribute || attribute is PaidStarsMessageAttribute || attribute is SuggestedPostMessageAttribute || attribute is EphemeralOutgoingMessageAttribute { special = true }
        }
        guard let date = PrivacyScheduledSendPolicy.scheduleDate(enabled: true, sendsOnline: policy.sendOnlinePackets, now: now, hasExplicitSchedule: message.attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute }), isSelf: peerId == account.peerId, isSecret: peerId.namespace == Namespaces.Peer.SecretChat, isBotOrUnknownUser: isBotOrUnknownUser, isSpecialFlow: special) else { return (transformed, message) }
        return (transformed, message.withUpdatedAttributes { $0 + [OutgoingScheduleInfoMessageAttribute(scheduleTime: date, repeatPeriod: nil)] })
    }
}
