import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

final class ExteralessPrivacyExtrasScreenLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if !valid { throw ExteralessHiddenAccountError.staleAccount } }
}

@MainActor
class ExteralessPrivacyExtrasListController: ExteralessSettingsListController {
    let identity: PrivacyExtrasAccountIdentity
    let lease = ExteralessPrivacyExtrasScreenLease()
    let operation = MetaDisposable()
    private let environment = MetaDisposable()
    private let changes = MetaDisposable()
    private(set) var valid = true

    override init(context: AccountContext) {
        identity = exteralessPrivacyExtrasIdentity(context.account)
        super.init(context: context)
        environment.set((combineLatest(context.sharedContext.activeAccountContexts, context.sharedContext.applicationBindings.applicationInForeground, context.sharedContext.appLockContext.isPasscodeLocked)
        |> deliverOnMainQueue).start(next: { [weak self] accounts, foreground, locked in
            guard let self else { return }
            if !foreground || locked || accounts.primary?.account !== context.account { self.invalidate() }
        }))
        changes.set((ExteralessFilteringRuntime.shared.changes |> deliverOnMainQueue).start(next: { [weak self] _ in if self?.valid == true { self?.render() } }))
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { lease.invalidate(); operation.dispose(); environment.dispose(); changes.dispose() }
    func invalidate() {
        valid = false; lease.invalidate(); operation.set(nil)
        if isNodeLoaded { view.endEditing(true); view.isHidden = true }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !valid { setSections([ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "expired", title: "Reopen from the current unlocked account.")])]); view.isHidden = false }
    }
    func errorMessage(_ error: Error) {
        switch error {
        case let error as FilteringRegexError: errorText = "Rule rejected: \(error.rawValue). Use literals, classes, groups, alternatives, anchors and bounded repetition; backreferences and lookarounds are not supported."
        case is FilteringConfigurationError: errorText = "Invalid filter collection or limit reached (64 rules, 4,096 peers per account)."
        default: errorText = "Unable to update local privacy settings. Reopen this screen and try again."
        }
        render()
    }
}

@MainActor
final class ExteralessLocalFiltersController: ExteralessPrivacyExtrasListController {
    private var shown = 50
    override func render() {
        guard valid else { return }
        title = "Local filters"
        let policy = ExteralessFilteringRuntime.shared.policy(identity)
        var shared = ExteralessSettingsRow(id: "shared", title: "Shared text rules", detail: "\(policy.configuration.sharedRules.count) rules")
        shared.accessory = .disclosure
        shared.action = { [weak self] in guard let self, self.valid else { return }; self.push(ExteralessFilterRulesController(context: self.context, peerId: nil)) }
        var chat = ExteralessSettingsRow(id: "chat", title: "Filters for a chat", detail: "Per-chat rules, exceptions, preview and unread count")
        chat.action = { [weak self] in self?.selectPeer(sender: false) }
        var sender = ExteralessSettingsRow(id: "sender", title: "Filter a sender locally", detail: "Does not change Telegram's server block list")
        sender.action = { [weak self] in self?.selectPeer(sender: true) }
        var sections = [ExteralessSettingsSection(footer: "Shared rules skip private chats unless enabled. Chat-specific rules run first. Excluded chats skip all text rules. Outgoing messages never match text rules.", rows: [shared, chat, sender])]
        let peers = policy.configuration.customFilteredUsers.union(policy.configuration.blockedChannels).sorted()
        var rows = peers.prefix(shown).map { packed -> ExteralessSettingsRow in
            var row = ExteralessSettingsRow(id: "sender.\(packed)", title: "Native peer \(packed)", detail: "Tap to remove this local sender filter")
            row.style = .destructive
            row.action = { [weak self] in
                guard let self, self.valid else { return }
                let identity = self.identity; let lease = self.lease
                self.perform({ try lease.check(); try ExteralessFilteringRuntime.shared.setPeer(EnginePeer.Id(packed), account: identity, filtered: false) }, completion: { _ in })
            }
            return row
        }
        if shown < peers.count {
            var more = ExteralessSettingsRow(id: "more", title: "Show more filtered senders")
            more.action = { [weak self] in self?.shown += 50; self?.render() }; rows.append(more)
        }
        if !rows.isEmpty { sections.append(ExteralessSettingsSection(title: "Filtered senders", rows: rows)) }
        if ExteralessFilteringRuntime.shared.configurationHasError(identity) || !policy.invalidRuleIds.isEmpty {
            sections.append(ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "invalid", title: "Some stored filters are invalid", detail: "Repair the rule in the editor. An invalid or incomplete regex evaluation never becomes a reversed match.")]))
        }
        setSections(sections + operationSections())
    }
    private func selectPeer(sender: Bool) {
        guard valid else { return }
        let selector = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.excludeRecent, .doNotSearchMessages], hasContactSelector: false, title: sender ? "Filter sender" : "Chat filters"))
        selector.peerSelected = { [weak self, weak selector] peer, _ in
            selector?.dismiss()
            guard let self, self.valid else { return }
            if sender {
                let identity = self.identity; let lease = self.lease; let id = peer.id
                self.perform({ try lease.check(); try ExteralessFilteringRuntime.shared.setPeer(id, account: identity, filtered: true) }, completion: { _ in })
            } else { self.push(ExteralessChatFiltersController(context: self.context, peer: peer)) }
        }
        push(selector)
    }
}

