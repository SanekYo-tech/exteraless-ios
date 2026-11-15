import Foundation
import PluginHost

/// Only platform identity and disk storage are fixtures. Native SDK UI goes to
/// PluginUIBridgeExtension, never constructUI or a fake success response.
final class ClientHarnessServices: PluginMessagesService, PluginSettingsService, PluginUIService,
    PluginPlatformService, @unchecked Sendable {
    let platformSnapshot: PluginPlatformSnapshot
    let serviceStorage: PluginServiceStorage
    let serviceLogs = PluginServiceLogBuffer(capacity: 64)
    let runtimeVersion = "client-ui-harness/1"
    let protectedPaths: [String]
    private let journal: ClientHarnessJournal

    init(root: URL, recordId: Int64, userId: Int64, scale: Double, journal: ClientHarnessJournal) {
        self.platformSnapshot = PluginPlatformSnapshot(displayScale: scale,
            accounts: [PluginServiceAccount(index: 41, recordId: recordId, userId: userId)], selectedAccountIndex: 41)
        self.serviceStorage = PluginServiceStorage(rootDirectory: root)
        self.protectedPaths = [root.deletingLastPathComponent().appendingPathComponent("client-settings.json").path]
        self.journal = journal
    }

    func selectedAccount() throws -> Int32 { try self.platformSnapshot.selectedAccount() }
    func dp(_ value: Double) throws -> Double { try self.platformSnapshot.points(value, pixelAligned: true) }
    func instanceHandle(fqcn: String, account: Int32) throws -> Int64 { throw self.unprovided("instanceHandle." + fqcn) }
    func themeKey(_ name: String) throws -> String { throw self.unprovided("themeKey." + name) }
    func themeColor(forKey key: String) throws -> Int32 { throw self.unprovided("themeColor." + key) }
    func constructUI(fqcn: String, arguments: [Any]) throws -> Int64 { throw self.unprovided("constructUI." + fqcn) }
    func runOnUIThread(delayMs: Int, work: @escaping @Sendable () -> Void) {
        fatalError("client-ui-harness: PluginUIService.runOnUIThread is not provided")
    }
    func addToClipboard(_ text: String, pluginId: String, lease: PluginNativeCallLease) throws { throw self.unprovided("clipboard") }
    func openURL(_ url: URL, pluginId: String, lease: PluginNativeCallLease) throws { throw self.unprovided("openURL") }
    func sendMessage(_ request: PluginTextMessageRequest, lease: PluginNativeCallLease) throws -> String { throw self.unprovided("sendMessage") }
    func releaseInstances(pluginId: String) {
        self.journal.record("platform-release", ["pluginId": pluginId])
    }

    private func unprovided(_ name: String) -> BridgeFailure {
        self.journal.reject(name)
        return .unimplemented("client-ui-harness: " + name + " is not provided")
    }
}
