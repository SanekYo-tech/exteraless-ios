import AccountContext
import Foundation
import PluginHost
import SwiftSignalKit
import TelegramCore

/// Native scheduling, logs, file/link barriers and portable account services.
/// Synchronous C dispatch validates and admits; every AccountContext/Signal start
/// is deferred to main, every Python callback to the captured interpreter owner.
public final class PluginNativeServicesBridgeExtension: PluginBridgeExtension, @unchecked Sendable {
    public typealias CaptureOwner = @Sendable (String) -> PluginHost.CallbackOwner?
    public typealias Callback = NativeServiceCallback<PluginHost.CallbackOwner>
    public typealias Release = @Sendable (PluginHost.CallbackOwner, [Int64]) -> Void
    public typealias HasPermission = @Sendable (String, PluginPermission) -> Bool
    public typealias Snapshot = @Sendable () -> PluginPlatformSnapshot
    public typealias AccountResolver = @MainActor @Sendable (Int64) -> AccountContext?
    public let exportedMethods: [String: Set<String>]
    public typealias Owner = PluginHost.CallbackOwner
    typealias Lease = NativeServiceCallbackLease<Owner>
    typealias Ticket = NativeServiceOperations<Owner>.Ticket

    private static let members: Set<String> = [
        "postToOwner", "cancelOwnerTask", "logEvent", "fileRegister", "fileRemove", "intentRegister", "intentRemove",
        "nativeGetUser", "nativeGetChat", "nativeObservePeer", "nativePeerInfo", "nativeGetContacts",
        "nativeMessageMedia", "nativeResourceStatus", "nativeObserveResource", "nativeDownload", "nativeNotificationSettings",
        "nativeConnectionState", "nativeServiceState", "nativeServiceCancel",
        "nativeCachedUser", "nativeCachedChat", "nativeCachedClientUser", "nativeCachedClientUserId",
        "nativeCachedUserFull", "nativeCachedChatFull", "nativeCachedContacts", "nativeCachedConnection",
        "nativeCachedPlayback", "nativeCachedDownloads",
        "notificationSubscribe", "notificationUnsubscribe", "notificationSupported"
    ]
    private let captureOwner: CaptureOwner
    private let callback: Callback
    private let resultCallback: NativeServiceResultCallback<Owner>
    private let release: Release
    private let acknowledgedRelease: NativeServiceAcknowledgedRelease<Owner>?
    private let hasPermission: HasPermission
    private let permissionAdmission: PluginPermissionAdmission
    private let snapshot: Snapshot
    private let resolveAccount: AccountResolver
    private let logs: PluginServiceLogBuffer
    private let leases = NativeServiceLeasePool<Owner>()
    private let scheduler = NativeServiceOwnerScheduler<Owner>()
    private let operations = NativeServiceOperations<Owner>()
    private let controllerSnapshots = NativeServiceControllerSnapshots()
    private let eventDelivery = NativeServiceEventDelivery<Owner>()
    private let publisherSites: Set<NativeServicePublisherSite>
    let interceptions: NativeServiceInterceptions<Owner>
    private let stateLock = NSLock()
    private var connectionStates: [Int64: PluginJSONValue] = [:]
    private var notificationAccounts: [Int64: Set<NativeServiceNotification>] = [:]

    // Main-only native objects. Dispatch never reads these or waits for main.
    private var sharedContext: SharedAccountContext?
    private var accountsDisposable: Disposable?
    private var observations: [Int64: NativeServiceAccountObservation] = [:]

    public init(logs: PluginServiceLogBuffer, hasPermission: @escaping HasPermission,
                captureOwner: @escaping CaptureOwner, callback: @escaping Callback,
                resultCallback: @escaping NativeServiceResultCallback<Owner>, release: @escaping Release,
                platformSnapshot: @escaping Snapshot, resolveAccount: @escaping AccountResolver,
                interceptionSites: Set<NativeServiceInterceptionSite> = [],
                publisherSites: Set<NativeServicePublisherSite> = [],
                acknowledgedRelease: NativeServiceAcknowledgedRelease<Owner>? = nil,
                permissionAdmission: PluginPermissionAdmission? = nil) {
        var exported = Self.members
        if !interceptionSites.contains(.chatDocument) { exported.subtract(["fileRegister", "fileRemove"]) }
        if interceptionSites.isDisjoint(with: [.externalURL, .applicationURL]) { exported.subtract(["intentRegister", "intentRemove"]) }
        self.exportedMethods = ["exteraless.ios.Runtime": exported]
        self.logs = logs
        self.hasPermission = hasPermission
        self.permissionAdmission = permissionAdmission ?? { id, required in
            { required.allSatisfy { hasPermission(id, $0) } }
        }
        self.captureOwner = captureOwner
        self.callback = callback
        self.resultCallback = resultCallback
        self.release = release
        self.acknowledgedRelease = acknowledgedRelease
        self.snapshot = platformSnapshot
        self.resolveAccount = resolveAccount
        self.interceptions = NativeServiceInterceptions(sites: interceptionSites)
        self.publisherSites = publisherSites
    }

