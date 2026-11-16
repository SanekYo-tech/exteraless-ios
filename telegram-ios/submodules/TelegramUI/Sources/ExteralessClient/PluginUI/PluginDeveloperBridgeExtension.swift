import ExteralessCore
import Foundation
import PluginHost

/// Owner-scoped listener controls only. Host-wide authenticated commands remain
/// in PluginDeveloperServer/ExteralessPluginRuntime, never in Python dispatch.
final class PluginDeveloperBridgeExtension: PluginBridgeExtension, @unchecked Sendable {
    private static let methods: Set<String> = [
        "getDeveloperServerState", "requestDeveloperServerStart", "requestDeveloperServerStop",
    ]
    let exportedMethods: [String: Set<String>] = ["exteraless.ios.Runtime": PluginDeveloperBridgeExtension.methods]
    private let snapshot: @Sendable () -> PluginDeveloperConnectionState
    private let enabled: @Sendable () -> Bool
    private let captureOwner: @Sendable (String) -> PluginHost.CallbackOwner?
    private let permits: @Sendable (String, PluginPermission) -> Bool
    private let permissionAdmission: PluginPermissionAdmission
    private struct Admission: Hashable, Sendable {
        let owner: PluginHost.CallbackOwner
        let permissionIsCurrent: @Sendable () -> Bool
        // Keep the existing per-owner quota, even with a predicate per request.
        static func == (lhs: Admission, rhs: Admission) -> Bool { lhs.owner == rhs.owner }
        func hash(into hasher: inout Hasher) { hasher.combine(owner) }
    }
    private let queue: ExteraConfigCommandQueue<Admission>

    init(snapshot: @escaping @Sendable () -> PluginDeveloperConnectionState,
         enabled: @escaping @Sendable () -> Bool,
         captureOwner: @escaping @Sendable (String) -> PluginHost.CallbackOwner?,
         permits: @escaping @Sendable (String, PluginPermission) -> Bool,
         apply: @escaping @MainActor @Sendable (Bool, PluginConfigAuthority) async throws -> Void,
         failed: @escaping @Sendable (String, Error) -> Void,
         permissionAdmission: @escaping PluginPermissionAdmission) {
        self.snapshot = snapshot
        self.enabled = enabled
        self.captureOwner = captureOwner
        self.permits = permits
        self.permissionAdmission = permissionAdmission
        // Reuse bounded, generation-scoped native admission. Here developer(true)
        // means retry an already opted-in listener, never write the setting true.
        self.queue = ExteraConfigCommandQueue(apply: { admission, mutation in
            guard case let .developer(start) = mutation else {
                throw BridgeFailure.malformed("Expected a native developer listener request")
            }
            let owner = admission.owner
            let current: @Sendable () -> Bool = {
                captureOwner(owner.pluginId) == owner && permits(owner.pluginId, .settings)
                    && admission.permissionIsCurrent()
            }
            guard current() else {
                throw BridgeFailure.invalidHandle("Developer control owner or settings grant expired")
            }
            try await apply(start, PluginConfigAuthority(isCurrent: current))
        }, failed: { admission, _, error in failed(admission.owner.pluginId, error) })
    }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        guard let request = try NativeServiceRequest(json: requestJSON, members: Self.methods) else { return nil }
        if request.memberKind { return try PluginBridgeJSON.success(.string("method")) }
        try request.requireArguments(0)
        guard let token = request.ownerToken, let owner = captureOwner(pluginId), owner.wireToken == token else {
            throw BridgeFailure.invalidHandle("Developer controls require the current immutable C owner epoch")
        }
        guard permits(pluginId, .settings) else {
            throw BridgeFailure.permission("Native developer controls require settings permission")
        }
        let enabled = self.enabled()
        if request.member == "getDeveloperServerState" {
            let connection = snapshot()
            // Native token presence is published only by NWListener.State.ready.
            // Project that readiness bit; never serialize/log the credential.
            return try PluginBridgeJSON.success(.object([
                "ready": .bool(enabled && connection.token != nil),
                "enabled": .bool(enabled), "status": .string(connection.status),
            ]))
        }
        let start = request.member == "requestDeveloperServerStart"
        guard !start || enabled else {
            throw BridgeFailure.permission("Developer mode must already be enabled in the native manager")
        }
        // Capture on the C caller before queue admission, not later in apply.
        // A lower/regrant sequence cannot revive an already queued start/stop.
        let permissionIsCurrent = permissionAdmission(pluginId, [.settings])
        guard permissionIsCurrent() else { throw BridgeFailure.permission("Developer control permission admission expired") }
        let id: String
        do { id = try queue.enqueue(owner: Admission(owner: owner, permissionIsCurrent: permissionIsCurrent), mutation: .developer(start)) }
        catch ExteraConfigCommandError.queueFull {
            throw BridgeFailure.unavailable("Native developer control queue is full")
        }
        return try PluginBridgeJSON.success(.object(["accepted": .bool(true), "operationId": .string(id)]))
    }

    func releaseInstances(pluginId: String) {
        let current = captureOwner(pluginId)
        queue.retire { $0.owner.pluginId == pluginId && $0.owner != current }
    }

    func permissionsChanged(pluginId: String) {
        queue.retire { $0.owner.pluginId == pluginId && !$0.permissionIsCurrent() }
    }
}
