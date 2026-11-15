import Foundation
import PasscodeCore
import TelegramCore

/// The authority is an actual PasscodeCore session, not a Bool from a settings
/// screen. All validation may run on the settings worker; no UIKit enters Core.
struct ExteralessNativeHiddenSettingsAuthorization: ExteralessHiddenSettingsAuthorization {
    let session: PasscodeSession

    var isValidForHiddenSettings: Bool { session.scope == .settings && session.isValid }

    func validateHiddenSettings() throws -> ExteralessPrivateCodeKind {
        guard session.scope == .settings, session.isValid else { throw ExteralessHiddenAccountError.authenticationRequired }
        try PasscodeCredentialStore.shared.validate(session, scope: .settings)
        guard let nativeKind = try PasscodeCredentialStore.shared.protectionSettings().passcode?.kind,
              let kind = ExteralessPrivateCodeKind(rawValue: nativeKind.rawValue) else { throw ExteralessHiddenAccountError.authenticationRequired }
        return kind
    }
}

/// Call after the real PasscodeEnvironment is configured and before account UI.
/// Resolves the existing entitled app group; no entitlement is invented here.
/// durabilityRootURL is the caller's actual OS container URL, not rootPath.
func exteralessPrivacyExtrasConfigure(rootPath: String, durabilityRootURL: URL) throws {
    try ExteralessHiddenAccounts.shared.configure(basePath: rootPath, accessGroup: PasscodeEnvironment.shared.sharedAccessGroup(), isMainApp: PasscodeEnvironment.shared.isMainApp, keychainScope: PasscodeEnvironment.shared.keychainScope, durabilityRootURL: durabilityRootURL)
}
