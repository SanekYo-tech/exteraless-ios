import ExteralessCore
import Foundation
import TelegramCore

/// Every native producer uses this boundary. An absent override preserves a
/// previous decision, including audible false; defaults are resolved only once.
struct ExteralessChatSendOptions {
    let silentPosting: Bool?
    let nativeSilent: Bool
    let defaultSilent: Bool
    var scheduleTime: Int32? = nil
    var repeatPeriod: Int32? = nil

    func applying(to message: EnqueueMessage) -> EnqueueMessage {
        let existing = message.attributes.compactMap { $0 as? NotificationInfoMessageAttribute }.first
        let silent = silentPosting ?? existing.map { $0.flags.contains(.muted) } ?? (nativeSilent || defaultSilent)
        return message.withNotificationOverride(silent: silent).withUpdatedAttributes { attributes in
            guard let scheduleTime else { return attributes }
            var attributes = attributes.filter { !($0 is OutgoingScheduleInfoMessageAttribute) }
            attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: repeatPeriod))
            return attributes
        }
    }

    static func scheduleSilent(nativeSilent: Bool, defaultSilent: Bool, explicit: Bool? = nil) -> Bool {
        explicit ?? (nativeSilent || defaultSilent)
    }
    static func existingSilent(in messages: [EnqueueMessage]) -> Bool? {
        guard let message = messages.first, let info = message.attributes.compactMap({ $0 as? NotificationInfoMessageAttribute }).first else { return nil }
        return info.flags.contains(.muted)
    }
}
