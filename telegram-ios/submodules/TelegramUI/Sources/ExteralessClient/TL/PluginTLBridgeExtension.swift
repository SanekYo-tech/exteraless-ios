import AccountContext
import Foundation
import PluginHost
import SwiftSignalKit
import TelegramCore

private final class PluginTLContextEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = UUID()
    func invalidate() { self.lock.lock(); self.epoch = UUID(); self.lock.unlock() }
    func captureGuard() -> @Sendable () -> Bool {
        self.lock.lock(); let epoch = self.epoch; self.lock.unlock()
        return { self.lock.lock(); defer { self.lock.unlock() }; return self.epoch == epoch }
    }
}

/// Application-owned native TL/services provider. A synchronous dispatch only
/// validates/adopts a lease; AccountContext is resolved on main, network/Postbox
/// work is asynchronous, and reverse calls always use the captured owner worker.
public final class PluginTLBridgeExtension: PluginBridgeExtension, @unchecked Sendable {
    public let exportedMethods: [String: Set<String>] = [
        "exteraless.ios.Runtime": ["tlRequest", "tlCancel", "getPeer", "sendMedia", "editMedia"]
    ]
    public typealias CaptureOwner = @Sendable (String) -> PluginHost.CallbackOwner?
    public typealias Callback = @Sendable (PluginHost.CallbackOwner, Int64, String, String, @escaping @Sendable () -> Bool) -> Bool
    public typealias Release = @Sendable (PluginHost.CallbackOwner, [Int64]) -> Bool
    public typealias HasPermission = @Sendable (String, PluginPermission) -> Bool
    public typealias AccountLookup = @Sendable (Int32) throws -> Int64
    public typealias AccountResolver = @MainActor @Sendable (Int64) -> AccountContext?

    typealias Registry = ExteralessTLRequestRegistry<PluginHost.CallbackOwner>
    typealias Ticket = Registry.Ticket

    let registry = Registry()
    private let contextEpoch = PluginTLContextEpoch()
    private let scheduleStart: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let mediaPreparation = PluginTLMediaPreparation()
    private let storage: PluginServiceStorage
    private let captureOwner: CaptureOwner
    private let callback: Callback
    private let release: Release
    private let hasPermission: HasPermission
    private let permissionAdmission: PluginPermissionAdmission
    private let accountLookup: AccountLookup
    private let resolveAccount: AccountResolver
    private let diagnostic: @Sendable (String) -> Void
    private let completions = DispatchQueue(label: "Exteraless.TLCompletions", qos: .userInitiated)
    private struct Completion {
        let ticket: Ticket
        var arguments: String
        var compacted = false
        var callbackAdmitted = false
    }
    // Accessed only on completions. One retry timer for every owner combined;
    // registry admission slots stay occupied until delivery/cancellation.
    private var queuedCompletions: [PluginHost.CallbackOwner: [Completion]] = [:]
    private var completionRetryTimer: DispatchSourceTimer?
    @MainActor private weak var context: AccountContext?

    public convenience init(storage: PluginServiceStorage, hasPermission: @escaping HasPermission,
                captureOwner: @escaping CaptureOwner, callback: @escaping Callback, release: @escaping Release,
                accountLookup: @escaping AccountLookup, resolveAccount: @escaping AccountResolver,
                diagnostic: @escaping @Sendable (String) -> Void = { NSLog("[Exteraless TL] %@", $0) },
                permissionAdmission: PluginPermissionAdmission? = nil) {
        self.init(storage: storage, hasPermission: hasPermission, captureOwner: captureOwner, callback: callback,
            release: release, accountLookup: accountLookup, resolveAccount: resolveAccount, diagnostic: diagnostic,
            scheduleStart: { work in DispatchQueue.main.async { work() } }, permissionAdmission: permissionAdmission)
    }