@MainActor
final class ExteralessChatFiltersController: ExteralessPrivacyExtrasListController {
    let peer: EnginePeer
    private var summary: ExteralessFilteredChatSummary?
    init(context: AccountContext, peer: EnginePeer) { self.peer = peer; super.init(context: context) }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func refresh() {
        guard valid else { return }
        operation.set((exteralessFilteredChatSummary(account: context.account, peerId: peer.id) |> deliverOnMainQueue).start(next: { [weak self] summary in
            guard let self, self.valid else { return }; self.summary = summary; self.tableView.refreshControl?.endRefreshing(); self.render()
        }))
    }
    override func render() {
        guard valid else { return }
        title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        let policy = ExteralessFilteringRuntime.shared.policy(identity)
        var excluded = ExteralessSettingsRow(id: "excluded", title: "Exclude this chat from text filters")
        excluded.toggle = (policy.configuration.excludedDialogs.contains(peer.id.toInt64()), { [weak self] value in
            guard let self, self.valid else { return }
            let identity = self.identity; let lease = self.lease; let id = self.peer.id.toInt64()
            self.perform({
                try lease.check()
                var ids = ExteralessFilteringRuntime.shared.policy(identity).configuration.excludedDialogs
                if value { ids.insert(id) } else { ids.remove(id) }
                try ExteralessFilteringRuntime.shared.setCollection("regexFiltersExcludedDialogs", account: identity, value: FilteringConfiguration.value(for: ids))
            }, completion: { [weak self] _ in self?.refresh() })
        })
        var rules = ExteralessSettingsRow(id: "rules", title: "Text rules for this chat", detail: "\(policy.configuration.chatRules[peer.id.toInt64()]?.count ?? 0) rules")
        rules.action = { [weak self] in guard let self, self.valid else { return }; self.push(ExteralessFilterRulesController(context: self.context, peerId: self.peer.id)) }
        var rows = [excluded, rules]
        if let summary {
            rows.append(ExteralessSettingsRow(id: "unread", title: "Visible unread messages", detail: summary.unreadCount.map(String.init) ?? "Local history is incomplete; an unread dot is used."))
            rows.append(ExteralessSettingsRow(id: "preview", title: "Visible preview", detail: summary.filteringActive ? (summary.preview?.text ?? "No confirmed visible preview within the local scan limit.") : "Local message filtering is off for this chat."))
        }
        setSections([ExteralessSettingsSection(footer: "Sender filtering in group history is independent of regex exceptions. Counts are a local projection; Telegram read state is preserved.", rows: rows)] + operationSections())
    }
}

