import Foundation
import PluginHost

/// Bootstrap indirection for the coordinator's Sendable callback closure. Avoids
/// capturing a mutable local provider variable while its initializer is running.
public final class PluginUICallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private weak var provider: PluginUIBridgeExtension?

    public init() {}

    public func bind(_ provider: PluginUIBridgeExtension) {
        self.lock.lock()
        self.provider = provider
        self.lock.unlock()
    }

    public func permits(owner: PluginHost.CallbackOwner, argumentsJSON: String) -> Bool {
        self.lock.lock()
        let provider = self.provider
        self.lock.unlock()
        return provider?.callbackIsCurrent(owner: owner, argumentsJSON: argumentsJSON) ?? false
    }

    /// Terminal batches use the bounded reserved lane. False admission is retried
    /// by the provider before release; this flag is not an unlimited bypass.
    public static func isTerminal(argumentsJSON: String) -> Bool {
        guard let metadata = (try? PluginUIJSON.decode(argumentsJSON))?.array?.first?.object else { return false }
        return metadata["event"] == .string("closed") || metadata["_uiTerminal"] == .bool(true)
    }
}
