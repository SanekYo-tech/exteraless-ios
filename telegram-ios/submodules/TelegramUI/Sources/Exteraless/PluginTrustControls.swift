import AccountContext
import Foundation
import PluginHost
import UIKit

/// Factories capture native page/account/owner authority synchronously, before
/// PluginListController creates its Task. No setter is exported to Python.
@MainActor public struct PluginManagerTrustActions {
    public typealias Predicate = @Sendable () -> Bool
    public typealias Operation = @MainActor () async throws -> Void
    public struct Edit {
        public let setLevel: (PluginTrustLevel) async throws -> Void
        public let setGrants: ([PluginPermission]) async throws -> Void
        public init(setLevel: @escaping (PluginTrustLevel) async throws -> Void,
                    setGrants: @escaping ([PluginPermission]) async throws -> Void) {
            self.setLevel = setLevel
            self.setGrants = setGrants
        }
    }
    public let snapshot: (String) -> PluginPermissionSnapshot
    public let captureEdit: (String, PluginPermissionSnapshot, @escaping Predicate) throws -> Edit
    public let readMetadata: (URL) async throws -> Plugin
    public let captureInstall: (URL, Plugin, PluginPermissionRecord, @escaping Predicate) throws -> Operation

    public init(snapshot: @escaping (String) -> PluginPermissionSnapshot,
                captureEdit: @escaping (String, PluginPermissionSnapshot, @escaping Predicate) throws -> Edit,
                readMetadata: @escaping (URL) async throws -> Plugin,
                captureInstall: @escaping (URL, Plugin, PluginPermissionRecord, @escaping Predicate) throws -> Operation) {
        self.snapshot = snapshot
        self.captureEdit = captureEdit
        self.readMetadata = readMetadata
        self.captureInstall = captureInstall
    }
}

@MainActor func pluginTrustSections(record: PluginPermissionRecord, unsafeMode: Bool, busy: Bool,
    selectLevel: @escaping (PluginTrustLevel) -> Void,
    selectGrant: @escaping (PluginPermission, Bool) -> Void) -> [PluginListSection] {
    let explanations: [PluginTrustLevel: String] = [
        .isolated: "0 · UI only. Network, files, messages and dangerous permissions are capped off.",
        .gated: "1 · Only individually selected non-dangerous permissions. Hooks and native-code consent are capped off.",
        .trusted: "2 · Dangerous permissions may also be selected individually. Choosing this level grants nothing by itself."
    ]
    let levels = PluginTrustLevel.allCases.map { level -> PluginListRow in
        var row = PluginListRow(id: "trust-level:\(level.rawValue)", title: level.name, detail: explanations[level])
        row.accessory = record.level == level ? .checkmark : .none
        row.enabled = !busy
        row.action = { selectLevel(level) }
        return row
    }
    var sections = [PluginListSection(title: "Access level", footer: "Lowering the level removes incompatible stored grants. Raising it later does not restore them.", rows: levels)]
    if unsafeMode {
        sections.append(PluginListSection(rows: [PluginListRow(id: "trust-unsafe", title: "Global unsafe mode is active",
            detail: "The existing global mode currently overrides permission checks. This editor changes stored consent for the selected level.")]))
    }
    let rows = PluginPermission.requestable.map { permission -> PluginListRow in
        let allowed = record.level.allows(permission)
        let stored = record.grants.contains(permission)
        var detail = permission.rawValue
        if !allowed { detail += " · blocked by \(record.level.name)" }
        if stored && !allowed { detail += " · stored, currently inactive" }
        let title: String
        switch permission {
        case .hooks:
            title = "Hooks consent"
            detail += " · Android/JVM/Xposed execution is unavailable on iOS. Consent does not provide it."
        case .native:
            title = "Native-code consent"
            detail += " · Consent does not enable unsupported native-library loading on this platform."
        default: title = permission.describe
        }
        var row = PluginListRow(id: "permission:\(permission.rawValue)", title: title, detail: detail)
        row.enabled = !busy && (allowed || stored)
        row.toggle = (stored, { value in selectGrant(permission, value) })
        return row
    }
    sections.append(PluginListSection(title: "Stored grants", footer: "UI is always available. A level is a cap; every other permission still needs explicit consent.", rows: rows))
    return sections
}

/// A real selection screen over the native-staged file; no plugin is executed
/// while its metadata, level and grant choices are being reviewed.
final class PluginTrustInstallController: PluginListController {
    private let copy: PluginImportCopy
    private let metadata: Plugin
    private let actions: PluginManagerTrustActions
    private let completed: () -> Void
    private var selection: PluginTrustSelection
    private let page = PluginUISettingsPageGate()

    init(context: AccountContext, copy: PluginImportCopy, metadata: Plugin, initial: PluginPermissionRecord,
         actions: PluginManagerTrustActions, completed: @escaping () -> Void) {
        self.copy = copy
        self.metadata = metadata
        self.actions = actions
        self.completed = completed
        self.selection = PluginTrustSelection(record: initial)
        super.init(context: context)
        self.title = "Install \(metadata.displayName)"
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.page.close() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.page.setVisible(true)
        self.page.publish()
    }
    override func viewWillDisappear(_ animated: Bool) {
        self.page.setVisible(false)
        super.viewWillDisappear(animated)
    }

    override func render() {
        var sections = self.operationSections()
        sections.append(PluginListSection(rows: [PluginListRow(id: "trust-import-metadata", title: self.metadata.displayName,
            detail: "\(self.metadata.id) · \(self.metadata.subtitle)\nRequested: \(self.metadata.permissions.joined(separator: ", "))")]))
        sections += pluginTrustSections(record: self.selection.record, unsafeMode: self.actions.snapshot(self.metadata.id).unsafeMode,
            busy: self.isBusy, selectLevel: { [weak self] level in
                guard let self, !self.isBusy else { return }
                self.selection.selectLevel(level)
                self.page.publish()
                self.render()
            }, selectGrant: { [weak self] permission, value in
                guard let self, !self.isBusy else { return }
                do { try self.selection.select(permission, granted: value); self.errorText = nil }
                catch { self.errorText = pluginErrorText(error) }
                self.page.publish()
                self.render()
            })
        var install = PluginListRow(id: "trust-install", title: "Install with selected access")
        install.enabled = !self.isBusy
        install.style = .accent
        install.action = { [weak self] in self?.install() }
        sections.append(PluginListSection(rows: [install]))
        self.setSections(sections)
    }

    private func install() {
        guard !self.isBusy else { return }
        do {
            let permit = try self.page.capture()
            let operation = try self.actions.captureInstall(self.copy.url, self.metadata, self.selection.record, { permit.isCurrent })
            self.perform(title: "Installing selected plugin…", operation: { [copy = self.copy] in
                defer { withExtendedLifetime(copy) {} }
                try await operation()
            }, completion: { [weak self] _ in
                guard let self else { return }
                self.completed()
                if self.isScreenVisible { self.dismiss(animated: true) }
            })
        } catch { self.errorText = pluginErrorText(error); self.render() }
    }
}
