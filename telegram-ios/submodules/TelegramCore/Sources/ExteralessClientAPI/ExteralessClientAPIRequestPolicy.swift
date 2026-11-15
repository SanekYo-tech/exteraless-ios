import Foundation
internal import TelegramApi

/// Native auth methods carrying an App hash. Coordinator calls these helpers in
/// both Network.request builders: the opaque hash must not enter either verbose
/// request metadata or generic plugin pre/post-request snapshots.
func exteralessClientAPIRequestContainsIdentity(_ description: FunctionDescription) -> Bool {
    switch description.name {
    case "auth.sendCode", "auth.exportLoginToken", "auth.importBotAuthorization",
         "auth.importWebTokenAuthorization", "auth.initPasskeyLogin", "auth.initFirebasePnvLogin":
        return true
    default:
        return false
    }
}

func exteralessClientAPIRequestLogMetadata(_ description: FunctionDescription) -> any CustomStringConvertible {
    if exteralessClientAPIRequestContainsIdentity(description) { return description.name + "(appHash: set)" }
    return WrappedFunctionDescription(description)
}