    public convenience init(services: TelegramPluginServices, callbacks: PluginCallbackDispatcher,
                            interceptionSites: Set<NativeServiceInterceptionSite> = [],
                            publisherSites: Set<NativeServicePublisherSite> = []) {
        let retirement = NativeServiceReleaseTransport.acknowledged(callbacks)
        self.init(logs: services.serviceLogs,
            hasPermission: { callbacks.hasPermission($0, $1) }, captureOwner: { callbacks.captureOwner($0) },
            callback: NativeServiceCallbackTransport.callback(using: callbacks),
            resultCallback: NativeServiceCallbackTransport.result(using: callbacks),
            release: { owner, handles in retirement(owner, handles, {}) }, platformSnapshot: { services.platformSnapshot },
            resolveAccount: { services.context(recordId: $0) }, interceptionSites: interceptionSites,
            publisherSites: publisherSites, acknowledgedRelease: retirement,
            permissionAdmission: { callbacks.permissionPredicate($0, requiring: $1) })
    }

    @MainActor public func update(context: AccountContext) {
        if self.sharedContext === context.sharedContext {
            observe(context)
            return
        }
        clearContext()
        self.sharedContext = context.sharedContext
        observe(context)
        self.accountsDisposable = (context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self] _, accounts, _ in
            guard let self else { return }
            let active = Set(accounts.map { $0.0.int64 })
            for id in Array(self.observations.keys) where !active.contains(id) { self.removeAccount(id) }
            for (_, context, _) in accounts { self.observe(context) }
        })
    }

    @MainActor public func clearContext() {
        accountsDisposable?.dispose()
        accountsDisposable = nil
        sharedContext = nil
        for id in Array(observations.keys) { removeAccount(id) }
        for ticket in operations.takeAll() { ticket.lease.close() }
        eventDelivery.remove()
        controllerSnapshots.clear()
        interceptions.cancelOpenings()
        NativeServiceOpenHooks.shared.cancelPreparations(provider: self)
    }

    public func releaseInstances(pluginId: String) {
        scheduler.cancelAll(pluginId: pluginId)
        interceptions.releaseInstances(pluginId: pluginId)
        for ticket in operations.takeAll(pluginId: pluginId) { ticket.lease.close() }
        eventDelivery.remove(pluginId: pluginId)
        leases.closeAll(pluginId: pluginId)
    }

    public func permissionsChanged(pluginId: String) {
        interceptions.retirePermissions(pluginId: pluginId)
        for ticket in operations.retirePermissions(pluginId: pluginId) {
            eventDelivery.remove(subscriptionId: ticket.id)
            ticket.lease.close()
        }
        leases.retirePermissions(pluginId: pluginId)
    }

    public func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        do {
            guard let request = try NativeServiceRequest(json: requestJSON, members: Self.members) else { return nil }
            if request.memberKind { return try PluginBridgeJSON.success(.string("method")) }
            if let value = try NativeServiceCleanupRoute.dispatch(request, pluginId: pluginId,
                scheduler: scheduler, operations: operations, interceptions: interceptions,
                cancelledOperation: { self.eventDelivery.remove(subscriptionId: $0) }) {
                return try PluginBridgeJSON.success(value)
            }
            let args = request.arguments
            if request.member.hasPrefix("nativeCached") {
                return try PluginBridgeJSON.success(cached(request, pluginId: pluginId))
            }
            switch request.member {
            case "logEvent":
                try request.requireArguments(1)
                // C supplies pluginId. Never take identity from the event/model.
                logs.append(pluginId: pluginId, event: try NativeServiceLogEvent(args[0]))
                return try PluginBridgeJSON.success(.null)
            case "postToOwner":
                try request.requireArguments(3)
                let handle = try NativeServiceWire.callbackHandle(args[0])
                let delay = try NativeServiceWire.integer(args[1], name: "delayMs")
                let queue = try NativeServiceWire.string(args[2], name: "queue", maximum: 64)
                try NativeServiceOwnerScheduler<Owner>.validate(delayMs: delay, queue: queue)
                let lease = try makeLease(request, pluginId: pluginId, handle: handle, permissions: [])
                do {
                    let id = try scheduler.schedule(lease, delayMs: delay, queue: queue)
                    return try PluginBridgeJSON.success(.object(["id": .string(id)]))
                } catch { lease.reject(); throw error }
            case "fileRegister", "intentRegister":
                try request.requireArguments(2)
                let handle = try NativeServiceWire.callbackHandle(args[1])
                // Validate the complete model before transferring handle ownership.
                let file: NativeServiceFileRegistration?
                let intent: NativeServiceIntentRegistration?
                if request.member == "fileRegister" {
                    file = try NativeServiceFileRegistration(args[0])
                    intent = nil
                } else {
                    file = nil
                    intent = try NativeServiceIntentRegistration(args[0])
                }
                let lease = try makeLease(request, pluginId: pluginId, handle: handle, permissions: [file != nil ? .files : .intents])
                do {
                    let id: String
                    if let file { id = try interceptions.registerFile(file, lease: lease) }
                    else if let intent { id = try interceptions.registerIntent(intent, lease: lease) }
                    else { throw BridgeFailure.malformed("Missing registration model") }
                    return try PluginBridgeJSON.success(.object(["id": .string(id)]))
                } catch { lease.reject(); throw error }
            case "nativeServiceState":
                try request.requireArguments(1)
                let id = try NativeServiceWire.string(args[0], name: "id", maximum: 128)
                return try PluginBridgeJSON.success(operations.state(id: id, owner: try owner(request, pluginId: pluginId)))
            case "notificationSupported":
                try request.requireArguments(1)
                let account = try account(args[0])
                let available = notificationsAvailable(account.recordId)
                guard !available.isEmpty else { throw BridgeFailure.unavailable("No active native notification publishers for this account") }
                return try PluginBridgeJSON.success(.array(available.sorted { $0.rawValue < $1.rawValue }.map {
                    .object(["id": .integer(Int64($0.rawValue)), "name": .string($0.name)])
                }))
            case "nativeConnectionState":
                try request.requireArguments(1)
                try require(pluginId, permissions: [.messagesRead])
                let account = try account(args[0])
                stateLock.lock()
                let value = connectionStates[account.recordId]
                stateLock.unlock()
                guard let value else { throw BridgeFailure.unavailable("Connection state has not been published for this account") }
                return try PluginBridgeJSON.success(value)
            default:
                try request.requireArguments(2)
                let model = try NativeServiceAccountModel(member: request.member, value: args[0])
                let account = try snapshot().account(at: model.account)
                if request.member == "notificationSubscribe", let event = model.event,
                   !notificationsAvailable(account.recordId).contains(event) {
                    throw BridgeFailure.unimplemented("Native publisher is not installed for \(event.name)")
                }
                let permissions: Set<PluginPermission> = model.event?.permissions
                    ?? (request.member == "nativeDownload" ? [.messagesRead, .network, .files] : [.messagesRead])
                guard let scope = controllerSnapshots.values.scope(recordId: account.recordId) else {
                    throw BridgeFailure.unavailable("Native account snapshot publisher is not ready")
                }
                let handle = try NativeServiceWire.callbackHandle(args[1])
                let lease = try makeLease(request, pluginId: pluginId, handle: handle, permissions: permissions, scope: scope)
                do {
                    let persistent = ["nativeObservePeer", "nativeObserveResource", "notificationSubscribe"].contains(request.member)
                    let kind = model.event.map { "notification:\($0.rawValue)" } ?? request.member
                    let ticket = try operations.reserve(lease: lease, accountRecordId: account.recordId, kind: kind,
                        timeoutMs: persistent ? nil : model.timeoutMs, expired: { [weak self] ticket in
                            self?.finish(ticket, error: .unavailable("NATIVE_SERVICE_TIMEOUT"))
                        })
                    DispatchQueue.main.async { [weak self] in self?.start(ticket, member: request.member, model: model, persistent: persistent) }
                    return try PluginBridgeJSON.success(.object(["id": .string(ticket.id)]))
                } catch { lease.reject(); throw error }
            }
        } catch let failure as BridgeFailure {
            return try PluginBridgeJSON.failure(kind: failure.kind, message: failure.description)
        } catch let failure as ExteralessTLError {
            return try PluginBridgeJSON.failure(kind: failure.kind.rawValue, message: failure.message)
        } catch {
            return try PluginBridgeJSON.failure(kind: "MalformedRequest", message: "Native service request could not be decoded")
        }
    }

    private func owner(_ request: NativeServiceRequest, pluginId: String) throws -> Owner {
        guard let token = request.ownerToken, let owner = captureOwner(pluginId), owner.pluginId == pluginId, owner.wireToken == token else {
            throw BridgeFailure.invalidHandle("Native service request belongs to a retired or unbound interpreter")
        }
        return owner
    }

    private func require(_ pluginId: String, permissions: Set<PluginPermission>) throws {
        for permission in permissions where !hasPermission(pluginId, permission) {
            throw BridgeFailure.permission("Native service requires \(permission.rawValue)")
        }
    }

    private func makeLease(_ request: NativeServiceRequest, pluginId: String, handle: Int64, permissions: Set<PluginPermission>,
                           scope: NativeServiceSnapshots.Scope? = nil) throws -> Lease {
        let permissionCurrent = permissionAdmission(pluginId, permissions)
        guard permissionCurrent() else { throw BridgeFailure.permission("Native service permission admission expired") }
        let captured = try owner(request, pluginId: pluginId)
        let captureOwner = self.captureOwner
        let snapshots = controllerSnapshots.values
        return try leases.make(pluginId: pluginId, owner: captured, handle: handle, isCurrent: { owner in
            captureOwner(owner.pluginId) == owner && permissionCurrent()
                && (scope.map { snapshots.isCurrent($0) } ?? true)
        }, callback: callback, resultCallback: resultCallback, release: release, acknowledgedRelease: acknowledgedRelease,
            ownerWireToken: captured.wireToken)
    }

    private func account(_ value: PluginJSONValue) throws -> PluginServiceAccount {
        let index = try NativeServiceWire.integer(value, name: "account", range: 0...Int64(Int32.max))
        return try snapshot().account(at: Int32(index))
    }

    private func cached(_ request: NativeServiceRequest, pluginId: String) throws -> PluginJSONValue {
        _ = try owner(request, pluginId: pluginId)
        try require(pluginId, permissions: [.messagesRead])
        guard !request.arguments.isEmpty else { throw BridgeFailure.malformed("Cached accessor requires an account slot") }
        let args = request.arguments
        let account = try self.account(args[0])
        switch request.member {
        case "nativeCachedClientUserId":
            try request.requireArguments(1)
            guard account.userId > 0 else { return NativeServiceSnapshots.notReady("clientUserId") }
            return .object(["ready": .bool(true), "kind": .string("clientUserId"), "value": .integer(account.userId),
                "source": .string("PluginPlatformSnapshot.account.peerId")])
        case "nativeCachedClientUser":
            try request.requireArguments(1)
            return try controllerSnapshots.peer(account: account, id: 0, kind: .user)
        case "nativeCachedUser", "nativeCachedUserFull":
            try request.requireArguments(2)
            let id = try NativeServiceWire.integer(args[1], name: "userId", range: 0...0x00ff_ffff_ffff_ffff)
            return try controllerSnapshots.peer(account: account, id: id, kind: .user, full: request.member == "nativeCachedUserFull")
        case "nativeCachedChat", "nativeCachedChatFull":
            try request.requireArguments(2)
            let full = request.member == "nativeCachedChatFull"
            if case .object = args[1] {
                let model = try NativeServiceWire.object(args[1], name: "chat", keys: ["type", "id"])
                let name = try NativeServiceWire.string(model["type"], name: "chat.type", maximum: 16)
                guard let kind = NativeServiceSnapshots.Peer.Kind(rawValue: name), kind != .user else {
                    throw BridgeFailure.malformed("Cached chat requires group or channel")
                }
                let id = try NativeServiceWire.integer(model["id"], name: "chat.id", range: 1...0x00ff_ffff_ffff_ffff)
                return try controllerSnapshots.peer(account: account, id: id, kind: kind, full: full)
            }
            let id = try NativeServiceWire.integer(args[1], name: "chatId", range: 1...0x00ff_ffff_ffff_ffff)
            return try controllerSnapshots.chat(account: account, id: id, full: full)
        case "nativeCachedContacts":
            guard args.count == 1 || args.count == 3 else { throw BridgeFailure.malformed("Cached contacts takes account, optionally offset and limit") }
            guard let scope = controllerSnapshots.values.scope(recordId: account.recordId),
                  case let .object(contactData)? = controllerSnapshots.values.readyValue(key: "contacts", scope: scope),
                  case let .array(ids)? = contactData["ids"], case let .integer(total)? = contactData["total"] else {
                return NativeServiceSnapshots.notReady("contacts")
            }
            let offset = args.count == 3 ? Int(try NativeServiceWire.integer(args[1], name: "offset", range: 0...1_000_000)) : 0
            let limit = args.count == 3 ? Int(try NativeServiceWire.integer(args[2], name: "limit", range: 1...512)) : 512
            // A whole-list getter must not return a 512-entry prefix as all contacts.
            if args.count == 1 && total > Int64(ids.count) { return NativeServiceSnapshots.notReady("contacts") }
            let end = min(Int(total), offset + limit)
            guard offset <= Int(total), end <= ids.count else { return NativeServiceSnapshots.notReady("contacts") }
            let contacts = ids[min(offset, end)..<end].map { PluginJSONValue.object(["user_id": $0, "partial": .bool(true)]) }
            return .object(["ready": .bool(true), "kind": .string("contacts"),
                "value": .object(["contacts": .array(contacts), "total": .integer(total), "offset": .integer(Int64(offset)),
                    "nextOffset": end < Int(total) ? .integer(Int64(end)) : .null]),
                "source": .string("Postbox.contactPeerIdsView"), "generation": .string(scope.generation.uuidString)])
        case "nativeCachedConnection", "nativeCachedPlayback", "nativeCachedDownloads":
            try request.requireArguments(1)
            let key = request.member == "nativeCachedConnection" ? "connection" : (request.member == "nativeCachedPlayback" ? "playback" : "downloads")
            guard let scope = controllerSnapshots.values.scope(recordId: account.recordId) else { return NativeServiceSnapshots.notReady(key) }
            return controllerSnapshots.values.read(key: key, scope: scope, kind: key)
        default:
            throw BridgeFailure.memberError("Unknown native cached accessor")
        }
    }

    private func notificationsAvailable(_ recordId: Int64) -> Set<NativeServiceNotification> {
        stateLock.lock(); defer { stateLock.unlock() }
        return notificationAccounts[recordId] ?? []
    }

    @MainActor func currentAccount(recordId: Int64) -> AccountContext? {
        guard sharedContext != nil, snapshot().accounts.contains(where: { $0.recordId == recordId }),
              let context = resolveAccount(recordId), context.account.id.int64 == recordId else { return nil }
        return context
    }

    @MainActor func accountIndex(recordId: Int64) -> Int32? { snapshot().accounts.first { $0.recordId == recordId }?.index }

    @MainActor private func start(_ ticket: Ticket, member: String, model: NativeServiceAccountModel, persistent: Bool) {
        guard operations.contains(ticket) else {
            if let ticket = operations.take(id: ticket.id, owner: ticket.lease.owner) { ticket.lease.close() }
            return
        }
        guard let context = currentAccount(recordId: ticket.accountRecordId) else {
            finish(ticket, error: .unavailable("ACCOUNT_UNAVAILABLE"))
            return
        }
        let signal: Signal<ExteralessTLValue, ExteralessTLServiceError>
        switch member {
        case "nativeGetUser":
            let peer: ExteralessTLPeerReference?
            if model.currentUser {
                peer = try? ExteralessTLPeerReference(kind: .user, id: context.account.peerId.id._internalGetInt64Value())
            } else {
                peer = model.peer
            }
            guard let peer else { finish(ticket, error: .unavailable("ACCOUNT_PEER_UNAVAILABLE")); return }
            signal = nativeServiceObservePeer(account: context.account, peer: peer)
        case "nativeGetChat" where model.cachedChatId != nil:
            guard let id = model.cachedChatId else { finish(ticket, error: .malformed("Missing chat id")); return }
            signal = nativeServiceCachedChat(account: context.account, id: id)
        case "nativeGetChat", "nativeObservePeer":
            guard let peer = model.peer else { finish(ticket, error: .malformed("Missing peer")); return }
            signal = nativeServiceObservePeer(account: context.account, peer: peer)
        case "nativePeerInfo":
            guard let peer = model.peer else { finish(ticket, error: .malformed("Missing peer")); return }
            signal = nativeServicePeerDetails(account: context.account, peer: peer) |> castError(ExteralessTLServiceError.self)
        case "nativeNotificationSettings":
            guard let peer = model.peer else { finish(ticket, error: .malformed("Missing peer")); return }
            signal = nativeServiceNotificationSettings(account: context.account, peer: peer) |> castError(ExteralessTLServiceError.self)
        case "nativeGetContacts":
            signal = context.engine.data.get(TelegramEngine.EngineData.Item.Contacts.List(includePresences: false))
            |> map { nativeServiceContactPage($0, offset: model.offset, limit: model.limit) }
            |> castError(ExteralessTLServiceError.self)
        case "nativeMessageMedia":
            guard let messageId = model.engineMessageId else { finish(ticket, error: .malformed("Missing message")); return }
            signal = nativeServiceMessageMedia(account: context.account, messageId: messageId) |> castError(ExteralessTLServiceError.self)
        case "nativeResourceStatus", "nativeObserveResource", "nativeDownload":
            guard let messageId = model.engineMessageId, let fileId = model.fileId else { finish(ticket, error: .malformed("Missing message file")); return }
            if member == "nativeDownload" {
                let operations = self.operations
                signal = nativeServiceDownload(account: context.account, messageId: messageId, fileId: fileId,
                    isCancelled: { !operations.contains(ticket) })
            } else {
                signal = nativeServiceResourceStatus(account: context.account, messageId: messageId, fileId: fileId)
            }
        case "notificationSubscribe":
            // The live account observers installed in update(context:) are the
            // publishers. No callback is synthesized to simulate a notification.
            return
        default:
            finish(ticket, error: .unimplemented("Unsupported portable native service"))
            return
        }
        let disposable = (signal |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            guard let self else { return }
            guard let context, self.currentAccount(recordId: ticket.accountRecordId) === context else {
                self.finish(ticket, error: .unavailable("ACCOUNT_UNAVAILABLE"))
                return
            }
            do {
                let value = try PluginJSONValue(jsonObject: value.jsonObject)
                if member == "nativeGetContacts", case let .object(fields) = value, fields["total"] == .integer(0),
                   let scope = self.controllerSnapshots.values.scope(recordId: ticket.accountRecordId) {
                    self.controllerSnapshots.publish(.object(["ids": .array([]), "total": .integer(0), "complete": .bool(true)]),
                        key: "contacts", scope: scope, source: "explicit EngineData.Contacts.List cache read")
                }
                if persistent { self.publish(ticket, value: value) } else { self.finish(ticket, value: value) }
            } catch { self.finish(ticket, error: .malformed("NATIVE_VALUE_NOT_REPRESENTABLE")) }
        }, error: { [weak self] error in
            self?.finish(ticket, error: .unavailable(error.text))
        }, completed: { [weak self] in
            self?.finish(ticket, error: .unavailable("EMPTY_OR_ENDED_NATIVE_SIGNAL"))
        })
        let cancellation = NativeServiceSignalCancellation(disposable)
        operations.bindCancellation(ticket) { cancellation.dispose() }
    }

    private func publish(_ ticket: Ticket, value: PluginJSONValue) {
        do {
            let arguments = try NativeServiceWire.json(.array([value, .null]))
            guard try operations.publish(value, for: ticket) else { return }
            if !ticket.lease.send(argumentsJSON: arguments) {
                _ = operations.take(id: ticket.id, owner: ticket.lease.owner)
                logs.append(pluginId: ticket.lease.pluginId, level: .warning, message: "Native subscription closed: callback admission rejected")
            }
        } catch let error as BridgeFailure {
            finish(ticket, error: error)
        } catch { finish(ticket, error: .malformed("NATIVE_RESULT_TOO_LARGE")) }
    }

    private func finish(_ ticket: Ticket, value: PluginJSONValue = .null, error: BridgeFailure? = nil) {
        guard let ticket = operations.take(id: ticket.id, owner: ticket.lease.owner) else { return }
        let failure: PluginJSONValue = error.map { .object(["kind": .string($0.kind), "message": .string($0.description)]) } ?? .null
        let arguments = (try? NativeServiceWire.json(.array([value, failure])))
            ?? "[null,{\"kind\":\"ResourceLimit\",\"message\":\"NATIVE_RESULT_TOO_LARGE\"}]"
        if !ticket.lease.send(argumentsJSON: arguments, terminal: true) {
            logs.append(pluginId: ticket.lease.pluginId, level: .warning, message: "Native operation released: callback admission rejected")
        }
    }

    @MainActor private func observe(_ context: AccountContext) {
        let recordId = context.account.id.int64
        if observations[recordId]?.context === context { return }
        removeAccount(recordId)
        let scope = controllerSnapshots.attach(context)
        let observation = NativeServiceAccountObservation(context: context, scope: scope)
        observations[recordId] = observation
        observation.disposables.add((context.account.networkState |> deliverOnMainQueue).start(next: { [weak self, weak context] state in
            guard let self, let context, self.observations[recordId]?.context === context else { return }
            let value: PluginJSONValue
            switch state {
            case .waitingForNetwork: value = .string("waitingForNetwork")
            case .connecting: value = .string("connecting")
            case .updating: value = .string("updating")
            case .online: value = .string("online")
            }
            self.stateLock.lock()
            let previous = self.connectionStates.updateValue(value, forKey: recordId)
            self.stateLock.unlock()
            self.controllerSnapshots.publish(value, key: "connection", scope: scope, source: "Account.networkState")
            if let previous, previous != value { self.emit(.didUpdateConnectionState, arguments: [], scope: scope) }
        }))
        observation.disposables.add((nativeServiceContactIDs(account: context.account)
        |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            guard let self, let context, let observation = self.observations[recordId], observation.context === context else { return }
            guard let value = try? PluginJSONValue(jsonObject: value.jsonObject) else { return }
            let changed = observation.contacts != value
            observation.contacts = value
            self.controllerSnapshots.publish(value, key: "contacts", scope: scope, source: "Postbox.contactPeerIdsView")
            if changed, value != .null { self.emit(.contactsDidLoad, arguments: [], scope: scope) }
        }))
        observation.disposables.add((context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            guard let self, let context, let observation = self.observations[recordId], observation.context === context else { return }
            let changed = observation.hasOwnPeer && observation.ownPeer != value
            observation.ownPeer = value
            observation.hasOwnPeer = true
            if let value { self.controllerSnapshots.seed([nativeServicePeerHeader(value, accountUserId: scope.userId)], scope: scope) }
            if changed { self.emit(.mainUserInfoChanged, arguments: [], scope: scope) }
        }))
        let publishers = NativeServiceLivePublishers(context: context, scope: scope, snapshots: controllerSnapshots) { [weak self] event, arguments in
            self?.emit(event, arguments: arguments, scope: scope)
        }
        observation.publishers = publishers
        var available = publishers.events.union([.contactsDidLoad, .mainUserInfoChanged, .didUpdateConnectionState])
        if publisherSites.contains(.committedMessages) { available.insert(.didReceiveNewMessages) }
        if publisherSites.contains(.mediaFetch) { available.formUnion([.fileLoaded, .fileLoadFailed]) }
        let source = NativeServiceAccountEventSource(account: context.account,
            messages: publisherSites.contains(.committedMessages), files: publisherSites.contains(.mediaFetch))
        observation.eventSource = source
        // No main-queue hop: budget/admit these already-applied events immediately
        // in the producer's order, before an unbounded UI queue could accumulate.
        observation.disposables.add(source.signal.start(next: { [weak self] event in
            guard let self, self.controllerSnapshots.values.isCurrent(scope) else { return }
            switch event {
            case let .messages(arguments, headers):
                guard self.publisherSites.contains(.committedMessages) else { return }
                self.controllerSnapshots.seed(headers, scope: scope)
                do { self.emit(.didReceiveNewMessages, arguments: try arguments.map { try PluginJSONValue(jsonObject: $0.jsonObject) }, scope: scope) }
                catch { self.retireNotifications(scope: scope, reason: "MESSAGE_EVENT_PROJECTION_FAILED") }
            case let .fileLoaded(key, path):
                guard self.publisherSites.contains(.mediaFetch) else { return }
                self.emit(.fileLoaded, arguments: [.string(key), .string(path)], scope: scope)
            case let .fileLoadFailed(key, reason):
                guard self.publisherSites.contains(.mediaFetch) else { return }
                self.emit(.fileLoadFailed, arguments: [.string(key), .integer(Int64(reason))], scope: scope)
            case let .gap(reason): self.retireNotifications(scope: scope, reason: reason)
            }
        }))
        stateLock.lock()
        notificationAccounts[recordId] = available
        stateLock.unlock()
    }

    private func emit(_ event: NativeServiceNotification, arguments: [PluginJSONValue], scope: NativeServiceSnapshots.Scope) {
        guard controllerSnapshots.values.isCurrent(scope),
              let account = snapshot().accounts.first(where: { $0.recordId == scope.recordId }) else { return }
        func stamp(_ value: PluginJSONValue) -> PluginJSONValue {
            guard case var .object(fields) = value, fields["nativeType"] == .string("MessageObject") else { return value }
            fields["currentAccount"] = .integer(Int64(account.index))
            return .object(fields)
        }
        var payload = arguments
        if event == .didReceiveNewMessages, payload.count == 4, case let .array(messages) = payload[1] { payload[1] = .array(messages.map(stamp)) }
        if event == .messagePlayingDidStart { payload = payload.map(stamp) }
        let args = PluginJSONValue.array([.integer(Int64(event.rawValue)), .integer(Int64(account.index)), .array(payload)])
        guard let json = try? NativeServiceWire.json(args) else {
            for ticket in operations.tickets(accountRecordId: scope.recordId, kind: "notification:\(event.rawValue)") {
                retireNotification(ticket, reason: "NATIVE_EVENT_TOO_LARGE")
            }
            return
        }
        for ticket in operations.tickets(accountRecordId: scope.recordId, kind: "notification:\(event.rawValue)") {
            do {
                guard try operations.publish(args, for: ticket) else { continue }
                let snapshots = controllerSnapshots.values
                let accepted = eventDelivery.enqueue(lease: ticket.lease, argumentsJSON: json,
                    coalescingKey: event.coalesces ? event.name : nil,
                    valid: { snapshots.isCurrent(scope) && ticket.lease.isOpen },
                    retire: { [weak self] in self?.retireNotification(ticket, reason: "NATIVE_EVENT_DELIVERY_FAILED") })
                if !accepted { retireNotification(ticket, reason: "NATIVE_EVENT_ADMISSION_FAILED") }
            } catch {
                retireNotification(ticket, reason: "NATIVE_EVENT_SNAPSHOT_BUDGET")
            }
        }
    }

    private func retireNotification(_ ticket: Ticket, reason: String) {
        guard let ticket = operations.take(id: ticket.id, owner: ticket.lease.owner) else { return }
        ticket.lease.close()
        eventDelivery.remove(subscriptionId: ticket.id)
        logs.append(pluginId: ticket.lease.pluginId, level: .warning, message: reason)
    }

    private func retireNotifications(scope: NativeServiceSnapshots.Scope, reason: String) {
        guard controllerSnapshots.values.isCurrent(scope) else { return }
        for event in NativeServiceNotification.allCases {
            for ticket in operations.tickets(accountRecordId: scope.recordId, kind: "notification:\(event.rawValue)") {
                retireNotification(ticket, reason: reason)
            }
        }
    }

    @MainActor private func removeAccount(_ recordId: Int64) {
        controllerSnapshots.detach(recordId)
        let observation = observations.removeValue(forKey: recordId)
        observation?.eventSource?.close()
        observation?.publishers?.dispose()
        observation?.disposables.dispose()
        stateLock.lock()
        connectionStates.removeValue(forKey: recordId)
        notificationAccounts.removeValue(forKey: recordId)
        stateLock.unlock()
        for ticket in operations.takeAll(accountRecordId: recordId) {
            ticket.lease.close()
            eventDelivery.remove(subscriptionId: ticket.id)
        }
        interceptions.cancelOpenings(accountRecordId: recordId)
        NativeServiceOpenHooks.shared.cancelPreparations(provider: self, accountRecordId: recordId)
    }

    deinit {
        accountsDisposable?.dispose()
        for observation in observations.values {
            observation.eventSource?.close()
            observation.publishers?.dispose()
            observation.disposables.dispose()
        }
        scheduler.cancelAll()
        interceptions.cancelOpenings()
        interceptions.releaseInstances()
        for ticket in operations.takeAll() { ticket.lease.close() }
        leases.closeAll()
    }
}

private final class NativeServiceAccountObservation {
    let context: AccountContext
    let disposables = DisposableSet()
    let scope: NativeServiceSnapshots.Scope
    var contacts: PluginJSONValue?
    var eventSource: NativeServiceAccountEventSource?
    var publishers: NativeServiceLivePublishers?
    var ownPeer: EnginePeer?
    var hasOwnPeer = false
    init(context: AccountContext, scope: NativeServiceSnapshots.Scope) { self.context = context; self.scope = scope }
}

/// SwiftSignalKit's disposable is thread-safe but predates Sendable annotations.
/// Publish only this exactly-once cancellation wrapper across the owner boundary.
private final class NativeServiceSignalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var disposable: Disposable?
    init(_ disposable: Disposable) { self.disposable = disposable }
    func dispose() {
        lock.lock()
        let disposable = self.disposable
        self.disposable = nil
        lock.unlock()
        disposable?.dispose()
    }
}
