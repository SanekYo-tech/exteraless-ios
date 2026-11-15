import AccountContext
import Display
import ExteralessCore
import Foundation
import LocalizedPeerData
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
class ExteralessIdentityController: ExteralessSettingsListController {
    let permit: IdentityEditPermit
    private let stateDisposable = MetaDisposable()
    private let operation = MetaDisposable()
    private(set) var identityState: IdentityAccountState?
    private(set) var saving = false

    var valid: Bool { (try? permit.check(owner: exteralessIdentityAccountId(context.account))) != nil }
    var canEdit: Bool { valid && identityState != nil && !saving }

    init(context: AccountContext, permit: IdentityEditPermit) {
        self.permit = permit
        super.init(context: context)
        stateDisposable.set((exteralessIdentityState(engine: context.engine) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self, self.valid else { return }
            switch result {
            case let .success(state):
                self.identityState = state
                self.didLoadIdentity(state)
            case let .failure(error): self.identityState = nil; self.errorText = error.errorDescription
            }
            self.render()
        }))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { stateDisposable.dispose(); operation.dispose() }

    func didLoadIdentity(_ state: IdentityAccountState) {}

    func apply(_ mutation: IdentityMutation, emojiFiles: [TelegramMediaFile] = [], completion: (() -> Void)? = nil) {
        guard valid, !saving else { return }
        saving = true; errorText = nil; render()
        operation.set((exteralessUpdateIdentity(engine: context.engine, mutation: mutation, permit: permit, emojiFiles: emojiFiles)
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            guard let self, self.valid else { return }
            self.saving = false
            completion?()
            self.render()
        }, error: { [weak self] error in
            guard let self, self.valid else { return }
            self.saving = false
            self.errorText = error.errorDescription
            self.render()
        }))
    }

    func identityOperationSections() -> [ExteralessSettingsSection] {
        if !valid { return [.init(rows: [.init(id: "inactive", title: "This account is no longer active")])] }
        if saving { return [.init(rows: [.init(id: "saving", title: "Updating local identity…")])] }
        return operationSections()
    }
}

@MainActor
final class ExteralessIdentityAccountController: ExteralessIdentityController {
    private var peer: EnginePeer?
    private var aliasPeers: [String: EnginePeer] = [:]
    private let peersDisposable = MetaDisposable()
    private let aliasesDisposable = MetaDisposable()
    private var aliasKeys: Set<String> = []
    private var shownAliases = 50

