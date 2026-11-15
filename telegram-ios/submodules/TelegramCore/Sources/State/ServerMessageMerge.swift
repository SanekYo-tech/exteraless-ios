import Foundation
import Postbox

/// The server's copy of a message the account already stores, keeping what the server's copy does not carry:
/// the outgoing live-location tag, the stored Incoming flag, a translation while the server revision and
/// plain/rich source are unchanged, a resolved fact check over a pending one with the same hash, and unlocked paid media.
/// (`SeedConfiguration.mergeMessageAttributes`, which Postbox applies to every update, keeps the rest.)
/// Used by edit updates and by feed pages, which refresh posts the account may already store.
func mergedServerMessageUpdate(previous previousMessage: Message, updated message: StoreMessage) -> StoreMessage {
    var updatedFlags = message.flags
    var updatedLocalTags = message.localTags
    var updatedAttributes = message.attributes
    if previousMessage.localTags.contains(.OutgoingLiveLocation) {
        updatedLocalTags.insert(.OutgoingLiveLocation)
    }
    if previousMessage.flags.contains(.Incoming) {
        updatedFlags.insert(.Incoming)
    } else {
        updatedFlags.remove(.Incoming)
    }

    if exteralessAITranslationSourceUnchanged(previous: previousMessage, updated: message) {
        let previousEntities = previousMessage.textEntitiesAttribute?.entities ?? []
        let updatedEntities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        if previousEntities == updatedEntities, let translation = previousMessage.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute {
            if message.attributes.firstIndex(where: { $0 is TranslationMessageAttribute }) == nil {
                updatedAttributes.append(translation)
            }
        }
    } else {
        // Invalidate payloads, not the server's fresh summary eligibility.
        // A rich-only edit can keep its preview while the server revision changes.
        // The Seed rich-cache merge checks that same revision before restoring full content.
        updatedAttributes = exteralessAIInvalidateDerivedAttributes(updatedAttributes)
    }

    if let previousFactCheckAttribute = previousMessage.attributes.first(where: { $0 is FactCheckMessageAttribute }) as? FactCheckMessageAttribute, let updatedFactCheckAttribute = message.attributes.first(where: { $0 is FactCheckMessageAttribute }) as? FactCheckMessageAttribute {
        if case .Pending = updatedFactCheckAttribute.content, updatedFactCheckAttribute.hash == previousFactCheckAttribute.hash {
            updatedAttributes.removeAll(where: { $0 is FactCheckMessageAttribute })
            updatedAttributes.append(previousFactCheckAttribute)
        }
    }

    var updatedMedia = message.media
    if let previousPaidContent = previousMessage.media.first(where: { $0 is TelegramMediaPaidContent }) as? TelegramMediaPaidContent, case .full = previousPaidContent.extendedMedia.first {
        updatedMedia = previousMessage.media
    }

    return message.withUpdatedLocalTags(updatedLocalTags).withUpdatedFlags(updatedFlags).withUpdatedAttributes(updatedAttributes).withUpdatedMedia(updatedMedia)
}