    init(storage: PluginServiceStorage, hasPermission: @escaping HasPermission,
         captureOwner: @escaping CaptureOwner, callback: @escaping Callback, release: @escaping Release,
         accountLookup: @escaping AccountLookup, resolveAccount: @escaping AccountResolver,
         diagnostic: @escaping @Sendable (String) -> Void,
         scheduleStart: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void,
         permissionAdmission: PluginPermissionAdmission? = nil) {
        self.scheduleStart = scheduleStart
        self.storage = storage
        self.hasPermission = hasPermission
        self.permissionAdmission = permissionAdmission ?? { id, required in
            { required.allSatisfy { hasPermission(id, $0) } }
        }
        self.captureOwner = captureOwner
        self.callback = callback
        self.release = release
        self.accountLookup = accountLookup
        self.resolveAccount = resolveAccount
        self.diagnostic = diagnostic
    }

    deinit {
        self.completionRetryTimer?.cancel()
        for ticket in self.registry.takeAll() { _ = self.release(ticket.owner, [ticket.callbackHandle]) }
    }

    @MainActor public func update(context: AccountContext) {
        if self.context !== context { self.contextEpoch.invalidate() }
        self.context = context
    }

    @MainActor public func clearContext() {
        self.contextEpoch.invalidate()
        self.context = nil
        // Retire native work first; live SDK owners receive a terminal account error.
        for ticket in self.registry.runningTickets { self.finish(ticket, error: .local("ACCOUNT_UNAVAILABLE")) }
    }

    public func releaseInstances(pluginId: String) {
        for ticket in self.registry.takeAll(pluginId: pluginId) {
            _ = self.release(ticket.owner, [ticket.callbackHandle])
        }
    }

    public func permissionsChanged(pluginId: String) {
        for ticket in self.registry.runningTickets where ticket.pluginId == pluginId && !ticket.permitsExecution {
            self.finish(ticket, error: .local("PERMISSION_REVOKED"))
        }
    }

