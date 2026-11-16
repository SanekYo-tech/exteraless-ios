#if PLUGIN_TRUST_UI_FIXTURE
import AccountContext
import Display
import Foundation
import PluginHost

/// Prepared loginless-harness entry points over disposable local storage.
/// The caller supplies its harness AccountContext; these entry points never
/// start Runtime, CPython, network work, or any real-account operation.
@MainActor final class PluginTrustUIFixture {
    private let root: URL
    private let model = PermissionsModel()
    private let store: PluginStore
    private let failWrites: Bool
    private var plugins: [Plugin]

    private init(failWrites: Bool) throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("trust-ui-frames-\(UUID().uuidString)")
        self.store = try PluginStore(directory: self.root)
        self.failWrites = failWrites
        self.plugins = [Plugin(id: "trust_fixture", name: "Trust selection fixture", permissions: ["network", "hooks", "native"], permissionsDeclared: true, enabled: false)]
        try self.model.prepareInstall("trust_fixture", replacing: false, to: self.store)
    }

    deinit { try? FileManager.default.removeItem(at: self.root) }

    private func trustActions() -> PluginManagerTrustActions {
        let model = self.model
        let store = self.store
        let failWrites = self.failWrites
        return PluginManagerTrustActions(snapshot: { model.snapshot($0) }, captureEdit: { id, expected, page in
            guard page(), model.snapshot(id) == expected else { throw PluginPermissionStoreError.authorityExpired }
            return .init(setLevel: { level in
                if failWrites { throw CocoaError(.fileWriteNoPermission) }
                try model.setLevel(id, level, to: store, isCurrent: { page() && model.snapshot(id) == expected })
            }, setGrants: { grants in
                if failWrites { throw CocoaError(.fileWriteNoPermission) }
                try model.setConsent(id, level: expected.level, permissions: grants, to: store,
                    isCurrent: { page() && model.snapshot(id) == expected })
            })
        }, readMetadata: { _ in
            guard let plugin = self.plugins.first else { throw PluginHostError.pluginNotFound("trust_fixture") }
            return plugin
        }, captureInstall: { _, plugin, selection, page in
            return {
                if self.failWrites { throw CocoaError(.fileWriteNoPermission) }
                try self.model.prepareInstall(plugin.id, replacing: false, selection: selection, to: self.store, isCurrent: page)
                self.plugins = [plugin]
            }
        })
    }

    static func manager(context: AccountContext, failWrites: Bool = false) throws -> ViewController {
        let fixture = try PluginTrustUIFixture(failWrites: failWrites)
        let actions = PluginManagerActions(status: { "Local trust UI fixture" }, snapshot: { fixture.plugins },
            importPlugin: { _ in throw PluginUIError(message: "Use the level-aware fixture import") },
            setEnabled: { _, _ in throw PluginUIError(message: "This fixture does not execute plugins") },
            remove: { _ in fixture.plugins = [] }, settings: { _ in "[]" }, updateSetting: { _, _, _ in }, click: { _, _ in },
            logs: { [] }, trust: fixture.trustActions())
        return exteralessPluginManagerController(context: context, actions: actions)
    }

    static func install(context: AccountContext) throws -> ViewController {
        let fixture = try PluginTrustUIFixture(failWrites: false)
        let url = fixture.root.appendingPathComponent("trust_fixture.plugin")
        try Data("# inert fixture bytes\n".utf8).write(to: url)
        return PluginTrustInstallController(context: context, copy: PluginImportCopy(url: url, directory: fixture.root),
            metadata: fixture.plugins[0], initial: PluginPermissionRecord(), actions: fixture.trustActions(), completed: {})
    }
}
#endif