@MainActor
final class ExteralessFilterRulesController: ExteralessPrivacyExtrasListController {
    let peerId: EnginePeer.Id?
    init(context: AccountContext, peerId: EnginePeer.Id?) { self.peerId = peerId; super.init(context: context) }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func render() {
        guard valid else { return }
        title = peerId == nil ? "Shared text rules" : "Chat text rules"
        let policy = ExteralessFilteringRuntime.shared.policy(identity)
        let rules = peerId.map { policy.configuration.chatRules[$0.toInt64()] ?? [] } ?? policy.configuration.sharedRules
        var add = ExteralessSettingsRow(id: "add", title: "Add rule")
        add.style = .accent; add.enabled = rules.count < FilteringConfiguration.maximumRules
        add.action = { [weak self] in guard let self, self.valid else { return }; self.push(ExteralessFilterRuleEditor(context: self.context, peerId: self.peerId, rule: FilteringRule(regex: ""), isNew: true)) }
        let rows = rules.map { rule -> ExteralessSettingsRow in
            var row = ExteralessSettingsRow(id: rule.id, title: rule.regex.isEmpty ? "Empty expression" : rule.regex, detail: "\(rule.enabled ? "Enabled" : "Disabled") · \(rule.caseInsensitive ? "Ignore case" : "Case sensitive") · \(rule.reversed ? "Hide non-matches" : "Hide matches")")
            row.action = { [weak self] in guard let self, self.valid else { return }; self.push(ExteralessFilterRuleEditor(context: self.context, peerId: self.peerId, rule: rule, isNew: false)) }
            return row
        }
        setSections([ExteralessSettingsSection(footer: "Find mode with multiline anchors. Maximum 256 pattern scalars, 8,192 input scalars and a fixed work budget. Unsupported regex syntax is rejected on save.", rows: [add] + rows)] + operationSections())
    }
}

@MainActor
final class ExteralessFilterRuleEditor: ExteralessPrivacyExtrasListController {
    private let peerId: EnginePeer.Id?
    private var rule: FilteringRule
    private let isNew: Bool
    init(context: AccountContext, peerId: EnginePeer.Id?, rule: FilteringRule, isNew: Bool) {
        self.peerId = peerId; self.rule = rule; self.isNew = isNew; super.init(context: context)
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func render() {
        guard valid else { return }
        title = isNew ? "New text rule" : "Edit text rule"
        var text = ExteralessSettingsRow(id: "text", title: "Expression")
        text.input = ExteralessSettingsInput(text: rule.regex, placeholder: "(?:(spam|promo))", kind: .text, updated: { [weak self] in self?.rule.regex = $0 }, submitted: { [weak self] in self?.save(remove: false) })
        var enabled = ExteralessSettingsRow(id: "enabled", title: "Enabled")
        enabled.toggle = (rule.enabled, { [weak self] in self?.rule.enabled = $0; self?.render() })
        var insensitive = ExteralessSettingsRow(id: "case", title: "Ignore ASCII case")
        insensitive.toggle = (rule.caseInsensitive, { [weak self] in self?.rule.caseInsensitive = $0; self?.render() })
        var reversed = ExteralessSettingsRow(id: "reverse", title: "Hide messages that do not match")
        reversed.toggle = (rule.reversed, { [weak self] in self?.rule.reversed = $0; self?.render() })
        var save = ExteralessSettingsRow(id: "save", title: "Save rule"); save.style = .accent
        save.action = { [weak self] in self?.save(remove: false) }
        var rows = [text, enabled, insensitive, reversed, save]
        if !isNew {
            var remove = ExteralessSettingsRow(id: "remove", title: "Remove rule"); remove.style = .destructive
            remove.action = { [weak self] in self?.save(remove: true) }; rows.append(remove)
        }
        setSections([ExteralessSettingsSection(rows: rows)] + operationSections())
    }
    private func save(remove: Bool) {
        guard valid else { return }
        if !remove { do { _ = try FilteringRegex(rule.regex, caseInsensitive: rule.caseInsensitive) } catch { errorMessage(error); return } }
        let identity = self.identity; let lease = self.lease; let rule = self.rule; let peer = peerId?.toInt64()
        perform({
            try lease.check()
            let policy = ExteralessFilteringRuntime.shared.policy(identity)
            var rules = peer.map { policy.configuration.chatRules[$0] ?? [] } ?? policy.configuration.sharedRules
            let index = rules.firstIndex(where: { $0.id == rule.id })
            if let index { if remove { rules.remove(at: index) } else { rules[index] = rule } }
            else if !remove { rules.insert(rule, at: 0) }
            let value = try FilteringConfiguration.value(for: rules)
            if let peer {
                var chats = policy.configuration.chatRules
                chats[peer] = rules.isEmpty ? nil : rules
                let object = try chats.reduce(into: [String: ClientSettingValue]()) { $0[String($1.key)] = try FilteringConfiguration.value(for: $1.value) }
                try ExteralessFilteringRuntime.shared.setCollection("regexChatFiltersData", account: identity, value: .object(object))
            } else { try ExteralessFilteringRuntime.shared.setCollection("regexFiltersData", account: identity, value: value) }
        }, completion: { [weak self] _ in
            guard let self, self.valid else { return }; _ = (self.navigationController as? NavigationController)?.popViewController(animated: true)
        })
    }
}
