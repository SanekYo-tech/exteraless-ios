import ExteralessCore
import Foundation

/// Preserves explicit-vs-timer refresh and asynchronous long-press handling without
/// extending the frozen Core provider enum. Registry remains the owner of pill views/lifetimes.
enum PluginPillBridgeActions {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        weak var bridge: PluginPillBridgeExtension?
    }
    private static let storage = Storage()
    static func install(_ bridge: PluginPillBridgeExtension) {
        self.storage.lock.lock(); self.storage.bridge = bridge; self.storage.lock.unlock()
    }
    private static var bridge: PluginPillBridgeExtension? {
        self.storage.lock.lock(); defer { self.storage.lock.unlock() }; return self.storage.bridge
    }
    static func refresh(id: Int, scope: PillAccountScope, force: Bool) -> Bool {
        self.bridge?.route(nativeId: id, scope: scope, action: .refresh, force: force) ?? false
    }
    static func longPress(id: Int, scope: PillAccountScope, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        self.bridge?.route(nativeId: id, scope: scope, action: .longPress, force: true, completion: completion) ?? false
    }
}
