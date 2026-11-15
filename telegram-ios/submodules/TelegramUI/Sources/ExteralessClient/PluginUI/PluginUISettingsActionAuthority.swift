import AccountContext
import Foundation
import PluginHost

/// Installed once by the application Runtime with its real Host and account-slot
/// lookup. Account replacement is revoked synchronously before services are moved.
@MainActor public final class PluginUISettingsActionAuthority {
    private let captureOwner: @Sendable (String) -> PluginHost.CallbackOwner?
    private let accountIndex: @MainActor (Int64) -> Int32?
    private weak var context: AccountContext?
    private let accountGate = PluginUISettingsAccountGate()

    public init(captureOwner: @escaping @Sendable (String) -> PluginHost.CallbackOwner?,
                accountIndex: @escaping @MainActor (Int64) -> Int32?) {
        self.captureOwner = captureOwner
        self.accountIndex = accountIndex
    }

    deinit { self.accountGate.clear() }

    public func prepareContextChange(to context: AccountContext) {
        if self.context !== context { self.clearContext() }
    }

    public func update(context: AccountContext) {
        guard let index = self.accountIndex(context.account.id.int64), index >= 0 else { self.clearContext(); return }
        if self.context === context, let current = self.accountGate.snapshot,
           current.recordId == context.account.id.int64, current.index == index { return }
        self.accountGate.replace(recordId: context.account.id.int64, index: index)
        self.context = context
    }

    public func clearContext() { self.accountGate.clear(); self.context = nil }

    public func capture(context: AccountContext, pluginId: String) -> PluginUISettingsActionScope? {
        guard self.context === context, let token = self.accountGate.snapshot,
              token.recordId == context.account.id.int64, let owner = self.captureOwner(pluginId), owner.pluginId == pluginId else { return nil }
        return PluginUISettingsActionScope(owner: owner, accountGate: self.accountGate,
            accountToken: token, captureOwner: self.captureOwner)
    }
}

/// Keeps existing ManagerActions constructors source-compatible. A missing
/// production authority denies mutations; a MainActor Bool is never upgraded to
/// a worker execution capability. Harnesses may inject an explicit owned scope.
@MainActor public enum PluginUISettingsActionRegistry {
    private static weak var authority: PluginUISettingsActionAuthority?

    public static func install(_ authority: PluginUISettingsActionAuthority?) { self.authority = authority }

    static func capture(context: AccountContext, pluginId: String) -> PluginUISettingsActionScope? {
        return self.authority?.capture(context: context, pluginId: pluginId)
    }
}
