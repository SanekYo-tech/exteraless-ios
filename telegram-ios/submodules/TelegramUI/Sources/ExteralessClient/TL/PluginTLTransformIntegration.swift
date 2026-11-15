import Foundation
import PluginHooks
import PluginHost
import TelegramCore

/// Process-owned adapter. Host dispatch still goes through its awaiting event
/// queue and captured interpreter generations; no Python is called on this thread.
public final class PluginTLTransformIntegration: @unchecked Sendable {
    private weak var host: PluginHost?
    private let registration: PluginTLTransformRegistration

    public init(host: PluginHost, accountIndex: @escaping @Sendable (Int64) -> Int32?,
                diagnostic: @escaping @Sendable (String) -> Void = { NSLog("[PluginTL] %@", $0) }) {
        self.host = host
        self.registration = PluginTLTransformRouter.attach(handler: { [weak host] payload, completion in
            let alive = PluginTLSubmissionGate()
            let task = Task {
                guard let host, host.isRunning, let account = accountIndex(payload.accountRecordId), alive.isActive else {
                    completion(.keepOriginal); return
                }
                do {
                    let kind: ExtensionPointKind
                    switch payload.kind {
                    case .preRequest: kind = .preRequest
                    case .postRequest: kind = .postRequest
                    case .update: kind = .update
                    case .updates: kind = .updates
                    }
                    let errorJSON = try payload.error.map { error in
                        try ExteralessTLValue.object(["_": .string("error"), "code": .integer(Int64(error.code)), "text": .string(error.message)]).jsonString()
                    }
                    let result = try await host.events.transformTL(PluginTLHostPayload(kind: kind, account: account,
                        name: PluginTLObservationCodec.hookName(payload.name), canonicalName: payload.name,
                        valueJSON: payload.valueJSON, metadataJSON: payload.metadataJSON, errorJSON: errorJSON,
                        canCancel: payload.canCancel, originPluginIds: payload.originPluginIds, originRootId: payload.originRootId,
                        normalize: { try payload.normalizedReplacement($0) },
                        shouldExecute: { alive.isActive }))
                    guard alive.isActive, !Task.isCancelled else { return }
                    switch result.strategy {
                    case .default: completion(.keepOriginal)
                    case .cancel: completion(.cancel)
                    case .modify, .modifyFinal:
                        guard let json = result.valueJSON else { completion(.keepOriginal); return }
                        completion(result.strategy == .modifyFinal ? .modifyFinal(json) : .modify(json))
                    }
                } catch {
                    if alive.isActive {
                        diagnostic("TL_HOST_TRANSFORM_FAILED: \(payload.name)")
                        completion(.keepOriginal)
                    }
                }
            }
            return PluginHookCancellation { alive.stop(); task.cancel() }
        }, diagnostic: { code, name, _ in diagnostic("\(code): \(name)") })
    }

    public func updateSubscriptions(active: Bool) {
        guard active, let host, host.isRunning else { self.registration.updateSubscriptions([]); return }
        let kinds: [(ExtensionPointKind, PluginTLTransformKind)] = [(.preRequest, .preRequest), (.postRequest, .postRequest), (.update, .update), (.updates, .updates)]
        self.registration.updateSubscriptions(Set(kinds.compactMap { host.events.subscribers.hasSubscribers($0.0) ? $0.1 : nil }))
    }

    public func detach() { self.registration.detach() }
    deinit { self.registration.detach() }
}
