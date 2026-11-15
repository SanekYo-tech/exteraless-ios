import Foundation

public enum FilteringNotificationDisposition: Equatable, Sendable {
    case allow, suppress, awaitMessage
}

public extension FilteringDecision {
    /// Presentation may retain an undecided history row, but an incomplete regex
    /// is never permission to deliver its text, sound, attachments or sender intent.
    var notificationDisposition: FilteringNotificationDisposition {
        if isHidden { return .suppress }
        return incomplete ? .awaitMessage : .allow
    }
}
