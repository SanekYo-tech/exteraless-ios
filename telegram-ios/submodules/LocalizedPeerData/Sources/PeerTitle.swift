import Foundation
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
//import PhoneNumberFormat

public extension EnginePeer {
    func exteralessDisplayTitle(account: Account, strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> String {
        return self.exteralessDisplayTitle(identity: exteralessIdentityPresentation(account: account, peer: self), strings: strings, displayOrder: displayOrder)
    }

    func exteralessCompactDisplayTitle(account: Account) -> String {
        return self.exteralessCompactDisplayTitle(identity: exteralessIdentityPresentation(account: account, peer: self))
    }

    /// The same final formatter is used with an immutable account-scoped snapshot
    /// by layout code and loginless native fixtures. Filtering is after alias and
    /// name-order composition, never a mutation of the peer or stored alias.
    func exteralessDisplayTitle(identity: ExteralessPeerIdentityPresentation, strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> String {
        if let name = identity.name { return exteralessZalgoDisplayText(name) }
        return self.displayTitle(strings: strings, displayOrder: displayOrder)
    }

    func exteralessCompactDisplayTitle(identity: ExteralessPeerIdentityPresentation) -> String {
        if let name = identity.compactName { return exteralessZalgoDisplayText(name) }
        return self.compactDisplayTitle
    }

    var compactDisplayTitle: String {
        switch self {
        case let .user(user):
            if let firstName = user.firstName, !firstName.isEmpty {
                return exteralessZalgoDisplayText(firstName)
            } else if let lastName = user.lastName, !lastName.isEmpty {
                return exteralessZalgoDisplayText(lastName)
            } else if let _ = user.phone {
                return "" //formatPhoneNumber("+\(phone)")
            } else {
                return "Deleted Account"
            }
        case let .legacyGroup(group):
            return exteralessZalgoDisplayText(group.title)
        case let .channel(channel):
            return exteralessZalgoDisplayText(channel.title)
        case let .community(community):
            return exteralessZalgoDisplayText(community.title)
        case .secretChat:
            return ""
        }
    }

    func displayTitle(strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> String {
        switch self {
        case let .user(user):
            if user.id.isReplies {
                return strings.DialogList_Replies
            }
            if let firstName = user.firstName, !firstName.isEmpty {
                if let lastName = user.lastName, !lastName.isEmpty {
                    switch displayOrder {
                    case .firstLast:
                        return exteralessZalgoDisplayText("\(firstName) \(lastName)")
                    case .lastFirst:
                        return exteralessZalgoDisplayText("\(lastName) \(firstName)")
                    }
                } else {
                    return exteralessZalgoDisplayText(firstName)
                }
            } else if let lastName = user.lastName, !lastName.isEmpty {
                return exteralessZalgoDisplayText(lastName)
            } else if let _ = user.phone {
                return "" //formatPhoneNumber("+\(phone)")
            } else {
                return strings.User_DeletedAccount
            }
        case let .legacyGroup(group):
            return exteralessZalgoDisplayText(group.title)
        case let .channel(channel):
            return exteralessZalgoDisplayText(channel.title)
        case let .community(community):
            return exteralessZalgoDisplayText(community.title)
        case .secretChat:
            return ""
        }
    }
}

public extension EnginePeer.IndexName {
    func isLessThan(other: EnginePeer.IndexName, ordering: PresentationPersonNameOrder) -> ComparisonResult {
        switch self {
        case let .title(lhsTitle, _):
            let rhsString: String
            switch other {
            case let .title(title, _):
                rhsString = title
            case let .personName(first, last, _, _):
                switch ordering {
                case .firstLast:
                    if first.isEmpty {
                        rhsString = last
                    } else {
                        rhsString = first + last
                    }
                case .lastFirst:
                    if last.isEmpty {
                        rhsString = first
                    } else {
                        rhsString = last + first
                    }
                }
            }
            return lhsTitle.caseInsensitiveCompare(rhsString)
        case let .personName(lhsFirst, lhsLast, _, _):
            let lhsString: String
            switch ordering {
            case .firstLast:
                if lhsFirst.isEmpty {
                    lhsString = lhsLast
                } else {
                    lhsString = lhsFirst + lhsLast
                }
            case .lastFirst:
                if lhsLast.isEmpty {
                    lhsString = lhsFirst
                } else {
                    lhsString = lhsLast + lhsFirst
                }
            }
            let rhsString: String
            switch other {
            case let .title(title, _):
                rhsString = title
            case let .personName(first, last, _, _):
                switch ordering {
                case .firstLast:
                    if first.isEmpty {
                        rhsString = last
                    } else {
                        rhsString = first + last
                    }
                case .lastFirst:
                    if last.isEmpty {
                        rhsString = first
                    } else {
                        rhsString = last + first
                    }
                }
            }
            return lhsString.caseInsensitiveCompare(rhsString)
        }
    }
}
