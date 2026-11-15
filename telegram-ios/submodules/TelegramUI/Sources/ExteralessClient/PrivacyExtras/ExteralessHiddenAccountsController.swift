import AccountContext
import Display
import ExteralessCore
import Foundation
import PasscodeCore
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
final class ExteralessHiddenAccountsController: ExteralessPrivacyExtrasListController {
    private let session: PasscodeSession
    private var accounts: [(PrivacyExtrasAccountIdentity, EnginePeer)] = []
    private var recoveryURL: URL?
    private let privateChanges = MetaDisposable()

    init(context: AccountContext, session: PasscodeSession) {
        self.session = session
        super.init(context: context)
        privateChanges.set((ExteralessHiddenAccounts.shared.changes |> deliverOnMainQueue).start(next: { [weak self] _ in if self?.valid == true { self?.render() } }))
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { session.invalidate(); privateChanges.dispose() }
    override func invalidate() { session.invalidate(); recoveryURL = nil; super.invalidate() }

    override func refresh() {
        guard valid, session.isValid else { return }
        // Read unfiltered account contexts. A filtered picker signal would make a
        // hidden account impossible to manage or recover from this authorized UI.
        operation.set((context.sharedContext.activeAccountContexts
        |> mapToSignal { value -> Signal<[(PrivacyExtrasAccountIdentity, EnginePeer)], NoError> in
            combineLatest(value.accounts.prefix(HiddenAccountPolicy.maximumAccounts).map { _, context, _ in
                context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                |> map { peer -> (PrivacyExtrasAccountIdentity, EnginePeer)? in
                    peer.map { (exteralessPrivacyExtrasIdentity(context.account), $0) }
                }
            }) |> map { $0.compactMap { $0 } }
        }
        |> deliverOnMainQueue).start(next: { [weak self] accounts in
            guard let self, self.valid else { return }; self.accounts = accounts; self.tableView.refreshControl?.endRefreshing(); self.render()
        }))
        let identity = identity; let session = session; let lease = lease
        perform({ try lease.check(); return try ExteralessHiddenAccounts.shared.recoveryURL(owner: identity, session: ExteralessNativeHiddenSettingsAuthorization(session: session)) }, completion: { [weak self] url in
            if self?.valid == true { self?.recoveryURL = url }
        })
    }

    override func render() {
        guard valid, session.isValid else { return }
        title = "Hidden accounts"
        let store = ExteralessHiddenAccounts.shared
        var hidden = ExteralessSettingsRow(id: "settings", title: "Hide this entry from Settings")
        hidden.enabled = recoveryURL != nil
        hidden.toggle = (store.settingsHidden, { [weak self] value in
            guard let self, self.valid else { return }
            let owner = self.identity; let session = self.session; let lease = self.lease
            self.perform({ try lease.check(); try ExteralessHiddenAccounts.shared.setSettingsHidden(value, owner: owner, session: ExteralessNativeHiddenSettingsAuthorization(session: session)) }, completion: { _ in })
        })
        var copy = ExteralessSettingsRow(id: "recovery", title: "Copy recovery link", detail: recoveryURL?.absoluteString ?? "Preparing the private recovery route…")
        copy.enabled = recoveryURL != nil
        copy.action = { [weak self] in
            guard let self, self.valid, self.session.isValid, let url = self.recoveryURL else { return }
            UIPasteboard.general.setItems([["public.url": url]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        }
        var sections = [ExteralessSettingsSection(footer: "The link reopens this page locally and still requires your ordinary app passcode. Keep it before hiding the entry.", rows: [hidden, copy])]
        sections.append(ExteralessSettingsSection(title: "Accounts", footer: "A hidden account needs its own code. Its account-menu rows and notifications are hidden; its code opens that exact identity from the app lock screen.", rows: accounts.map { identity, peer in
            let state = store.state(identity)
            var row = ExteralessSettingsRow(id: identity.storageKey, title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder), detail: "\(state.isHidden ? "Hidden" : "Visible") · \(state.allowPanic ? "Included in panic" : "Excluded from panic")")
            row.accessory = .disclosure
            row.action = { [weak self] in guard let self, self.valid else { return }; self.push(ExteralessHiddenAccountController(context: self.context, target: identity, session: self.session)) }
            return row
        }))
        var panic = ExteralessSettingsRow(id: "panic", title: store.hasPanicCode ? "Change panic code" : "Set panic code")
        panic.action = { [weak self] in guard let self, self.valid else { return }; self.push(ExteralessPrivateCodeEditor(context: self.context, target: nil, session: self.session)) }
        var panicRows = [panic]
        if store.hasPanicCode {
            var remove = ExteralessSettingsRow(id: "removePanic", title: "Remove panic code"); remove.style = .destructive
            remove.action = { [weak self] in
                guard let self, self.valid else { return }
                self.confirmRemoval(title: "Remove panic code?", text: "The configured panic code will stop working.") {
                    let owner = self.identity; let session = self.session; let lease = self.lease
                    self.perform({ try lease.check(); try ExteralessHiddenAccounts.shared.setPanicCode(nil, kind: .alphanumeric, owner: owner, session: ExteralessNativeHiddenSettingsAuthorization(session: session)) }, completion: { _ in })
                }
            }
            panicRows.append(remove)
        }
        sections.append(ExteralessSettingsSection(title: "Panic code", footer: "Entering the configured panic code on the app lock screen logs out activated accounts marked Included in panic. It does not delete the Telegram accounts on the server. Ordinary PIN, Face ID, Cancel and backgrounding never trigger panic.", rows: panicRows))
        setSections(sections + operationSections())
    }

    private func confirmRemoval(title: String, text: String, action: @escaping () -> Void) {
        present(textAlertController(context: context, title: title, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: action)
        ]), in: .window(.root))
    }
}

