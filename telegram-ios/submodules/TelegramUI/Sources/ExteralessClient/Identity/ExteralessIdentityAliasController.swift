import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
final class ExteralessIdentityAliasController: ExteralessIdentityController {
    private let key: IdentityPeerKey
    private let originalName: String
    private var expected: String?
    private var draft: String?

    init(context: AccountContext, permit: IdentityEditPermit, peer: EnginePeer?, key: IdentityPeerKey, originalName: String) {
        self.key = key
        self.originalName = originalName
        super.init(context: context, permit: permit)
        allowsRefresh = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didLoadIdentity(_ state: IdentityAccountState) {
        if draft == nil { expected = state.alias(for: key); draft = expected ?? originalName }
    }

    override func render() {
        title = "Local name"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: presentationData.strings.Common_Save, style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.isEnabled = canEdit && draft != nil
        var name = ExteralessSettingsRow(id: "name", title: "Name", detail: "Telegram name: " + originalName)
        name.enabled = canEdit
        name.input = .init(text: draft ?? "", placeholder: originalName, kind: .text, updated: { [weak self] value in self?.draft = value }, submitted: { [weak self] in self?.save() })
        var restore = ExteralessSettingsRow(id: "restore", title: "Restore Telegram name")
        restore.enabled = canEdit
        restore.action = { [weak self] in
            guard let self, self.canEdit else { return }
            self.apply(.alias(peer: self.key, value: nil, expected: self.expected)) { [weak self] in
                self?.expected = nil; self?.draft = self?.originalName; self?.render()
            }
        }
        setSections(identityOperationSections() + [.init(footer: "Visible only in this account on this device.", rows: [name, restore])])
    }

    @objc private func save() {
        guard canEdit, let draft else { return }
        do {
            let normalized = try IdentityNamePolicy.normalizedAlias(draft)
            let value = normalized == originalName ? nil : normalized
            apply(.alias(peer: key, value: value, expected: expected)) { [weak self] in
                self?.expected = value
                self?.dismiss(animated: true)
            }
        } catch { errorText = (error as? IdentityError)?.errorDescription; render() }
    }
}

@MainActor
final class ExteralessIdentityImportController: ExteralessIdentityController {
    private var archive = ""
    private var status = ""
    private var colors = ""

    override func render() {
        title = "Import local identity"
        var rows: [ExteralessSettingsRow] = []
        for (id, title, value) in [("archive", "Native identity archive", archive), ("status", "Android emoji status JSON", status), ("colors", "Android quote colors JSON", colors)] {
            var row = ExteralessSettingsRow(id: id, title: title)
            row.enabled = canEdit
            row.input = .init(text: value, placeholder: "Paste JSON", kind: .json, updated: { [weak self] value in
                switch id { case "archive": self?.archive = value; case "status": self?.status = value; default: self?.colors = value }
            }, submitted: {})
            rows.append(row)
        }
        var apply = ExteralessSettingsRow(id: "apply", title: "Import into this account")
        apply.enabled = canEdit; apply.style = .accent
        apply.action = { [weak self] in self?.importData() }
        rows.append(apply)
        setSections(identityOperationSections() + [.init(footer: "Paste a native export, or the original useLocalEmojiStatusData / useLocalQuoteColorData records. Native exports are matched to their owning account.", rows: rows)])
    }

    private func importData() {
        guard canEdit, let current = identityState else { return }
        do {
            let updated: IdentityAccountState
            if !archive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated = try IdentityArchive.decode(Data(archive.utf8), owner: permit.account)
            } else {
                guard !status.isEmpty || !colors.isEmpty else { throw IdentityError.invalidData }
                updated = try IdentityArchive.importAndroid(statusJSON: status.isEmpty ? nil : status, colorsJSON: colors.isEmpty ? nil : colors, into: current)
            }
            apply(.replace(updated, expected: current)) { [weak self] in self?.dismiss(animated: true) }
        } catch { errorText = (error as? IdentityError)?.errorDescription; render() }
    }
}
