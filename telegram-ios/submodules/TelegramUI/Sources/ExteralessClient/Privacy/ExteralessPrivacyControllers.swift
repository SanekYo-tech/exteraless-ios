import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit
import UserNotifications

@MainActor
class ExteralessPrivacyListController: ExteralessSettingsListController {
    let operation = MetaDisposable()
    var accountIsValid = true
    private var observation: ClientSettingsObservation?

    override init(context: AccountContext) {
        super.init(context: context)
        observation = ClientSettings.shared.observe { [weak self] _ in
            Task { @MainActor [weak self] in if self?.accountIsValid == true { self?.render() } }
        }
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { operation.dispose(); observation?.cancel() }
    func invalidateAccount() {
        accountIsValid = false
        operation.set(nil)
        setSections([ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "account", title: "Account changed. Reopen this screen from the current account.")])])
    }
    func dateText(_ timestamp: Int32) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: presentationData.strings.baseLanguageCode)
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

@MainActor
final class ExteralessPrivacyOverviewController: ExteralessPrivacyListController {
    private var ownLastSeen: Int32?
    override func refresh() {
        guard accountIsValid else { return }
        operation.set((exteralessPrivacyOwnLastSeen(engine: context.engine) |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.accountIsValid else { return }
            self.ownLastSeen = value
            self.tableView.refreshControl?.endRefreshing()
            self.render()
        }))
    }
    override func render() {
        guard accountIsValid else { return }
        title = "Ghost mode"
        let policy = PrivacyPolicy.current
        var toggle = ExteralessSettingsRow(id: "toggle", title: policy.ghostModeActive ? "Turn ghost mode off" : "Turn ghost mode on", detail: "Locked fields keep their individual values.")
        toggle.style = .accent
        toggle.action = { [weak self] in
            guard let self, self.accountIsValid else { return }
            self.operation.set((exteralessToggleGhostMode(account: self.context.account) |> deliverOnMainQueue).start(next: { [weak self] _ in self?.render() }, error: { [weak self] error in self?.showError(error) }))
        }
        var rows = [toggle]
        if (!policy.sendOnlinePackets || policy.sendOfflinePacketAfterOnline), let ownLastSeen {
            rows.append(ExteralessSettingsRow(id: "lastSeen", title: "My last observed server status", detail: dateText(ownLastSeen)))
        }
        var clear = ExteralessSettingsRow(id: "clear", title: "Clear remembered activity for this account", detail: "Clears local last-seen and read/played dates.")
        clear.style = .destructive
        clear.action = { [weak self] in
            guard let self, self.accountIsValid else { return }
            self.operation.set((exteralessClearPrivacyObservations(account: self.context.account) |> deliverOnMainQueue).start(completed: { [weak self] in self?.ownLastSeen = nil; self?.render() }))
        }
        rows.append(clear)
        setSections([ExteralessSettingsSection(footer: "Read receipts, story views, online status and typing remain independently configurable. Explicitly marking a chat read is a server action.", rows: rows)] + operationSections())
    }
}

@MainActor
final class ExteralessPrivacyPeerController: ExteralessPrivacyListController {
    let peerId: EnginePeer.Id
    private var peer: EnginePeer?
    private var lastSeen: Int32?
    private var readDates: [(id: EngineMessage.Id, dates: PrivacyObservations.Read)] = []

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.peerId = peerId
        super.init(context: context)
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func refresh() {
        guard accountIsValid else { return }
        operation.set((exteralessPrivacyPeerObservationData(engine: context.engine, peerId: peerId) |> deliverOnMainQueue).start(next: { [weak self] peer, lastSeen, dates in
            guard let self, self.accountIsValid else { return }
            self.peer = peer; self.lastSeen = lastSeen; self.readDates = dates
            self.tableView.refreshControl?.endRefreshing()
            self.render()
        }))
    }

    private func setException(_ field: String, value: Bool) {
        guard accountIsValid else { return }
        let peerKey = PrivacyPeerKey(accountId: context.account.id.int64, peerId: peerId.toInt64()).settingKey
        perform({
            var values: [String: ClientSettingValue] = [:]
            if case let .object(stored)? = ClientSettings.shared.value(field) { values = stored }
            if value { values[peerKey] = .bool(true) } else { values.removeValue(forKey: peerKey) }
            try ClientSettings.shared.set(.object(values), for: field)
        }, completion: { _ in })
    }

    override func render() {
        guard accountIsValid else { return }
        title = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? "Chat privacy"
        let policy = PrivacyPolicy.current
        let key = PrivacyPeerKey(accountId: context.account.id.int64, peerId: peerId.toInt64())
        var read = ExteralessSettingsRow(id: "read", title: "Always allow reads for this chat")
        read.toggle = (policy.readExcluded(key), { [weak self] in self?.setException("privacy.ghostModeReadExclusions", value: $0) })
        var typing = ExteralessSettingsRow(id: "typing", title: "Always allow typing for this chat")
        typing.toggle = (policy.typingExcluded(key), { [weak self] in self?.setException("privacy.ghostModeTypingExclusions", value: $0) })
        var mark = ExteralessSettingsRow(id: "mark", title: "Mark read on Telegram now", detail: "Sends a read receipt even while ghost mode is enabled.")
        mark.style = .accent
        mark.action = { [weak self] in
            guard let self, self.accountIsValid else { return }
            self.operation.set((exteralessMarkReadOnServer(account: self.context.account, peerId: self.peerId) |> deliverOnMainQueue).start(next: { [weak self] success in
                self?.errorText = success ? nil : "Could not mark the loaded history read."
                self?.render()
            }))
        }
        var sections = [ExteralessSettingsSection(footer: "Exceptions belong only to this account and peer. A private story-viewing session still suppresses story views.", rows: [read, typing, mark])]
        if policy.saveLocalLastSeen, let lastSeen { sections.append(ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "seen", title: "Locally observed activity", detail: dateText(lastSeen))])) }
        if policy.saveReadDate, !readDates.isEmpty {
            sections.append(ExteralessSettingsSection(title: "Observed read dates", footer: "Dates observed on this device for the most recent 100 loaded messages.", rows: readDates.map { id, dates in
                let parts = [dates.readAt.map { "Read: " + dateText($0) }, dates.playedAt.map { "Played: " + dateText($0) }].compactMap { $0 }
                return ExteralessSettingsRow(id: "date.\(id.namespace).\(id.id)", title: "Message \(id.id)", detail: parts.joined(separator: "\n"))
            }))
        }
        setSections(sections + operationSections())
    }
}

