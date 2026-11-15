import Foundation

/// Deliberate, tiny DTO-only boundary. C/Host capture the ancestry on the real
/// worker; this recorder never creates an Account, Postbox message or network RPC.
final class SDKTLTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [PluginTextMessageRequest] = []

    func record(_ request: PluginTextMessageRequest) throws -> String {
        guard request.pluginId == "nativeTLSdkZ", request.account.index == 2,
              request.peerKind == .user, request.peerId == 101,
              ["sdk-legacy-origin-child", "sdk-legacy-unrelated"].contains(request.text) else {
            throw BridgeFailure.unimplemented("Only the own bounded legacy text-origin fixture is recorded")
        }
        lock.lock(); defer { lock.unlock() }
        guard requests.count < 4 else { throw BridgeFailure.unavailable("Legacy DTO fixture bound exceeded") }
        requests.append(request)
        return UUID().uuidString
    }

    var snapshot: [PluginTextMessageRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

/// Native-owned request tickets/unique C handles. Responses below are canned DTOs;
/// the TL request/response normalization uses the production Foundation binary codec.
final class SDKTLBoundaryFixture: PluginBridgeExtension, @unchecked Sendable {
    enum Cancellation: Equatable, Sendable { case cancel, completionWon, fail }
    struct Entry: Sendable {
        let id: String
        let owner: PluginHost.CallbackOwner
        let handle: Int64
        let member: String
        let model: PluginJSONValue
        let requestName: String?
    }
    private let callbacks: PluginCallbackDispatcher
    private let codec = ExteralessTLCodec()
    private let lock = NSLock()
    private var requests: [String: Entry] = [:]
    private var cancellation: Cancellation = .cancel
    private var released: [Int64] = []
    private var admitted: [Entry] = []
    let exportedMethods: [String: Set<String>] = ["exteraless.ios.Runtime": ["tlRequest", "tlCancel", "sendMedia", "editMedia"]]

    init(callbacks: PluginCallbackDispatcher) { self.callbacks = callbacks }
    func setCancellation(_ value: Cancellation) { lock.lock(); cancellation = value; lock.unlock() }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var releases: [Int64] { lock.lock(); defer { lock.unlock() }; return released }
    var admissions: [Entry] { lock.lock(); defer { lock.unlock() }; return admitted }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        guard let request = try NativeServiceRequest(json: requestJSON, members: exportedMethods["exteraless.ios.Runtime"]!) else { return nil }
        if request.memberKind { return try PluginBridgeJSON.success(.string("method")) }
        guard requestJSON.utf8.count <= 32_768, let owner = callbacks.captureOwner(pluginId), request.ownerToken == owner.wireToken else {
            throw BridgeFailure.invalidHandle("TL fixture requires the current C owner and at most 32 KiB")
        }
        if request.member == "tlCancel" {
            try request.requireArguments(1)
            let id = try NativeServiceWire.string(request.arguments[0], name: "requestId", maximum: 128)
            lock.lock()
            let mode = cancellation
            let entry = requests[id]
            if mode == .cancel, entry?.owner == owner { requests.removeValue(forKey: id) }
            lock.unlock()
            if mode == .fail { throw BridgeFailure.unavailable("canned cancellation transport failure") }
            let cancelled = mode == .cancel && entry?.owner == owner
            if cancelled, let entry { try release(entry) }
            return try PluginBridgeJSON.success(.object(["cancelled": .bool(cancelled)]))
        }
        try request.requireArguments(2)
        let permission: PluginPermission = request.member == "tlRequest" ? .network : .messagesSend
        guard callbacks.hasPermission(pluginId, permission) else { throw BridgeFailure.permission("TL fixture requires \(permission.rawValue)") }
        guard case let .object(model) = request.arguments[0], model["schemaVersion"] == .integer(1), model["account"] == .integer(2) else {
            throw BridgeFailure.malformed("TL fixture account/schema mismatch")
        }
        let requestName: String?
        if request.member == "tlRequest" {
            guard let raw = model["request"] else { throw BridgeFailure.malformed("Missing TL request") }
            let encoded = try codec.encodeRequest(ExteralessTLValue(jsonObject: raw.jsonObject))
            guard ["users.getUsers", "contacts.getContactIDs", "messages.receivedQueue"].contains(encoded.methodName) else {
                throw BridgeFailure.unimplemented("Only own small request fixtures are admitted")
            }
            requestName = encoded.methodName
        } else {
            guard model["kind"] == .string("text"), model["peer"] == .object(["type": .string("user"), "id": .integer(101)]),
                  model["path"] == nil, model["request"] == nil, model["random_id"] == nil else {
                throw BridgeFailure.unimplemented("Only native text DTO fixtures are recorded")
            }
            requestName = nil
        }
        let handle = try NativeServiceWire.callbackHandle(request.arguments[1])
        let id = UUID().uuidString
        let entry = Entry(id: id, owner: owner, handle: handle, member: request.member, model: request.arguments[0], requestName: requestName)
        lock.lock()
        guard requests.count < 8, admitted.count < 32 else { lock.unlock(); throw BridgeFailure.unavailable("TL DTO fixture bound exceeded") }
        requests[id] = entry; admitted.append(entry)
        lock.unlock()
        return try PluginBridgeJSON.success(.object(["requestId": .string(id)]))
    }

    func entry(_ id: String) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        guard let entry = requests[id] else { throw BridgeFailure.invalidHandle("Unknown TL fixture request") }
        return entry
    }

    func complete(_ id: String, value: PluginJSONValue, error: PluginJSONValue = .null, checks: Int64) async throws {
        let entry = try take(id)
        let response: PluginJSONValue
        if error == .null, let name = entry.requestName {
            let binary = try codec.encode(ExteralessTLValue(jsonObject: value.jsonObject), as: codec.resultTypeOfMethod(name))
            response = try NativeServiceWire.decode(codec.decodeMethodResponse(binary, methodName: name).jsonString())
        } else { response = value }
        let json = try NativeServiceWire.json(.array([response, error]))
        guard json.utf8.count <= 32_768 else { throw BridgeFailure.malformed("TL canned response exceeds 32 KiB") }
        do {
            let result = try await callbacks.result(entry.owner, entry.handle, "run", json)
            guard result == "null" else { throw BridgeFailure.malformed("TL delegate exported an ignored Python value") }
        } catch { try release(entry); throw error }
        try release(entry)
        let fence = try await callbacks.result(entry.owner, checks, "barrier", "[]")
        guard fence == "null" else { throw BridgeFailure.malformed("TL FIFO fence is not void") }
    }

    private func take(_ id: String) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        guard let entry = requests.removeValue(forKey: id) else { throw BridgeFailure.invalidHandle("TL fixture completed twice") }
        return entry
    }

    private func release(_ entry: Entry) throws {
        lock.lock(); released.append(entry.handle); lock.unlock()
        guard callbacks.release(entry.owner, [entry.handle]) else { throw BridgeFailure.unavailable("TL release was not admitted to the owner FIFO") }
    }

    func releaseInstances(pluginId: String) {
        lock.lock(); requests = requests.filter { $0.value.owner.pluginId != pluginId }; lock.unlock()
    }
}