    override init(context: AccountContext, permit: IdentityEditPermit) {
        super.init(context: context, permit: permit)
        peersDisposable.set((context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)) |> deliverOnMainQueue).start(next: { [weak self] peer in
            self?.peer = peer; self?.render()
        }))
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { peersDisposable.dispose(); aliasesDisposable.dispose() }

    override func didLoadIdentity(_ state: IdentityAccountState) {
        let keys = Set(state.aliases.keys)
        if keys != aliasKeys {
            aliasKeys = keys
            aliasesDisposable.set((exteralessIdentityAliasPeers(engine: context.engine, keys: keys.compactMap(IdentityPeerKey.init(storageKey:))) |> deliverOnMainQueue).start(next: { [weak self] peers in
                self?.aliasPeers = peers; self?.render()
            }))
        }
    }

    override func render() {
        title = "Local identity"
        var sections = identityOperationSections()
        guard valid else { setSections(sections); return }
        guard let state = identityState else {
            var reset = ExteralessSettingsRow(id: "reset", title: "Reset local identity data")
            reset.style = .destructive; reset.enabled = !saving
            reset.action = { [weak self] in self?.apply(.resetAll) }
            setSections(sections + [.init(rows: [reset])]); return
        }
        let accountDefinitions = Dictionary(uniqueKeysWithValues: IdentityFeatures.accountDefinitions.map { ($0.key, $0) })
        var order = ExteralessSettingsRow(id: "nameOrder", title: accountDefinitions["identity.nameOrder"]?.title ?? "Name order", detail: state.nameOrder == .firstLast ? "First name, last name" : "Last name, first name")
        order.accessory = .disclosure; order.enabled = canEdit
        order.action = { [weak self] in guard let self, self.canEdit else { return }; self.push(ExteralessIdentityNameOrderController(context: self.context, permit: self.permit)) }
        order.reset = { [weak self] in self?.apply(.nameOrder(.firstLast, expected: state.nameOrder)) }
        var add = ExteralessSettingsRow(id: "addAlias", title: "Set a local name")
        add.accessory = .disclosure; add.enabled = canEdit
        add.action = { [weak self] in self?.selectPeer() }
        sections.append(.init(title: "This account", rows: [order, add]))

        var aliases: [ExteralessSettingsRow] = []
        for key in state.aliases.keys.sorted().prefix(shownAliases) {
            guard let alias = state.aliases[key], let peerKey = IdentityPeerKey(storageKey: key) else { continue }
            let peer = aliasPeers[key]
            let original = peer.map { self.originalName(for: $0) } ?? key
            var row = ExteralessSettingsRow(id: "alias." + key, title: alias, detail: original)
            row.accessory = .disclosure; row.enabled = canEdit
            row.action = { [weak self] in
                guard let self, self.canEdit else { return }
                self.push(ExteralessIdentityAliasController(context: self.context, permit: self.permit, peer: peer, key: peerKey, originalName: original))
            }
            row.reset = { [weak self] in self?.apply(.alias(peer: peerKey, value: nil, expected: alias)) }
            aliases.append(row)
        }
        if shownAliases < state.aliases.count {
            var more = ExteralessSettingsRow(id: "more", title: "Show more names")
            more.action = { [weak self] in guard let self else { return }; self.shownAliases += 50; self.render() }
            aliases.append(more)
        }
        if !aliases.isEmpty { sections.append(.init(title: "Local names", rows: aliases)) }

        var premium = ExteralessSettingsRow(id: "localPremium", title: accountDefinitions["identity.localPremium"]?.title ?? "Local Premium presentation")
        premium.enabled = canEdit
        premium.toggle = (state.localPremium, { [weak self] value in self?.apply(.localPremium(value, expected: state.localPremium)) })
        var status = ExteralessSettingsRow(id: "emojiStatus", title: "Local emoji status", detail: state.emojiStatus.map { "Document \($0.documentId)" } ?? "Telegram value")
        status.accessory = .disclosure; status.enabled = canEdit && state.localPremium
        status.action = { [weak self] in self?.selectStatus() }
        status.reset = { [weak self] in self?.apply(.emojiStatus(nil, expected: state.emojiStatus)) }
        var colors = ExteralessSettingsRow(id: "colors", title: "Local reply and profile colors")
        colors.accessory = .disclosure; colors.enabled = canEdit && state.localPremium && peer != nil
        colors.action = { [weak self] in
            guard let self, self.canEdit, let peer = self.peer else { return }
            self.push(ExteralessIdentityColorsController(context: self.context, permit: self.permit, peer: peer))
        }
        sections.append(.init(title: "Local Premium", footer: "Local badge and appearance for this account. Telegram status/color values take precedence while present. Subscription, boosts and paid sends use actual Telegram capabilities.", rows: [premium, status, colors]))

        var export = ExteralessSettingsRow(id: "export", title: "Export local identity")
        export.enabled = canEdit
        export.action = { [weak self] in
            guard let self, self.canEdit, let state = self.identityState else { return }
            do {
                let data = try IdentityArchive.encode(state)
                let activity = UIActivityViewController(activityItems: [String(decoding: data, as: UTF8.self)], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = self.view
                activity.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY, width: 1, height: 1)
                self.present(activity, animated: true)
            } catch { self.errorText = (error as? IdentityError)?.errorDescription; self.render() }
        }
        var importRow = ExteralessSettingsRow(id: "import", title: "Import local identity")
        importRow.enabled = canEdit; importRow.accessory = .disclosure
        importRow.action = { [weak self] in guard let self, self.canEdit else { return }; self.push(ExteralessIdentityImportController(context: self.context, permit: self.permit)) }
        var resetNames = ExteralessSettingsRow(id: "clearAliases", title: "Reset all local names")
        resetNames.style = .destructive; resetNames.enabled = canEdit && !state.aliases.isEmpty
        resetNames.action = { [weak self] in self?.apply(.clearAliases) }
        var resetPremium = ExteralessSettingsRow(id: "resetPremium", title: "Reset local Premium")
        resetPremium.style = .destructive; resetPremium.enabled = canEdit
        resetPremium.action = { [weak self] in self?.apply(.resetPremium) }
        var reset = ExteralessSettingsRow(id: "resetAll", title: "Reset local identity")
        reset.style = .destructive; reset.enabled = canEdit
        reset.action = { [weak self] in self?.apply(.resetAll) }
        sections.append(.init(rows: [export, importRow, resetNames, resetPremium, reset]))
        setSections(sections)
    }

    private func selectPeer() {
        guard canEdit else { return }
        let selector = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context,
            filter: [.excludeRecent, .doNotSearchMessages], hasContactSelector: false, title: "Local name"))
        selector.peerSelected = { [weak self, weak selector] peer, _ in
            selector?.dismiss()
            guard let self, self.canEdit, let key = exteralessIdentityPeerKey(peer) else { return }
            self.push(ExteralessIdentityAliasController(context: self.context, permit: self.permit, peer: peer, key: key,
                originalName: self.originalName(for: peer)))
        }
        push(selector)
    }

    private func originalName(for peer: EnginePeer) -> String {
        if case let .user(user) = peer,
           let name = IdentityNamePolicy.userName(first: user.firstName, last: user.lastName, alias: nil, order: identityState?.nameOrder ?? .firstLast) {
            return name
        }
        return peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
    }

    private func selectStatus() {
        guard canEdit, let state = identityState, state.localPremium else { return }
        exteralessIdentityPickEmoji(context: context, parent: self, source: view, status: true,
            selected: state.emojiStatus?.documentId ?? peer?.emojiStatus?.fileId) { [weak self] file, until in
                guard let self, self.canEdit else { return }
                self.apply(.emojiStatus(file.map { IdentityEmojiStatus(documentId: $0.fileId.id, until: until) }, expected: state.emojiStatus), emojiFiles: file.map { [$0] } ?? [])
            }
    }
}

@MainActor
private final class ExteralessIdentityNameOrderController: ExteralessIdentityController {
    override func render() {
        title = "Name order"
        var rows: [ExteralessSettingsRow] = []
        if let state = identityState {
            for option in IdentityFeatures.accountDefinitions.first(where: { $0.key == "identity.nameOrder" })?.options ?? [] {
                guard case let .integer(value) = option.value, let rawValue = Int(exactly: value), let order = IdentityNameOrder(rawValue: rawValue) else { continue }
                var row = ExteralessSettingsRow(id: String(order.rawValue), title: option.title)
                row.enabled = canEdit; row.accessory = state.nameOrder == order ? .checkmark : .none
                row.action = { [weak self] in self?.apply(.nameOrder(order, expected: state.nameOrder)) }
                rows.append(row)
            }
        }
        setSections(identityOperationSections() + [.init(rows: rows)])
    }
}
