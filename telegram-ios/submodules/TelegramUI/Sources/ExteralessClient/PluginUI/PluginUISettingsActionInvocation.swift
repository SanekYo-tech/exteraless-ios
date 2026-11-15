import Foundation
import PluginHost

/// Typed native action provenance carried through the existing ManagerActions
/// async closures. The UI captures it before creating its operation Task; Runtime
/// must read it before operationHost() and pass the exact owner/index to Host.
public struct PluginUISettingsActionInvocation: Sendable {
    public let owner: PluginHost.CallbackOwner
    public let account: Int32
    public let accountRecordId: Int64
    private let accountGate: PluginUISettingsAccountGate
    private let accountToken: PluginUISettingsAccountToken
    private let permit: PluginUISettingsActionPermit

    init(owner: PluginHost.CallbackOwner, accountGate: PluginUISettingsAccountGate,
         accountToken: PluginUISettingsAccountToken, permit: PluginUISettingsActionPermit) {
        self.owner = owner
        self.account = accountToken.index
        self.accountRecordId = accountToken.recordId
        self.accountGate = accountGate
        self.accountToken = accountToken
        self.permit = permit
    }

    public var isCurrent: Bool { self.accountGate.permits(self.accountToken) && self.permit.isCurrent }
    public func cancel() { self.permit.cancel() }
}

public enum PluginUISettingsActionExecution {
    @TaskLocal public static var current: PluginUISettingsActionInvocation?

    public static func require(pluginId: String) throws -> PluginUISettingsActionInvocation {
        guard let value = self.current, value.owner.pluginId == pluginId, value.isCurrent else {
            throw PluginHostError.superseded("Native settings action has no current captured owner/account/page revision")
        }
        return value
    }

    @MainActor static func withInvocation<Value: Sendable>(_ invocation: PluginUISettingsActionInvocation,
        operation: @MainActor () async throws -> Value) async throws -> Value {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            guard invocation.isCurrent else { throw PluginHostError.superseded("Settings action was revoked before admission") }
            return try await self.$current.withValue(invocation, operation: operation)
        }, onCancel: { invocation.cancel() })
    }
}

/// A subpage forks page visibility/revision, but retains its parent's immutable
/// owner and account token. It never recaptures the newest owner by plugin id.
public final class PluginUISettingsActionScope: @unchecked Sendable {
    private let owner: PluginHost.CallbackOwner
    private let accountGate: PluginUISettingsAccountGate
    private let accountToken: PluginUISettingsAccountToken
    private let captureOwner: @Sendable (String) -> PluginHost.CallbackOwner?
    private let page = PluginUISettingsPageGate()

    init(owner: PluginHost.CallbackOwner, accountGate: PluginUISettingsAccountGate,
         accountToken: PluginUISettingsAccountToken,
         captureOwner: @escaping @Sendable (String) -> PluginHost.CallbackOwner?) {
        self.owner = owner
        self.accountGate = accountGate
        self.accountToken = accountToken
        self.captureOwner = captureOwner
    }

    deinit { self.page.close() }

    func fork() -> PluginUISettingsActionScope {
        return PluginUISettingsActionScope(owner: self.owner, accountGate: self.accountGate,
            accountToken: self.accountToken, captureOwner: self.captureOwner)
    }

    func publish() { self.page.publish() }
    func invalidate() { self.page.invalidate() }
    func invalidateActions() { self.page.invalidateActions() }
    func beginAppearance() { self.page.beginAppearance() }
    func setVisible(_ visible: Bool) { self.page.setVisible(visible) }
    func close() { self.page.close() }

    func capture() throws -> PluginUISettingsActionInvocation {
        guard self.accountGate.permits(self.accountToken), self.captureOwner(self.owner.pluginId) == self.owner else {
            throw PluginHostError.superseded("Settings page belongs to an expired account/interpreter")
        }
        return try PluginUISettingsActionInvocation(owner: self.owner, accountGate: self.accountGate,
            accountToken: self.accountToken, permit: self.page.capture())
    }

    func captureRead() throws -> PluginUISettingsReadInvocation {
        guard self.accountGate.permits(self.accountToken), self.captureOwner(self.owner.pluginId) == self.owner else {
            throw PluginHostError.superseded("Settings read belongs to an expired account/interpreter")
        }
        return try PluginUISettingsReadInvocation(owner: self.owner, accountGate: self.accountGate,
            accountToken: self.accountToken, permit: self.page.captureRead())
    }
}
