import Foundation

struct PluginUINavigationModel: Equatable, Sendable {
    let route: String
    let sourceId: UUID?
    let peerType: String?
    let peerId: Int64?
    let messageId: Int32?

    init(_ raw: PluginUIJSON) throws {
        guard let object = raw.object, let route = try object.uiString("route", limit: 32) else {
            throw PluginUIFailure.malformed("uiNavigate requires a route")
        }
        try object.uiFields(["route", "sourceId", "peer", "messageId"], name: "uiNavigate")
        guard ["chat", "back"].contains(route) else {
            throw PluginUIFailure.unsupported("Unsupported navigation route: \(route); use uiPresent(page/settings) for plugin pages")
        }
        self.route = route
        if let source = try object.uiString("sourceId", limit: 64) {
            guard let id = UUID(uuidString: source) else { throw PluginUIFailure.invalidHandle("Invalid native fragment id") }
            self.sourceId = id
        } else { self.sourceId = nil }
        if route == "chat" {
            guard let peer = object["peer"]?.object, let type = try peer.uiString("type", limit: 16), ["user", "group", "channel"].contains(type),
                  let id = peer["id"]?.integer, id > 0, id <= 0x00ff_ffff_ffff_ffff else {
                throw PluginUIFailure.malformed("Chat navigation requires peer {type:user|group|channel,id:positive Int64}")
            }
            try peer.uiFields(["type", "id"], name: "peer")
            self.peerType = type
            self.peerId = id
        } else {
            guard self.sourceId != nil, object["peer"] == nil, object["messageId"] == nil else {
                throw PluginUIFailure.malformed("Back requires the sourceId from uiActiveFragment and no peer/message")
            }
            self.peerType = nil
            self.peerId = nil
        }
        if let raw = object["messageId"], raw != .null {
            guard let integer = raw.integer, let id = Int32(exactly: integer), id > 0 else { throw PluginUIFailure.malformed("messageId must be a positive Int32") }
            self.messageId = id
        } else { self.messageId = nil }
    }
}

/// Synchronous bridge queries return only a Sendable JSON snapshot. A blocked
/// main queue gives a named timeout; it never makes the C worker wait forever.
/// This helper is strictly read-only: a timed-out read may later be discarded.
final class PluginUIReadback: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<PluginUIJSON, Error>?
    private var cancelled = false
    private let semaphore = DispatchSemaphore(value: 0)

    private func run(_ body: @MainActor () throws -> PluginUIJSON) {
        self.lock.lock()
        let cancelled = self.cancelled
        self.lock.unlock()
        guard !cancelled else { return }
        let value = Result { try MainActor.assumeIsolated { try body() } }
        self.lock.lock()
        if !self.cancelled { self.result = value }
        self.lock.unlock()
        self.semaphore.signal()
    }

    static func read(_ body: @escaping @MainActor @Sendable () throws -> PluginUIJSON) throws -> PluginUIJSON {
        if Thread.isMainThread { return try MainActor.assumeIsolated { try body() } }
        let box = PluginUIReadback()
        DispatchQueue.main.async { box.run(body) }
        guard box.semaphore.wait(timeout: .now() + .milliseconds(750)) == .success else {
            box.lock.lock()
            box.cancelled = true
            box.lock.unlock()
            throw PluginUIFailure.unavailable("Native UI readback timed out (750 ms)")
        }
        box.lock.lock()
        let result = box.result
        box.lock.unlock()
        guard let result else { throw PluginUIFailure.unavailable("Native UI readback was cancelled") }
        return try result.get()
    }
}
