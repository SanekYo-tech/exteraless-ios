import Foundation
import PluginHost
import ExteralessCore

/// Closed global manager operations. No arbitrary preference key or callable can
/// enter this queue from an SDK request.
typealias PluginConfigMutation = ExteraConfigManagerMutation

/// A value capability which can follow an admitted command into its detached
/// writer without turning an escaping check into a cached Boolean.
struct PluginConfigAuthority: Sendable {
    let isCurrent: @Sendable () -> Bool
}

/// Global SDK projections use the real PluginManagerPreferences snapshot. Native
/// mode changes enter existing Runtime controls; no Python runs on main and no
/// C worker synchronously waits for main, disk, or Host maintenance.
final class PluginConfigBridgeExtension: PluginBridgeExtension, @unchecked Sendable {
    let exportedMethods: [String: Set<String>] = [
        "exteraless.ios.Runtime": ["getPluginConfig", "setPluginConfig"]
    ]
    private let snapshot: @Sendable () throws -> PluginManagerPresentationState
    private let installedIds: @Sendable () -> Set<String>
    private let captureOwner: @Sendable (String) -> PluginHost.CallbackOwner?
    private let permits: @Sendable (String, PluginPermission) -> Bool
    private let queue: ExteraConfigCommandQueue<PluginHost.CallbackOwner>

    init(snapshot: @escaping @Sendable () throws -> PluginManagerPresentationState,
         installedIds: @escaping @Sendable () -> Set<String>,
         captureOwner: @escaping @Sendable (String) -> PluginHost.CallbackOwner?,
         permits: @escaping @Sendable (String, PluginPermission) -> Bool,
          apply: @escaping @MainActor @Sendable (PluginConfigMutation, PluginConfigAuthority) async throws -> Void,
         failed: @escaping @Sendable (String, String, Error) -> Void) {
        self.snapshot = snapshot
        self.installedIds = installedIds
        self.captureOwner = captureOwner
        self.permits = permits
        self.queue = ExteraConfigCommandQueue(apply: { owner, mutation in
            try await Self.perform(owner: owner, mutation: mutation, captureOwner: captureOwner, permits: permits, apply: apply)
        }, failed: { owner, field, error in failed(owner.pluginId, field, error) })
    }

    @MainActor private static func perform(owner: PluginHost.CallbackOwner, mutation: PluginConfigMutation,
        captureOwner: @escaping @Sendable (String) -> PluginHost.CallbackOwner?, permits: @escaping @Sendable (String, PluginPermission) -> Bool,
        apply: @MainActor @Sendable (PluginConfigMutation, PluginConfigAuthority) async throws -> Void) async throws {
        let current: @Sendable () -> Bool = { captureOwner(owner.pluginId) == owner && permits(owner.pluginId, .settings) }
        guard current() else {
            throw BridgeFailure.invalidHandle("Plugin config caller or settings grant expired before execution")
        }
        try await apply(mutation, PluginConfigAuthority(isCurrent: current))
    }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        guard let request = try NativeServiceRequest(json: requestJSON, members: Set(["getPluginConfig", "setPluginConfig"])) else { return nil }
        if request.memberKind { return try PluginBridgeJSON.success(.string("method")) }
        guard requestJSON.utf8.count <= 262_144 else { throw BridgeFailure.malformed("Plugin config request exceeds 256 KiB") }
        guard let token = request.ownerToken, let owner = captureOwner(pluginId), owner.wireToken == token else {
            throw BridgeFailure.invalidHandle("Plugin config requires its current immutable C owner epoch")
        }
        guard permits(pluginId, .settings) else { throw BridgeFailure.permission("Plugin config requires settings permission") }
        try request.requireArguments(request.member == "getPluginConfig" ? 1 : 2)
        guard case let .string(field) = request.arguments[0] else { throw BridgeFailure.malformed("Plugin config field must be a string") }
        if field == "compatibilityMode" {
            throw BridgeFailure.unimplemented("PluginsDisableArtOpts targets Android ART Profile Saver, absent from the native runtime")
        }
        let fields: Set<String> = ["engineEnabled", "safeMode", "developerMode", "compactView", "pinned"]
        guard fields.contains(field) else { throw BridgeFailure.unimplemented("Unknown global plugin config field: \(field)") }
        if request.member == "getPluginConfig" {
            let state = try snapshot()
            let value: PluginJSONValue
            switch field {
            case "engineEnabled": value = .bool(state.engineEnabled)
            case "safeMode": value = .bool(state.safeMode)
            case "developerMode": value = .bool(state.developerMode)
            case "compactView": value = .bool(state.compactView)
            default: value = .array(state.pinned.intersection(installedIds()).sorted().map(PluginJSONValue.string))
            }
            return try PluginBridgeJSON.success(value)
        }
        let mutation: PluginConfigMutation
        if field == "pinned" {
            guard case let .array(raw) = request.arguments[1], raw.count <= 4096 else {
                throw BridgeFailure.malformed("Pinned plugins require a bounded array of plugin IDs")
            }
            var ids = Set<String>()
            for value in raw {
                guard case let .string(id) = value, Plugin.isValidID(id) else { throw BridgeFailure.malformed("Invalid pinned plugin ID") }
                ids.insert(id)
            }
            // Original ExteraConfig.setPinnedPlugins affects existing plugins only.
            mutation = .pinned(ids.intersection(installedIds()))
        } else {
            guard case let .bool(value) = request.arguments[1] else { throw BridgeFailure.malformed("Plugin config flag must be Bool, not an integer") }
            switch field {
            case "engineEnabled": mutation = .engine(value)
            case "safeMode": mutation = .safeMode(value)
            case "developerMode": mutation = .developer(value)
            default: mutation = .compact(value)
            }
        }
        _ = try snapshot() // An unavailable native store fails before admission.
        let id: String
        do { id = try queue.enqueue(owner: owner, mutation: mutation) }
        catch ExteraConfigCommandError.queueFull { throw BridgeFailure.unavailable("Plugin config command queue is full") }
        return try PluginBridgeJSON.success(.object(["accepted": .bool(true), "operationId": .string(id)]))
    }

    func releaseInstances(pluginId: String) {
        let current = captureOwner(pluginId)
        queue.retire { $0.pluginId == pluginId && $0 != current }
    }
}
