import Foundation

/// Field-level compare-and-set keeps two editors from overwriting each other,
/// while an unrelated alias/status change does not invalidate a name-order edit.
public enum IdentityMutation: Sendable {
    case alias(peer: IdentityPeerKey, value: String?, expected: String?)
    case nameOrder(IdentityNameOrder, expected: IdentityNameOrder)
    case localPremium(Bool, expected: Bool)
    case emojiStatus(IdentityEmojiStatus?, expected: IdentityEmojiStatus?)
    case colors(IdentityPeerColors?, expected: IdentityPeerColors?)
    case clearAliases
    case resetPremium
    case resetAll
    case replace(IdentityAccountState, expected: IdentityAccountState)

    public func applying(to state: IdentityAccountState) throws -> IdentityAccountState {
        var result = state
        switch self {
        case let .alias(peer, value, expected):
            guard state.alias(for: peer) == expected else { throw IdentityError.staleEdit }
            try result.setAlias(value, for: peer)
        case let .nameOrder(value, expected):
            guard state.nameOrder == expected else { throw IdentityError.staleEdit }
            result.nameOrder = value
        case let .localPremium(value, expected):
            guard state.localPremium == expected else { throw IdentityError.staleEdit }
            result.localPremium = value
        case let .emojiStatus(value, expected):
            guard state.emojiStatus == expected else { throw IdentityError.staleEdit }
            result.emojiStatus = value
        case let .colors(value, expected):
            guard state.colors == expected else { throw IdentityError.staleEdit }
            result.colors = value
        case .clearAliases: result.clearAliases()
        case .resetPremium: result.resetPremium()
        case .resetAll: result = IdentityAccountState(ownerUserId: state.ownerUserId, testingEnvironment: state.testingEnvironment)
        case let .replace(value, expected):
            guard state == expected else { throw IdentityError.staleEdit }
            guard value.ownerUserId == state.ownerUserId, value.testingEnvironment == state.testingEnvironment else { throw IdentityError.differentAccount }
            result = value
        }
        try result.validate()
        return result
    }
}