    public func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        guard requestJSON.utf8.count <= ExteralessTLCodec.maximumJSONBytes else {
            throw BridgeFailure.malformed("TL bridge request exceeds 16 MiB")
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any] else {
            throw BridgeFailure.malformed("TL bridge expected a JSON object")
        }
        guard root["fqcn"] as? String == "exteraless.ios.Runtime", let member = root["member"] as? String,
              ["tlRequest", "tlCancel", "getPeer", "sendMedia", "editMedia"].contains(member) else { return nil }
        do {
            _ = try PluginTLModel.object(root, name: "TL bridge envelope", keys: ["op", "fqcn", "member", "args", "kwargs", "instance", "value", "pluginId", "ownerToken"])
            guard let operation = root["op"] as? String else { throw BridgeFailure.malformed("Missing TL bridge operation") }
            guard root["instance"] == nil || root["instance"] is NSNull else {
                throw BridgeFailure.malformed("TL runtime operations are static")
            }
            if let kwargs = root["kwargs"] {
                guard let kwargs = kwargs as? [String: Any], kwargs.isEmpty else { throw BridgeFailure.malformed("TL runtime keyword arguments are unsupported") }
            }
            guard let arguments = (root["args"] ?? [Any]()) as? [Any] else { throw BridgeFailure.malformed("TL args must be an array") }
            if operation == "member_kind" {
                guard arguments.isEmpty else { throw BridgeFailure.malformed("member_kind takes no arguments") }
                return try Self.success(.string("method"))
            }
            guard operation == "call", root["value"] == nil || root["value"] is NSNull else {
                throw BridgeFailure.memberError("\(member) is a callable, read-only native operation")
            }
            guard let ownerToken = root["ownerToken"] as? String, !ownerToken.isEmpty else {
                throw BridgeFailure.invalidHandle("TL request has no originating interpreter token")
            }
            if member == "tlCancel" {
                guard arguments.count == 1 else { throw BridgeFailure.malformed("tlCancel requires one request id") }
                let id = try PluginTLModel.string(arguments[0], name: "tlCancel.requestId", maximum: 128)
                guard let owner = self.captureOwner(pluginId), owner.wireToken == ownerToken,
                       let ticket = self.registry.cancelRetainingLease(id: id, pluginId: pluginId, owner: owner) else {
                    return try Self.success(.object(["cancelled": .bool(false)]))
                }
                self.completions.async { [weak self] in
                    guard let self else { return }
                    self.queuedCompletions[owner, default: []].append(Completion(ticket: ticket, arguments: "[]", callbackAdmitted: true))
                    self.pumpCompletions(owner)
                }
                return try Self.success(.object(["cancelled": .bool(true)]))
            }
            guard arguments.count == 2 else { throw BridgeFailure.malformed("\(member) requires exactly model and callback") }
            let callbackHandle = try PluginTLModel.callbackHandle(arguments[1])
            let ticket: Ticket
            switch member {
            case "tlRequest":
                try self.require(pluginId, .network, member: member)
                let model = try PluginTLRequestModel(arguments[0])
                ticket = try self.admit(pluginId, ownerToken: ownerToken, callbackHandle: callbackHandle, common: model.common, permission: .network)
                self.scheduleStart { [weak self] in self?.startRequest(ticket, model: model) }
            case "getPeer":
                try self.require(pluginId, .messagesRead, member: member)
                let model = try PluginTLPeerModel(arguments[0])
                ticket = try self.admit(pluginId, ownerToken: ownerToken, callbackHandle: callbackHandle, common: model.common, permission: .messagesRead)
                self.scheduleStart { [weak self] in self?.startPeer(ticket, model: model) }
            case "sendMedia":
                try self.require(pluginId, .messagesSend, member: member)
                let model = try PluginTLMediaModel(arguments[0])
                if model.kind == .text {
                    ticket = try self.admit(pluginId, ownerToken: ownerToken, callbackHandle: callbackHandle, common: model.common, permission: .messagesSend)
                    self.scheduleStart { [weak self] in self?.startText(ticket, model: model) }
                } else if model.kind == .album {
                    let sources = try model.items.map { try self.mediaResource($0.path, pluginId: pluginId) }
                    let cache = try self.storage.cacheDirectory(pluginId: pluginId)
                    ticket = try self.admit(pluginId, ownerToken: ownerToken, callbackHandle: callbackHandle, common: model.common, permission: .messagesSend, media: true, resources: sources)
                    self.scheduleStart { [weak self] in self?.startAlbum(ticket, model: model, sources: sources, cache: cache) }
                } else {
                    let source = try self.mediaResource(model.path, pluginId: pluginId)
                    let cache = try self.storage.cacheDirectory(pluginId: pluginId)
                    ticket = try self.admit(pluginId, ownerToken: ownerToken, callbackHandle: callbackHandle, common: model.common, permission: .messagesSend, media: true, resources: [source])
                    self.scheduleStart { [weak self] in self?.startMedia(ticket, model: model, source: source, cache: cache) }
                }
            case "editMedia":
                try self.require(pluginId, .messagesSend, member: member)
                let model = try PluginTLEditMediaModel(arguments[0])
                let source = model.content.kind == .text ? nil : try self.mediaResource(model.content.path, pluginId: pluginId)
                let cache = try self.storage.cacheDirectory(pluginId: pluginId)
                ticket = try self.admit(pluginId, ownerToken: ownerToken, callbackHandle: callbackHandle, common: model.content.common,
                    permission: .messagesSend, media: source != nil || model.spoiler != nil, resources: source.map { [$0] } ?? [])
                self.scheduleStart { [weak self] in self?.startEditMedia(ticket, model: model, source: source, cache: cache) }
            default:
                throw BridgeFailure.unimplemented("Unsupported TL runtime method: \(member)")
            }
            return try Self.success(.object(["requestId": .string(ticket.id)]))
        } catch let error as ExteralessTLError {
            return try PluginBridgeJSON.failure(kind: error.kind.rawValue, message: error.message)
        } catch let error as BridgeFailure {
            return try PluginBridgeJSON.failure(kind: error.kind, message: error.description)
        } catch let error as PluginHostError {
            return try PluginBridgeJSON.failure(kind: "NativeOrigin", message: String(describing: error))
        } catch {
            return try PluginBridgeJSON.failure(kind: "MalformedRequest", message: "TL service model could not be accepted")
        }
    }

    private static func success(_ value: ExteralessTLValue) throws -> String {
        return try ExteralessTLValue.object(["ok": .bool(true), "value": value]).jsonString()
    }

    private func require(_ pluginId: String, _ permission: PluginPermission, member: String) throws {
        guard self.hasPermission(pluginId, permission) else { throw BridgeFailure.permission("\(member) requires \(permission.rawValue)") }
    }

    private func admit(_ pluginId: String, ownerToken: String, callbackHandle: Int64, common: PluginTLCommonModel, permission: PluginPermission, media: Bool = false,
                       resources: [PluginResourcePath] = []) throws -> Ticket {
        // Capture on the calling C owner-worker, before ANY main/Task hop. A
        // later capture would see nil and accidentally grant permanent execution.
        let parentExecution = PluginNativeExecutionContext.captureGuard()
        let accountExecution = self.contextEpoch.captureGuard()
        guard let owner = self.captureOwner(pluginId), owner.pluginId == pluginId, owner.wireToken == ownerToken else {
            throw BridgeFailure.invalidHandle("TL request has no current interpreter owner")
        }
        let recordId = try self.accountLookup(common.account)
        let origin = try PluginTLNativeOrigin.capture(owner: owner)
        let captureOwner = self.captureOwner
        var required: Set<PluginPermission> = [permission]
        if permission == .messagesSend { required.insert(.ui) }
        if resources.contains(where: \.requiresFiles) { required.insert(.files) }
        // Classification is metadata-only and never consults current grants.
        // This single full predicate owns preparation, cancellation and delivery.
        let permissionCurrent = self.permissionAdmission(pluginId, required)
        let execution: @Sendable () -> Bool = {
            parentExecution() && accountExecution() && permissionCurrent()
        }
        guard execution(), captureOwner(pluginId) == owner else { throw PluginHostError.superseded("TL native execution revoked before admission") }
        let ticket = try self.registry.reserve(pluginId: pluginId, owner: owner, callbackHandle: callbackHandle,
            accountRecordId: recordId, isMedia: media, timeoutMs: common.timeoutMs,
            originPluginIds: origin?.pluginIds ?? [], originRootId: origin?.rootId, executionIsCurrent: execution, expired: { [weak self] ticket in
                self?.finish(ticket, error: .local("TIMEOUT"))
            })
        do {
            guard ticket.permitsExecution, captureOwner(pluginId) == owner else { throw PluginHostError.superseded("TL native execution revoked during admission") }
            if let origin {
                guard try PluginTLNativeOrigin.capture(owner: owner, callbackHandle: callbackHandle) == origin else {
                    throw PluginHostError.superseded("TL origin scope expired during native admission")
                }
            }
            return ticket
        } catch {
            _ = self.registry.take(ticket)
            throw error
        }
    }

    private func origin(_ ticket: Ticket) -> ExteralessTLRequestOrigin? {
        guard let root = ticket.originRootId else { return nil }
        return try? ExteralessTLRequestOrigin(rootId: root, pluginIds: ticket.originPluginIds)
    }

    /// This is the same predicate passed to Core's post-authorization/commit
    /// guards. Ownership membership never calls the external execution predicate
    /// while the registry is locked, and revocation does not release the ticket.
    func nativeCancellation(_ ticket: Ticket) -> @Sendable () -> Bool {
        let registry = self.registry
        let captureOwner = self.captureOwner
        return { !registry.contains(ticket) || !ticket.permitsExecution || captureOwner(ticket.pluginId) != ticket.owner }
    }

    @MainActor private func account(_ ticket: Ticket, permission: PluginPermission) -> AccountContext? {
        guard self.registry.contains(ticket) else { return nil }
        guard ticket.permitsExecution else {
            self.finish(ticket, error: .local("EXECUTION_REVOKED"))
            return nil
        }
        guard self.captureOwner(ticket.pluginId) == ticket.owner else {
            if let ticket = self.registry.take(ticket) { _ = self.release(ticket.owner, [ticket.callbackHandle]) }
            return nil
        }
        guard self.hasPermission(ticket.pluginId, permission) else {
            self.finish(ticket, error: .local("PERMISSION_REVOKED"))
            return nil
        }
        guard self.context != nil, let context = self.resolveAccount(ticket.accountRecordId), context.account.id.int64 == ticket.accountRecordId else {
            self.finish(ticket, error: .local("ACCOUNT_UNAVAILABLE"))
            return nil
        }
        return context
    }

    @MainActor private func startRequest(_ ticket: Ticket, model: PluginTLRequestModel) {
        guard let context = self.account(ticket, permission: .network) else { return }
        self.start(exteralessTLRequest(account: context.account, request: model.request,
            automaticFloodWait: model.automaticFloodWait, applyUpdates: model.applyUpdates, origin: self.origin(ticket),
            isCancelled: self.nativeCancellation(ticket)), ticket: ticket)
    }

    @MainActor private func startPeer(_ ticket: Ticket, model: PluginTLPeerModel) {
        guard let context = self.account(ticket, permission: .messagesRead) else { return }
        self.start(exteralessTLGetPeer(account: context.account, reference: model.peer, isCancelled: self.nativeCancellation(ticket)), ticket: ticket)
    }

    @MainActor private func startText(_ ticket: Ticket, model: PluginTLMediaModel) {
        guard let context = self.account(ticket, permission: .messagesSend) else { return }
        self.start(exteralessTLSendText(account: context.account, reference: model.peer, text: model.caption,
            entities: model.entities, silent: model.silent, replyToId: model.replyToId, threadId: model.threadId,
            disableLinkPreviews: model.disableLinkPreviews, scheduleTime: model.scheduleTime,
            replyToNamespace: model.replyToNamespace, ttlSeconds: model.ttlSeconds,
            origin: self.origin(ticket),
            isCancelled: self.nativeCancellation(ticket)), ticket: ticket)
    }

    @MainActor private func startMedia(_ ticket: Ticket, model: PluginTLMediaModel, source: PluginResourcePath, cache: URL) {
        guard let context = self.account(ticket, permission: .messagesSend) else { return }
        let registry = self.registry
        let isCancelled = self.nativeCancellation(ticket)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.mediaPreparation.prepare(model: model, source: source, cacheDirectory: cache,
                    isActive: { !isCancelled() }, bindCancellation: { cancel in registry.bindCancellation(ticket, cancel) })
                guard !Task.isCancelled, let current = self.account(ticket, permission: .messagesSend) else { return }
                guard current === context else {
                    self.finish(ticket, error: .local("ACCOUNT_UNAVAILABLE"))
                    return
                }
                // Prepared bytes and this ticket's original permission predicate
                // remain authoritative; never select a fresh files grant here.
                self.start(exteralessTLSendMedia(account: current.account, reference: model.peer, media: prepared,
                    caption: model.caption, entities: model.entities, silent: model.silent, replyToId: model.replyToId,
                    threadId: model.threadId, scheduleTime: model.scheduleTime,
                    replyToNamespace: model.replyToNamespace, spoiler: model.spoiler, ttlSeconds: model.ttlSeconds,
                    origin: self.origin(ticket),
                    isCancelled: isCancelled), ticket: ticket)
            } catch is CancellationError {
                // Explicit cancellation/timeout/unload already owns the terminal lease.
                if registry.contains(ticket) { self.finish(ticket, error: .local("MEDIA_PREPARATION_CANCELLED")) }
            } catch let error as ExteralessTLError {
                self.finish(ticket, error: .local("MEDIA_\(error.kind.rawValue): \(error.message)"))
            } catch let error as BridgeFailure {
                self.finish(ticket, error: .local("MEDIA_\(error.kind): \(error.description)"))
            } catch {
                self.finish(ticket, error: .local("MEDIA_PREPARATION_FAILED"))
            }
        }
        registry.bindCancellation(ticket) { task.cancel() }
    }

    @MainActor private func startAlbum(_ ticket: Ticket, model: PluginTLMediaModel, sources: [PluginResourcePath], cache: URL) {
        guard let context = self.account(ticket, permission: .messagesSend) else { return }
        let registry = self.registry
        let isCancelled = self.nativeCancellation(ticket)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var items: [ExteralessTLPreparedMessage] = []
                var size = 0
                guard sources.count == model.items.count else { throw BridgeFailure.malformed("Album resource admission mismatch") }
                for (item, source) in zip(model.items, sources) {
                    guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
                    let media = try await self.mediaPreparation.prepare(model: item, source: source, cacheDirectory: cache,
                        isActive: { !isCancelled() }, bindCancellation: { registry.bindCancellation(ticket, $0) })
                    size += media.data.count
                    guard size <= 32 * 1024 * 1024 else { throw ExteralessTLError(.limit, "Album data exceeds 32 MiB") }
                    items.append(ExteralessTLPreparedMessage(media: media, text: item.caption, entities: item.entities,
                        spoiler: item.spoiler, ttlSeconds: item.ttlSeconds))
                }
                guard let current = self.account(ticket, permission: .messagesSend), current === context else {
                    self.finish(ticket, error: .local("ACCOUNT_UNAVAILABLE")); return
                }
                self.start(exteralessTLSendAlbum(account: current.account, reference: model.peer, items: items, silent: model.silent,
                    replyToId: model.replyToId, replyToNamespace: model.replyToNamespace, threadId: model.threadId, scheduleTime: model.scheduleTime,
                    origin: self.origin(ticket),
                    isCancelled: isCancelled), ticket: ticket)
            } catch let error as ExteralessTLError {
                self.finish(ticket, error: .local("ALBUM_\(error.kind.rawValue): \(error.message)"))
            } catch {
                self.finish(ticket, error: .local("ALBUM_PREPARATION_FAILED"))
            }
        }
        registry.bindCancellation(ticket) { task.cancel() }
    }

    @MainActor private func startEditMedia(_ ticket: Ticket, model: PluginTLEditMediaModel, source: PluginResourcePath?, cache: URL) {
        guard let context = self.account(ticket, permission: .messagesSend) else { return }
        let registry = self.registry
        let isCancelled = self.nativeCancellation(ticket)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let media: ExteralessTLPreparedMedia?
                if let source {
                    media = try await self.mediaPreparation.prepare(model: model.content, source: source, cacheDirectory: cache,
                        isActive: { !isCancelled() }, bindCancellation: { registry.bindCancellation(ticket, $0) })
                } else { media = nil }
                guard let current = self.account(ticket, permission: .messagesSend), current === context else {
                    self.finish(ticket, error: .local("ACCOUNT_UNAVAILABLE")); return
                }
                self.start(exteralessTLEditMedia(account: current.account, reference: model.content.peer, messageId: model.messageId,
                    namespace: model.namespace, media: media, caption: model.caption, entities: model.entities, spoiler: model.spoiler,
                    disableLinkPreviews: model.content.disableLinkPreviews, scheduleTime: model.content.scheduleTime,
                    origin: self.origin(ticket),
                    isCancelled: isCancelled), ticket: ticket)
            } catch let error as ExteralessTLError {
                self.finish(ticket, error: .local("EDIT_\(error.kind.rawValue): \(error.message)"))
            } catch {
                self.finish(ticket, error: .local("EDIT_PREPARATION_FAILED"))
            }
        }
        registry.bindCancellation(ticket) { task.cancel() }
    }

    private func start(_ signal: Signal<ExteralessTLValue, ExteralessTLServiceError>, ticket: Ticket) {
        guard self.registry.contains(ticket) else { return }
        guard ticket.permitsExecution else { self.finish(ticket, error: .local("EXECUTION_REVOKED")); return }
        let disposable = signal.start(next: { [weak self] response in
            self?.finish(ticket, response: response)
        }, error: { [weak self] error in
            self?.finish(ticket, error: error)
        }, completed: { [weak self] in
            // A native empty Signal is an error, not a stuck accepted request.
            self?.finish(ticket, error: .local("EMPTY_NATIVE_RESPONSE"))
        })
        self.registry.bindCancellation(ticket) { disposable.dispose() }
    }

    func finish(_ ticket: Ticket, response: ExteralessTLValue? = nil, error: ExteralessTLServiceError? = nil) {
        guard let ticket = self.registry.complete(ticket) else { return }
        self.deliver(ticket, response: response, error: error)
    }

    private func deliver(_ ticket: Ticket, response: ExteralessTLValue?, error: ExteralessTLServiceError?) {
        self.completions.async { [weak self] in
            guard let self, self.registry.completionPending(ticket) else { return }
            if !ticket.permitsExecution {
                self.queuedCompletions[ticket.owner, default: []].append(Completion(ticket: ticket, arguments: "[]", callbackAdmitted: true))
                self.pumpCompletions(ticket.owner)
                return
            }
            let arguments: String
            do {
                arguments = try ExteralessTLValue.array([response ?? .null, error?.value ?? .null]).jsonString()
            } catch {
                arguments = "[null,{\"_\":\"error\",\"code\":-1,\"text\":\"EXTERALESS_RESPONSE_TOO_LARGE\"}]"
            }
            self.queuedCompletions[ticket.owner, default: []].append(Completion(ticket: ticket, arguments: arguments))
            self.pumpCompletions(ticket.owner)
        }
    }

    /// Serialized, nonblocking callback admission. On pressure discard the large
    /// body in favor of a named terminal error and retry within the original request
    /// deadline (plus a bounded one-second control-message grace period).
    private func pumpCompletions(_ owner: PluginHost.CallbackOwner) {
        while let first = self.queuedCompletions[owner]?.first {
            let ticket = first.ticket
            if !self.registry.completionPending(ticket) || self.captureOwner(ticket.pluginId) != owner {
                _ = self.registry.releaseCompletion(ticket) // retired owner already destroys its C handles
                self.removeFirstCompletion(owner)
                continue
            }
            if first.callbackAdmitted {
                if self.releaseCompleted(ticket) { self.removeFirstCompletion(owner); continue }
                self.ensureCompletionRetryTimer()
                return
            }
            if !ticket.permitsExecution {
                self.queuedCompletions[owner]?[0].arguments = "[]"
                self.queuedCompletions[owner]?[0].callbackAdmitted = true
                continue
            }
            // Completion/release can retire the registry entry before this queued
            // callback enters Python. Its guard must not depend on membership or
            // fresh lifecycle admission; Host rechecks the captured callback owner
            // inside its already-reserved activity on the actual worker.
            if self.callback(owner, ticket.callbackHandle, "run", first.arguments, { ticket.permitsExecution }) {
                self.queuedCompletions[owner]?[0].callbackAdmitted = true
                continue
            }
            if !first.compacted {
                let fallback = "[null,{\"_\":\"error\",\"code\":-1,\"text\":\"EXTERALESS_CALLBACK_BACKPRESSURE\"}]"
                self.queuedCompletions[owner]?[0].arguments = fallback
                self.queuedCompletions[owner]?[0].compacted = true
                if self.callback(owner, ticket.callbackHandle, "run", fallback, { ticket.permitsExecution }) {
                    self.queuedCompletions[owner]?[0].callbackAdmitted = true
                    continue
                }
            }
            if DispatchTime.now().uptimeNanoseconds >= ticket.deadlineNanoseconds + 1_000_000_000 {
                self.diagnostic("EXTERALESS_CALLBACK_DELIVERY_TIMEOUT: owner dispatcher refused a terminal error")
                self.queuedCompletions[owner]?[0].callbackAdmitted = true
                continue
            }
            // Later completions for this owner remain behind this one. Different
            // owners can drain independently, through the same bounded timer.
            self.ensureCompletionRetryTimer()
            return
        }
        if self.queuedCompletions.isEmpty {
            self.completionRetryTimer?.cancel()
            self.completionRetryTimer = nil
        }
    }

    private func removeFirstCompletion(_ owner: PluginHost.CallbackOwner) {
        self.queuedCompletions[owner]?.removeFirst()
        if self.queuedCompletions[owner]?.isEmpty == true { self.queuedCompletions.removeValue(forKey: owner) }
    }

    private func ensureCompletionRetryTimer() {
        guard self.completionRetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: self.completions)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for owner in Array(self.queuedCompletions.keys) { self.pumpCompletions(owner) }
        }
        self.completionRetryTimer = timer
        timer.resume()
    }

    private func releaseCompleted(_ ticket: Ticket) -> Bool {
        guard self.registry.completionPending(ticket) else { return true }
        // Release shares the dispatcher's FIFO, after a callback that was accepted.
        guard self.release(ticket.owner, [ticket.callbackHandle]) else { return false }
        _ = self.registry.releaseCompletion(ticket)
        return true
    }

    private func mediaResource(_ path: String, pluginId: String) throws -> PluginResourcePath {
        try PluginResourcePath(path: path, allowedRoots: [self.storage.filesDirectory(pluginId: pluginId),
                                                       self.storage.cacheDirectory(pluginId: pluginId)])
    }
}