@MainActor
final class ExteralessHiddenAccountController: ExteralessPrivacyExtrasListController {
    private let target: PrivacyExtrasAccountIdentity
    private let session: PasscodeSession
    private let privateChanges = MetaDisposable()
    init(context: AccountContext, target: PrivacyExtrasAccountIdentity, session: PasscodeSession) {
        self.target = target; self.session = session; super.init(context: context)
        privateChanges.set((ExteralessHiddenAccounts.shared.changes |> deliverOnMainQueue).start(next: { [weak self] _ in if self?.valid == true { self?.render() } }))
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { privateChanges.dispose() }
    override func render() {
        guard valid, session.isValid else { return }
        title = "Account visibility"
        let state = ExteralessHiddenAccounts.shared.state(target)
        let owner = identity; let target = target; let session = session; let lease = lease
        var hide = ExteralessSettingsRow(id: "hidden", title: "Hide account")
        hide.enabled = state.hasPasscode
        hide.toggle = (state.isHidden, { [weak self] value in
            self?.perform({ try lease.check(); try ExteralessHiddenAccounts.shared.setHidden(value, target: target, owner: owner, session: ExteralessNativeHiddenSettingsAuthorization(session: session)) }, completion: { _ in })
        })
        var allow = ExteralessSettingsRow(id: "allow", title: "Include in panic logout")
        allow.toggle = (state.allowPanic, { [weak self] value in
            self?.perform({ try lease.check(); try ExteralessHiddenAccounts.shared.setAllowPanic(value, target: target, owner: owner, session: ExteralessNativeHiddenSettingsAuthorization(session: session)) }, completion: { _ in })
        })
        var code = ExteralessSettingsRow(id: "code", title: state.hasPasscode ? "Change account code" : "Set account code")
        code.action = { [weak self] in guard let self, self.valid else { return }; self.push(ExteralessPrivateCodeEditor(context: self.context, target: target, session: session)) }
        var rows = [hide, allow, code]
        if state.hasPasscode {
            var remove = ExteralessSettingsRow(id: "remove", title: "Remove account code"); remove.style = .destructive
            remove.action = { [weak self] in
                guard let self, self.valid else { return }
                self.present(textAlertController(context: self.context, title: "Remove account code?", text: "This also makes the account visible again.", actions: [
                    TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: self.presentationData.strings.Common_Delete, action: { [weak self] in
                        self?.perform({ try lease.check(); try ExteralessHiddenAccounts.shared.removeAccountCode(target: target, owner: owner, session: ExteralessNativeHiddenSettingsAuthorization(session: session)) }, completion: { _ in })
                    })
                ]), in: .window(.root))
            }
            rows.append(remove)
        }
        setSections([ExteralessSettingsSection(footer: "The code uses the same keypad type as the ordinary app code. Keep at least one visible account for ordinary PIN/biometric unlock. If every account is hidden, use an account code.", rows: rows)] + operationSections())
    }
}

@MainActor
final class ExteralessPrivateCodeEditor: ExteralessPrivacyExtrasListController {
    private let target: PrivacyExtrasAccountIdentity?
    private let session: PasscodeSession
    private var code = ""
    private var repeated = ""
    init(context: AccountContext, target: PrivacyExtrasAccountIdentity?, session: PasscodeSession) {
        self.target = target; self.session = session; super.init(context: context)
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func invalidate() { code = ""; repeated = ""; super.invalidate() }
    override func render() {
        guard valid, session.isValid else { return }
        title = target == nil ? "Panic code" : "Account code"
        var first = ExteralessSettingsRow(id: "first", title: "New code")
        first.input = ExteralessSettingsInput(text: code, placeholder: "", kind: .secret, updated: { [weak self] in self?.code = $0 }, submitted: {})
        var second = ExteralessSettingsRow(id: "second", title: "Repeat code")
        second.input = ExteralessSettingsInput(text: repeated, placeholder: "", kind: .secret, updated: { [weak self] in self?.repeated = $0 }, submitted: { [weak self] in self?.save() })
        var save = ExteralessSettingsRow(id: "save", title: "Save code"); save.style = .accent
        save.action = { [weak self] in self?.save() }
        setSections([ExteralessSettingsSection(footer: "Choose a code different from the ordinary app PIN and all other account codes. A valid ordinary PIN always takes precedence. Saving here does not execute the code.", rows: [first, second, save])] + operationSections())
    }
    private func save() {
        guard valid, session.isValid else { return }
        guard !code.isEmpty, code == repeated, code.utf8.count <= 256 else { errorText = "Codes must match and use the current app keypad format."; render(); return }
        let code = code; let owner = identity; let target = target; let session = session; let lease = lease
        perform({
            try lease.check()
            let authorization = ExteralessNativeHiddenSettingsAuthorization(session: session)
            let kind = try authorization.validateHiddenSettings()
            if let target { try ExteralessHiddenAccounts.shared.setAccountCode(code, kind: kind, target: target, owner: owner, session: authorization) }
            else { try ExteralessHiddenAccounts.shared.setPanicCode(code, kind: kind, owner: owner, session: authorization) }
        }, completion: { [weak self] _ in
            guard let self else { return }; self.code = ""; self.repeated = ""
            if self.valid { _ = (self.navigationController as? NavigationController)?.popViewController(animated: true) }
        })
    }
}