@MainActor
final class ExteralessBotAccountSettingsController: ExteralessPrivacyListController {
    private var accounts: [AccountWithInfo] = []
    override func refresh() {
        guard accountIsValid else { return }
        operation.set((context.sharedContext.activeAccountsWithInfo |> take(1) |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.accountIsValid else { return }
            self.accounts = value.accounts.filter { $0.account.testingEnvironment == self.context.account.testingEnvironment }
            self.tableView.refreshControl?.endRefreshing()
            self.render()
        }))
    }
    override func render() {
        guard accountIsValid else { return }
        title = "Bot account"
        setSections([ExteralessSettingsSection(footer: "New bot conversations use the selected identity. Existing conversations retain their account; unknown evidence cancels the decision.", rows: accounts.map { account in
            var row = ExteralessSettingsRow(id: "account.\(account.account.id.int64)", title: account.peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder))
            let id = account.account.peerId.id._internalGetInt64Value()
            row.accessory = PrivacyPolicy.current.botPrivacyUserId == id ? .checkmark : .none
            row.action = { [weak self] in
                guard let self, self.accountIsValid else { return }
                self.perform({ try ClientSettings.shared.set(.integer(id), for: "privacy.botPrivacyUserId") }, completion: { _ in })
            }
            return row
        })] + operationSections())
    }
}

@MainActor
final class ExteralessNotificationDiagnosticsController: ExteralessPrivacyListController {
    override func refresh() {
        guard accountIsValid else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] value in
            PrivacyNotificationDiagnostics.shared.recordAuthorization(exteralessNotificationAuthorization(value.authorizationStatus))
            Task { @MainActor [weak self] in
                self?.tableView.refreshControl?.endRefreshing()
                self?.render()
            }
        }
    }
    private func registrationText(_ state: PrivacyNotificationRegistrationState) -> String {
        switch state {
        case .notAttempted: return "Not attempted in this process"
        case .registering: return "Registering"
        case .registered: return "Telegram accepted registration"
        case .unregistered: return "Unregistered"
        case .invalidated: return "Token invalidated by Telegram"
        case let .failed(code): return "Registration failed (code \(code))"
        }
    }
    override func render() {
        guard accountIsValid else { return }
        title = "Notification diagnostics"
        let state = PrivacyNotificationDiagnostics.shared.snapshot(accountId: context.account.id.int64)
        var rows = [
            ExteralessSettingsRow(id: "permission", title: "System authorization", detail: state.authorization.rawValue),
            ExteralessSettingsRow(id: "token", title: "APNs callback", detail: state.tokenReceived ? "Device token received in this process" : state.tokenErrorCode.map { "Registration error (code \($0))" } ?? "No device token received in this process"),
            ExteralessSettingsRow(id: "telegram", title: "This account", detail: registrationText(state.apnsRegistration)),
            ExteralessSettingsRow(id: "environment", title: "APNs environment", detail: state.sandbox.map { $0 ? "Sandbox" : "Production" } ?? "Not registered yet")
        ]
        if let report = PrivacyNotificationDiagnostics.extensionReport(root: URL(fileURLWithPath: context.sharedContext.basePath), accountId: context.account.id.int64) {
            rows.append(ExteralessSettingsRow(id: "extension", title: "Last notification extension result", detail: report.stage.rawValue + " · " + dateText(Int32(clamping: Int64(report.timestamp)))))
        }
        var authorize = ExteralessSettingsRow(id: "authorize", title: "Request notification permission", detail: "Uses Telegram's native registration and notification categories.")
        authorize.action = { [weak self] in
            guard let self, self.accountIsValid else { return }
            self.context.sharedContext.applicationBindings.registerForNotifications { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        var retry = ExteralessSettingsRow(id: "retry", title: "Retry this device's Telegram registration")
        retry.action = { [weak self] in
            guard let self, self.accountIsValid else { return }
            self.context.sharedContext.updateNotificationTokensRegistration()
            self.render()
        }
        var settings = ExteralessSettingsRow(id: "settings", title: "Open iOS notification settings")
        settings.action = { [weak self] in self?.context.sharedContext.applicationBindings.openSettings() }
        setSections([ExteralessSettingsSection(footer: "An accepted device token does not prove end-to-end push delivery. Signing/profile, APNs environment and topic, and Telegram's provider-side configuration must match. No APNs provider credentials belong in the app. Delivery must be verified on a physical device.", rows: rows), ExteralessSettingsSection(rows: [authorize, retry, settings])])
    }
}
