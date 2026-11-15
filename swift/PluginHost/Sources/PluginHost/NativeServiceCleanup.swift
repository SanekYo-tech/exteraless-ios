import Foundation

/// Request data, not an active-owner capability. It only matches an immutable
/// identity already stored on the resource being revoked.
public struct NativeServiceCleanupIdentity: Equatable, Sendable {
    public let pluginId: String
    public let ownerToken: String

    public init(pluginId: String, ownerToken: String) throws {
        guard !pluginId.isEmpty, !ownerToken.isEmpty, ownerToken.utf8.count <= 128, !ownerToken.contains("\0") else {
            throw BridgeFailure.invalidHandle("Native cleanup requires its bound interpreter token")
        }
        self.pluginId = pluginId
        self.ownerToken = ownerToken
    }
}

/// Shared production cleanup path, also usable by a headless native provider
/// fixture. Retiring SDK unload can run this while captureOwner is intentionally nil.
public enum NativeServiceCleanupRoute {
    public static let members: Set<String> = ["cancelOwnerTask", "nativeServiceCancel", "notificationUnsubscribe", "fileRemove", "intentRemove"]

    public static func dispatch<Owner: Hashable & Sendable>(
        _ request: NativeServiceRequest, pluginId: String,
        scheduler: NativeServiceOwnerScheduler<Owner>, operations: NativeServiceOperations<Owner>,
        interceptions: NativeServiceInterceptions<Owner>,
        cancelledOperation: (String) -> Void
    ) throws -> PluginJSONValue? {
        guard members.contains(request.member) else { return nil }
        try request.requireArguments(1)
        let id = try NativeServiceWire.string(request.arguments[0], name: "id", maximum: 128)
        guard let token = request.ownerToken else { throw BridgeFailure.invalidHandle("Native cleanup requires its bound interpreter token") }
        let identity = try NativeServiceCleanupIdentity(pluginId: pluginId, ownerToken: token)
        switch request.member {
        case "cancelOwnerTask":
            return .bool(scheduler.cancel(id: id, cleanup: identity))
        case "nativeServiceCancel", "notificationUnsubscribe":
            let cancelled = operations.cancel(id: id, cleanup: identity)
            if cancelled { cancelledOperation(id) }
            return .bool(cancelled)
        case "fileRemove", "intentRemove":
            _ = interceptions.remove(id: id, cleanup: identity, file: request.member == "fileRemove")
            return .null
        default:
            return nil
        }
    }
}
