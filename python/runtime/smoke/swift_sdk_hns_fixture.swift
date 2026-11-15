import Foundation

final class SDKHNSBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func change(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

/// An intentional, bounded fixture stall inside the real C reverse call. Nothing
/// on main/Host maintenance is awaited here; the test releases this semaphore.
final class SDKHNSWorkerGate: @unchecked Sendable {
    let entered = OneShotResult<Void>()
    private let semaphore = DispatchSemaphore(value: 0)
    func block() throws {
        guard !Thread.isMainThread else { throw BridgeFailure.unavailable("HNS fixture reached main") }
        entered.succeed(())
        guard semaphore.wait(timeout: .now() + 4) == .success else { throw BridgeFailure.unavailable("HNS bounded worker gate expired") }
    }
    func open() { semaphore.signal() }
}

/// Real Foundation NativeServices pool/scheduler/cleanup/callback transport.
/// The UI side is explicitly a stored-token DTO lease recorder, not UIKit.
final class SDKHNSFixture: PluginBridgeExtension, @unchecked Sendable {
    private struct UILease {
        let owner: PluginHost.CallbackOwner
        let handles: [Int64]
    }
    let callbacks: PluginCallbackDispatcher
    let pool = NativeServiceLeasePool<PluginHost.CallbackOwner>(maximumPerOwner: 16, maximumTotal: 32)
    let scheduler = NativeServiceOwnerScheduler<PluginHost.CallbackOwner>(maximumPerOwner: 8, maximumTotal: 16)
    let operations = NativeServiceOperations<PluginHost.CallbackOwner>(maximumSnapshotBytes: 32_768)
    private let interceptions = NativeServiceInterceptions<PluginHost.CallbackOwner>(sites: [])
    let scopes = NativeServiceSnapshots()
    let accountRecordId: Int64 = 9_007_199_254_740_993
    let released = SDKHNSBox<[String]>([])
    let cleanups = SDKHNSBox<[String]>([])
    let unloadingOwner = SDKHNSBox<PluginHost.CallbackOwner?>(nil)
    let retiringDuplicates = SDKHNSBox<[String]>([])
    let residualSweeps = SDKHNSBox(0)
    let workerGate = SDKHNSBox<SDKHNSWorkerGate?>(nil)
    private let retirement: NativeServiceAcknowledgedRelease<PluginHost.CallbackOwner>
    private let uiLock = NSLock()
    private var ui: [String: UILease] = [:]
    let exportedMethods: [String: Set<String>] = ["exteraless.ios.Runtime": NativeServiceCleanupRoute.members.union([
        "postToOwner", "nativeGetUser", "nativeObservePeer", "nativeDownload", "nativeServiceState",
        "notificationSupported", "notificationSubscribe", "uiPresent", "uiDismiss", "sdkHNSBlockWorker"
    ])]

    init(callbacks: PluginCallbackDispatcher) {
        self.callbacks = callbacks
        self.retirement = NativeServiceReleaseTransport.acknowledged(callbacks)
        _ = scopes.begin(recordId: accountRecordId, userId: 101)
    }

    var liveUI: Int { uiLock.lock(); defer { uiLock.unlock() }; return ui.count }

    private func make(owner: PluginHost.CallbackOwner, handle: Int64,
                      required: Set<PluginPermission> = [], scope: NativeServiceSnapshots.Scope? = nil) throws -> NativeServiceCallbackLease<PluginHost.CallbackOwner> {
        let callbacks = self.callbacks, scopes = self.scopes, released = self.released, retirement = self.retirement
        return try pool.make(pluginId: owner.pluginId, owner: owner, handle: handle,
            isCurrent: { candidate in
                callbacks.captureOwner(candidate.pluginId) == candidate
                    && required.allSatisfy { callbacks.hasPermission(candidate.pluginId, $0) }
                    && (scope.map { scopes.isCurrent($0) } ?? true)
            }, callback: NativeServiceCallbackTransport.callback(using: callbacks),
            resultCallback: NativeServiceCallbackTransport.result(using: callbacks),
            release: { _, _ in preconditionFailure("HNS fixture requires acknowledged release") },
            acknowledgedRelease: { owner, handles, accepted in
                released.change { $0 += handles.map { owner.wireToken + ":" + String($0) } }
                retirement(owner, handles, accepted)
            }, ownerWireToken: owner.wireToken)
    }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        guard let request = try NativeServiceRequest(json: requestJSON, members: exportedMethods["exteraless.ios.Runtime"]!) else { return nil }
        guard requestJSON.utf8.count <= 32_768 else { throw BridgeFailure.malformed("HNS fixture payload exceeds 32 KiB") }
        if request.memberKind { return try PluginBridgeJSON.success(.string("method")) }
        // Exact finalized HNS-02 production route, BEFORE active-owner lookup.
        if let value = try NativeServiceCleanupRoute.dispatch(request, pluginId: pluginId, scheduler: scheduler,
            operations: operations, interceptions: interceptions, cancelledOperation: { _ in }) {
            let id = try NativeServiceWire.string(request.arguments[0], name: "id")
            cleanups.change { $0.append(request.member + ":" + id + ":" + (value == .bool(true) ? "true" : "false")) }
            if value == .bool(true), let retiring = unloadingOwner.value,
               retiring.pluginId == pluginId, retiring.wireToken == request.ownerToken {
                // Same immutable request, while actual SDK unload is on the C
                // worker: duplicate production-route cleanup is an allowed no-op.
                let duplicate = try NativeServiceCleanupRoute.dispatch(request, pluginId: pluginId, scheduler: scheduler,
                    operations: operations, interceptions: interceptions, cancelledOperation: { _ in })
                guard duplicate == .bool(false) else { throw BridgeFailure.unavailable("Retiring duplicate native cleanup changed a resource") }
                retiringDuplicates.change { $0.append(retiring.wireToken + ":" + request.member + ":" + id) }
            }
            return try PluginBridgeJSON.success(value)
        }
        if request.member == "uiDismiss" {
            try request.requireArguments(1)
            guard let token = request.ownerToken else { throw BridgeFailure.invalidHandle("UI cleanup needs its bound C owner") }
            let identity = try NativeServiceCleanupIdentity(pluginId: pluginId, ownerToken: token)
            let id = try NativeServiceWire.string(request.arguments[0], name: "id")
            let matches = revokeUI(id: id, identity: identity)
            if matches, let retiring = unloadingOwner.value,
               retiring.pluginId == pluginId, retiring.wireToken == identity.ownerToken {
                guard !revokeUI(id: id, identity: identity) else { throw BridgeFailure.unavailable("Retiring duplicate UI cleanup changed a resource") }
                retiringDuplicates.change { $0.append(retiring.wireToken + ":uiDismiss:" + id) }
            }
            cleanups.change { $0.append("uiDismiss:" + id + ":" + (matches ? "true" : "false")) }
            return try PluginBridgeJSON.success(.null)
        }
        guard let owner = callbacks.captureOwner(pluginId), request.ownerToken == owner.wireToken else {
            throw BridgeFailure.invalidHandle("HNS fixture owner is retired")
        }
        if request.member == "sdkHNSBlockWorker" {
            try request.requireArguments(0)
            guard let gate = workerGate.value else { throw BridgeFailure.unavailable("No bounded HNS gate armed") }
            try gate.block()
            return try PluginBridgeJSON.success(.null)
        }
        if request.member == "postToOwner" {
            try request.requireArguments(3)
            let delay = try NativeServiceWire.integer(request.arguments[1], name: "delay", range: 60_000...60_000)
            let queue = try NativeServiceWire.string(request.arguments[2], name: "queue")
            guard queue == "PLUGINS_QUEUE" else { throw BridgeFailure.unimplemented("HNS fixture uses its owner queue only") }
            let lease = try make(owner: owner, handle: NativeServiceWire.callbackHandle(request.arguments[0]))
            let id = try scheduler.schedule(lease, delayMs: delay, queue: queue)
            return try PluginBridgeJSON.success(.object(["id": .string(id)]))
        }
        if request.member == "uiPresent" {
            try request.requireArguments(3)
            guard callbacks.hasPermission(pluginId, .ui), request.arguments[0] == .string("alert"),
                  case let .object(model) = request.arguments[1], model["title"] == .string("HNS SDK lease fixture"),
                  case let .object(rawCallbacks) = request.arguments[2],
                  Set(rawCallbacks.keys) == Set(["positive", "negative", "neutral", "item", "dismiss", "cancel", "back", "change", "closed"]) else {
                throw BridgeFailure.malformed("HNS fixture only records its own alert DTO")
            }
            let handles = try rawCallbacks.values.map(NativeServiceWire.callbackHandle)
            guard Set(handles).count == 9 else { throw BridgeFailure.invalidHandle("HNS UI callbacks must have unique C identities") }
            let id = UUID().uuidString
            uiLock.lock()
            guard ui.isEmpty else { uiLock.unlock(); throw BridgeFailure.unavailable("HNS fixture allows one UI lease") }
            ui[id] = UILease(owner: owner, handles: handles)
            uiLock.unlock()
            return try PluginBridgeJSON.success(.object(["id": .string(id)]))
        }
        if request.member == "nativeServiceState" {
            try request.requireArguments(1)
            return try PluginBridgeJSON.success(operations.state(id: NativeServiceWire.string(request.arguments[0], name: "id"), owner: owner))
        }
        guard callbacks.hasPermission(pluginId, .messagesRead) else { throw BridgeFailure.permission("HNS fixture requires messages.read") }
        if request.member == "notificationSupported" {
            try request.requireArguments(1)
            guard request.arguments[0] == .integer(2) else { throw BridgeFailure.malformed("HNS account mismatch") }
            return try PluginBridgeJSON.success(.array(NativeServiceNotification.allCases.map {
                .object(["id": .integer(Int64($0.rawValue)), "name": .string($0.name)])
            }))
        }
        try request.requireArguments(2)
        guard case let .object(model) = request.arguments[0], model["account"] == .integer(2),
              let scope = scopes.scope(recordId: accountRecordId) else { throw BridgeFailure.malformed("HNS fixture account unavailable") }
        var required: Set<PluginPermission> = [.messagesRead]
        if request.member == "nativeDownload" { required.formUnion([.files, .network]) }
        if request.member == "notificationSubscribe" {
            let id = try NativeServiceWire.integer(model["event"], name: "event", range: 1...Int64(Int32.max))
            guard let event = NativeServiceNotification(rawValue: Int32(id)) else { throw BridgeFailure.unimplemented("Unknown HNS notification DTO") }
            required.formUnion(event.permissions)
        }
        guard required.allSatisfy({ callbacks.hasPermission(pluginId, $0) }) else { throw BridgeFailure.permission("HNS native download permission missing") }
        let lease = try make(owner: owner, handle: NativeServiceWire.callbackHandle(request.arguments[1]), required: required, scope: scope)
        let ticket = try operations.reserve(lease: lease, accountRecordId: accountRecordId, kind: request.member, timeoutMs: nil,
            expired: { _ in preconditionFailure("HNS fixture has no synthetic expiration") })
        return try PluginBridgeJSON.success(.object(["id": .string(ticket.id)]))
    }

    private func revokeUI(id: String, identity: NativeServiceCleanupIdentity) -> Bool {
        uiLock.lock()
        let entry = ui[id]
        let matches = entry?.owner.pluginId == identity.pluginId && entry?.owner.wireToken == identity.ownerToken
        if matches { ui.removeValue(forKey: id) }
        uiLock.unlock()
        if matches, let entry {
            released.change { $0 += entry.handles.map { entry.owner.wireToken + ":" + String($0) } }
            retirement(entry.owner, entry.handles, {})
        }
        return matches
    }

    /// Return persistent ids so they are closed only AFTER worker guard checks.
    func emitCallbacks(_ ids: [String]) throws -> [String] {
        var persistent: [String] = []
        let tickets = ["nativeGetUser", "nativeDownload", "nativeObservePeer"].flatMap {
            operations.tickets(accountRecordId: accountRecordId, kind: $0)
        }
        for id in ids {
            guard let ticket = tickets.first(where: { $0.id == id }) else { throw BridgeFailure.invalidHandle("Missing HNS callback ticket") }
            let terminal = ticket.kind != "nativeObservePeer"
            if terminal { _ = operations.take(id: id, owner: ticket.lease.owner) }
            else { persistent.append(id) }
            guard ticket.lease.send(argumentsJSON: "[{\"fixture\":true},null]", terminal: terminal) else {
                throw BridgeFailure.unavailable("HNS native callback admission failed")
            }
            if terminal { ticket.lease.close() } // Must preserve the terminal entitlement.
        }
        return persistent
    }

    func releaseInstances(pluginId: String) {
        let leftovers = scheduler.pendingCount + operations.count + liveUI
        residualSweeps.change { $0 += leftovers }
        scheduler.cancelAll(pluginId: pluginId)
        for ticket in operations.takeAll(pluginId: pluginId) { ticket.lease.close() }
        pool.closeAll(pluginId: pluginId)
        uiLock.lock(); ui = ui.filter { $0.value.owner.pluginId != pluginId }; uiLock.unlock()
    }
}
