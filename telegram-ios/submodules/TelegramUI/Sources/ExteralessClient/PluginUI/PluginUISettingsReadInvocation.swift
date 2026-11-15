import Foundation
import PluginHost

/// Captured before the native settings read's first Task/await. This is separate
/// from an action permit: initial reads are allowed while the page is appearing,
/// before it has a rendered schema from which an action could be authorized.
public struct PluginUISettingsReadInvocation: Sendable {
    public let owner: PluginHost.CallbackOwner
    public let account: Int32
    public let accountRecordId: Int64
    private let accountGate: PluginUISettingsAccountGate
    private let accountToken: PluginUISettingsAccountToken
    private let permit: PluginUISettingsReadPermit

    init(owner: PluginHost.CallbackOwner, accountGate: PluginUISettingsAccountGate,
         accountToken: PluginUISettingsAccountToken, permit: PluginUISettingsReadPermit) {
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

public enum PluginUISettingsReadExecution {
    @TaskLocal public static var current: PluginUISettingsReadInvocation?

    public static func require(pluginId: String) throws -> PluginUISettingsReadInvocation {
        guard let value = self.current, value.owner.pluginId == pluginId, value.isCurrent else {
            throw PluginHostError.superseded("Native settings read has no current captured owner/account/page request")
        }
        return value
    }

    @MainActor static func withInvocation<Value: Sendable>(_ invocation: PluginUISettingsReadInvocation,
        operation: @MainActor () async throws -> Value) async throws -> Value {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            guard invocation.isCurrent else { throw PluginHostError.superseded("Settings read was revoked before admission") }
            return try await self.$current.withValue(invocation, operation: operation)
        }, onCancel: { invocation.cancel() })
    }
}
