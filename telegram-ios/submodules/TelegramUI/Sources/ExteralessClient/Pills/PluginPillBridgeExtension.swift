import AccountContext
import ExteralessCore
import Foundation
import PluginHost
import UIKit

/// Native plugin pills use the same registry, subscriptions and UIKit header as built-ins.
/// C dispatch never waits for main or invokes Python inline.
public final class PluginPillBridgeExtension: PluginBridgeExtension, @unchecked Sendable {
    public let exportedMethods: [String: Set<String>] = ["exteraless.ios.Runtime": PluginPillWire.members]
    private static let layoutKeys: Set<String> = ["chats.activePillsRaw", "chats.hiddenPillsRaw", "chats.lastActivePillId", "chats.infiniteScrolling", "chats.rateInstancesRaw"]
    private typealias Owner = PluginHost.CallbackOwner
    private final class Scope: @unchecked Sendable {
        let nativeLease: PillAccountLease
        let gate: PillAccountLease
        let lifetime = PillCancellation()
        let account: Int32
        var id: PillAccountScope { self.gate.scope }
        // This flag never takes the durable-write gate while the bridge state lock is held.
        var valid: Bool { !self.lifetime.isCancelled }
        init(nativeLease: PillAccountLease, account: Int32) {
            self.nativeLease = nativeLease; self.gate = PillAccountLease(scope: nativeLease.scope); self.account = account
        }
    }
    private final class Selection: @unchecked Sendable {
        let id = UUID()
        let scope: Scope
        let context: PluginJSONValue
        let created = ProcessInfo.processInfo.systemUptime
        var lastAutomaticUpdate = ProcessInfo.processInfo.systemUptime
        var update: (@Sendable (PillModel) -> Void)?
        var pending: PillModel?
        var scheduled = false
        var lastDelivery: TimeInterval?
        init(scope: Scope, context: (UUID) -> PluginJSONValue, update: @escaping @Sendable (PillModel) -> Void) {
            self.scope = scope; self.context = context(self.id); self.update = update
        }
    }
    private final class Entry: @unchecked Sendable {
        let id: UUID
        let owner: Owner
        let descriptor: PluginPillDescriptor
        let callbacks: PluginPillCallbacks
        var nativeId: Int?
        var registration: PillCancellation?
        var selections: [UUID: Selection] = [:]
        var transferred = false
        var retired = false
        init(id: UUID, owner: Owner, descriptor: PluginPillDescriptor, callbacks: PluginPillCallbacks) {
            self.id = id; self.owner = owner; self.descriptor = descriptor; self.callbacks = callbacks
        }
    }
    private struct LayoutReceipt {
        let owner: Owner
        let scope: Scope
        let snapshot: ClientSettingsSnapshot
        let created: TimeInterval
    }

    private let lock = NSLock()
    private let dispatcher: PluginCallbackDispatcher
    private let registry: PillPluginRegistry
    private let settings: ClientSettings
    private let identities: PluginPillIdentityArchive
    private let releaseQueue: PluginPillReleaseQueue
    private let platformSnapshot: @Sendable () -> PluginPlatformSnapshot
    private let deliveries = DispatchQueue(label: "Exteraless.Pills.PluginModels", qos: .utility)
    private var scope: Scope?
    private var foreground = false
    private var foregroundObservers: [NSObjectProtocol] = []
    private var entries: [UUID: Entry] = [:] // Retirements remain budgeted until FIFO release admission.
    private var nativeIds: [Int: UUID] = [:]
    private var receipts: [UUID: LayoutReceipt] = [:]
    private var settingsObservation: ClientSettingsObservation?

    public init(identityURL: URL, callbacks: PluginCallbackDispatcher,
                platformSnapshot: @escaping @Sendable () -> PluginPlatformSnapshot,
                registry: PillPluginRegistry = .shared, settings: ClientSettings = .shared) throws {
        self.dispatcher = callbacks; self.platformSnapshot = platformSnapshot
        self.registry = registry; self.settings = settings
        self.identities = try PluginPillIdentityArchive(url: identityURL)
        self.releaseQueue = PluginPillReleaseQueue(dispatcher: callbacks)
        self.settingsObservation = settings.observe { [weak self] keys in
            guard keys.isEmpty || keys.contains("chats.rateInstancesRaw") else { return }
            self?.retireRateCollisions()
        }
        PluginPillBridgeActions.install(self)
    }

    public convenience init(services: TelegramPluginServices, callbacks: PluginCallbackDispatcher, identityURL: URL) throws {
        try self.init(identityURL: identityURL, callbacks: callbacks, platformSnapshot: { services.platformSnapshot })
    }

    deinit {
        self.settingsObservation?.cancel()
        for observer in self.foregroundObservers { NotificationCenter.default.removeObserver(observer) }
        for entry in self.entries.values { entry.registration?.cancel(); entry.callbacks.close() }
    }

    @MainActor public func update(context: AccountContext) {
        if self.foregroundObservers.isEmpty {
            self.foregroundObservers = [
                NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setForeground(false) },
                NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setForeground(true) }
            ]
        }
        self.setForeground(UIApplication.shared.applicationState == .active)
        let nativeLease = ExteralessPillRuntimes.get(context: context).lease
        guard let account = self.platformSnapshot().accounts.first(where: { $0.recordId == context.account.id.int64 }) else { self.clearContext(); return }
        self.lock.lock()
        let unchanged = self.scope?.id == nativeLease.scope && self.scope?.valid == true
        self.lock.unlock()
        guard !unchanged else { return }
        self.replaceScope(Scope(nativeLease: nativeLease, account: account.index))
    }

    @MainActor public func clearContext() { self.replaceScope(nil) }

    private func setForeground(_ value: Bool) {
        self.lock.lock()
        self.foreground = value
        var stopped: [(Entry, Selection)] = []
        if !value {
            for entry in self.entries.values {
                for selection in entry.selections.values {
                    selection.update = nil; selection.pending = nil
                    stopped.append((entry, selection))
                }
                entry.selections.removeAll()
            }
        }
        self.lock.unlock()
        // Cleanup is allowed; start/update/tap/result gates are already synchronously closed.
        for (entry, selection) in stopped { self.sendStop(entry: entry, selection: selection) }
    }

    private func replaceScope(_ next: Scope?) {
        self.lock.lock()
        let previous = self.scope; self.scope = next; self.receipts.removeAll()
        for entry in self.entries.values {
            for selection in entry.selections.values { selection.update = nil; selection.pending = nil }
            entry.selections.removeAll()
        }
        self.lock.unlock()
        previous?.lifetime.cancel()
        previous?.gate.invalidate()
        // Registrations and their callback wrappers survive an account switch; old selection work does not.
    }

    public func releaseInstances(pluginId: String) {
        self.lock.lock()
        let retired = self.entries.values.filter { $0.owner.pluginId == pluginId }.map(\.id)
        self.receipts = self.receipts.filter { $0.value.owner.pluginId != pluginId }
        self.lock.unlock()
        // Host calls after retiring the interpreter. A concurrently published new owner is not removed.
        for id in retired {
            self.lock.lock(); let owner = self.entries[id]?.owner; self.lock.unlock()
            if let owner, self.dispatcher.captureOwner(pluginId) != owner { self.retire(id) }
        }
        self.releaseQueue.kick()
    }

    public func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        do {
            guard let request = try NativeServiceRequest(json: requestJSON, members: PluginPillWire.members) else { return nil }
            guard requestJSON.utf8.count <= 65_536 else { throw BridgeFailure.malformed("Pill request exceeds 64 KiB") }
            if request.memberKind { return try PluginBridgeJSON.success(.string("method")) }
            self.releaseQueue.kick()
            if request.member == "pillUnregister" {
                try request.requireArguments(1)
                return try PluginBridgeJSON.success(.bool(self.unregister(request, pluginId: pluginId)))
            }
            let owner = try self.owner(request, pluginId: pluginId)
            let value: PluginJSONValue
            switch request.member {
            case "pillRegister":
                try request.requireArguments(2)
                value = try self.register(owner: owner, descriptor: PluginPillDescriptor(request.arguments[0]), handles: PluginPillWire.callbacks(request.arguments[1]))
            case "pillUpdate":
                try request.requireArguments(2)
                try self.publish(owner: owner, id: PluginPillWire.uuid(request.arguments[0], name: "id"), value: request.arguments[1])
                value = .null
            case "pillGetLayout":
                try request.requireArguments(0); try self.requireSettings(owner)
                value = try self.getLayout(owner: owner)
            case "pillSaveLayout":
                try request.requireArguments(1); try self.requireSettings(owner)
                try self.saveLayout(owner: owner, value: request.arguments[0])
                value = .null
            default: return nil
            }
            return try PluginBridgeJSON.success(value)
        } catch let failure as BridgeFailure {
            return try PluginBridgeJSON.failure(kind: failure.kind, message: failure.description)
        } catch ClientSettingsError.concurrentModification {
            return try PluginBridgeJSON.failure(kind: "SettingsConflict", message: "Pill layout changed. Read a new snapshot before saving.")
        } catch is PluginPillIdentityArchive.Failure {
            return try PluginBridgeJSON.failure(kind: "ServiceUnavailable", message: "Pill identity metadata is unavailable, invalid or full. Existing mappings were preserved.")
        } catch is ClientSettingsError {
            return try PluginBridgeJSON.failure(kind: "ServiceUnavailable", message: "Pill settings could not be committed. Read the current layout before retrying.")
        } catch {
            return try PluginBridgeJSON.failure(kind: "MalformedRequest", message: "Invalid or retired native pill request")
        }
    }

    private func owner(_ request: NativeServiceRequest, pluginId: String) throws -> Owner {
        guard PluginPillIdentityArchive.validPluginId(pluginId), let token = request.ownerToken,
              let owner = self.dispatcher.captureOwner(pluginId), owner.pluginId == pluginId,
              owner.wireToken == token, UUID(uuidString: token) != nil else {
            throw BridgeFailure.invalidHandle("Pill request belongs to a retired or unbound interpreter")
        }
        guard self.isCurrent(owner) else { throw BridgeFailure.permission("Pill registration requires ui permission") }
        return owner
    }
    /// Host permits its retiring C epoch to clean up. Use the originally captured owner;
    /// captureOwner deliberately returns nil during unloading, when new effects are forbidden.
    private func unregister(_ request: NativeServiceRequest, pluginId: String) throws -> Bool {
        guard PluginPillIdentityArchive.validPluginId(pluginId), let token = request.ownerToken,
              UUID(uuidString: token) != nil, self.dispatcher.hasPermission(pluginId, .ui) else {
            throw BridgeFailure.invalidHandle("Pill cleanup requires its bound native owner")
        }
        let id = try PluginPillWire.uuid(request.arguments[0], name: "id")
        self.lock.lock(); let entry = self.entries[id]; self.lock.unlock()
        guard let entry else { return false }
        guard entry.owner.pluginId == pluginId, entry.owner.wireToken == token else {
            throw BridgeFailure.invalidHandle("Pill cleanup belongs to another interpreter lifetime")
        }
        return self.retire(id)
    }
    private func isCurrent(_ owner: Owner) -> Bool {
        self.dispatcher.captureOwner(owner.pluginId) == owner && self.dispatcher.hasPermission(owner.pluginId, .ui)
    }
    private func requireSettings(_ owner: Owner) throws {
        guard self.isCurrent(owner), self.dispatcher.hasPermission(owner.pluginId, .settings) else { throw BridgeFailure.permission("Global pill layout requires settings permission") }
    }

    private func register(owner: Owner, descriptor: PluginPillDescriptor, handles: [String: Int64]) throws -> PluginJSONValue {
        let id = UUID()
        let callbacks = PluginPillCallbacks(owner: owner, handles: handles, dispatcher: self.dispatcher,
            isCurrent: { [weak self] in self?.isCurrent(owner) == true }, release: { [weak self] owner, handles in
                guard let self else { return }
                self.releaseQueue.enqueue(owner: owner, handles: handles) { [weak self] in self?.finishRetirement(id) }
            })
        let entry = Entry(id: id, owner: owner, descriptor: descriptor, callbacks: callbacks)
        self.lock.lock()
        let duplicate = self.entries.values.contains { !$0.retired && $0.owner.pluginId == owner.pluginId && $0.descriptor.androidId == descriptor.androidId }
        let claimed = Set(self.entries.values.filter { $0.owner == owner }.flatMap { $0.callbacks.handles.values })
        guard self.entries.count < 64, !duplicate, claimed.isDisjoint(with: handles.values), self.isCurrent(owner) else {
            self.lock.unlock()
            throw BridgeFailure.invalidHandle("Pill registration limit, duplicate identity, reused callback wrapper or retired owner")
        }
        self.entries[id] = entry // Reserve budget/handles before disk work; no main-thread wait for filesystem I/O.
        self.lock.unlock()
        do {
            let configuration = try PillConfiguration(values: self.layoutSnapshot().values)
            let occupied = Set(configuration.instances.map(\.id) + configuration.layout.active + configuration.layout.hidden + self.registry.descriptors.map(\.id))
            let identity = try self.identities.resolve(pluginId: owner.pluginId, androidId: descriptor.androidId, reserving: occupied)
            let nativeId = Int(identity.nativeId)
            self.lock.lock()
            guard self.entries[id] === entry, !entry.retired, self.isCurrent(owner) else { self.lock.unlock(); throw BridgeFailure.invalidHandle("Pill registration retired during admission") }
            let currentConfiguration: PillConfiguration
            do { currentConfiguration = try PillConfiguration(values: self.layoutSnapshot().values) }
            catch { self.lock.unlock(); throw error }
            guard !currentConfiguration.instances.contains(where: { $0.id == nativeId }),
                  self.nativeIds[nativeId] == nil else { self.lock.unlock(); throw BridgeFailure.invalidHandle("Persistent pill ID conflicts with a dynamic rate/native registration") }
            entry.nativeId = nativeId
            do {
                let provider = PluginPillNativeProvider(bridge: self, registrationId: id)
                entry.registration = try self.registry.register(owner: PillPluginOwner(pluginId: owner.pluginId, generation: UUID(uuidString: owner.wireToken)!), descriptor: descriptor.native(id: nativeId), provider: provider)
            } catch { self.lock.unlock(); throw error }
            entry.transferred = true; callbacks.transfer(); self.nativeIds[nativeId] = id
            self.lock.unlock()
            return .object(["id": .string(id.uuidString), "nativeId": .integer(Int64(nativeId)), "androidId": .integer(Int64(descriptor.androidId)), "refreshIntervalMs": .integer(descriptor.refreshIntervalMs), "mappingVersion": .integer(1)])
        } catch {
            self.retire(id)
            throw error
        }
    }

    @discardableResult private func retire(_ id: UUID) -> Bool {
        self.lock.lock()
        guard let entry = self.entries[id], !entry.retired else { self.lock.unlock(); return false }
        entry.retired = true
        if let nativeId = entry.nativeId, self.nativeIds[nativeId] == id { self.nativeIds.removeValue(forKey: nativeId) }
        for selection in entry.selections.values { selection.update = nil; selection.pending = nil }
        entry.selections.removeAll()
        let registration = entry.registration; entry.registration = nil
        if !entry.transferred { self.entries.removeValue(forKey: id) }
        self.lock.unlock()
        registration?.cancel()
        entry.callbacks.close()
        return true
    }
    private func finishRetirement(_ id: UUID) { self.lock.lock(); self.entries.removeValue(forKey: id); self.lock.unlock() }
    private func retireRateCollisions() {
        guard let config = try? PillConfiguration(values: self.settings.snapshot()) else { return }
        let rates = Set(config.instances.map(\.id))
        self.lock.lock(); let ids = self.entries.values.filter { $0.nativeId.map(rates.contains) == true }.map(\.id); self.lock.unlock()
        for id in ids { self.retire(id) }
    }
    private func layoutSnapshot() throws -> ClientSettingsSnapshot {
        let value = self.settings.readSnapshot()
        guard Self.layoutKeys.isSubset(of: Set(value.definitions.map(\.key))) else { throw BridgeFailure.unavailable("Pill layout definitions are not registered") }
        let values = value.values.filter { Self.layoutKeys.contains($0.key) }
        for key in ["chats.activePillsRaw", "chats.hiddenPillsRaw", "chats.rateInstancesRaw"] {
            if case let .string(raw)? = values[key], raw.utf8.count > 65_536 { throw BridgeFailure.unavailable("Saved pill layout exceeds the bridge's bounded snapshot size and was preserved") }
        }
        return ClientSettingsSnapshot(definitions: value.definitions.filter { Self.layoutKeys.contains($0.key) }, values: values,
            storedKeys: value.storedKeys.intersection(Self.layoutKeys), secretKeys: value.secretKeys.intersection(Self.layoutKeys))
    }

    fileprivate func attach(_ id: UUID, request: PillPluginRequest, update: @escaping @Sendable (PillModel) -> Void) -> PillCancellation {
        self.lock.lock()
        guard let entry = self.entries[id], entry.transferred, !entry.retired, entry.nativeId == request.id,
              self.foreground, let scope = self.scope, scope.id == request.scope, scope.valid, self.isCurrent(entry.owner), entry.selections.count < 8 else {
            self.lock.unlock(); let result = PillCancellation(); result.cancel(); return result
        }
        let selection = Selection(scope: scope, context: { selection in .object([
            "id": .string(id.uuidString), "nativeId": .integer(Int64(request.id)), "androidId": .integer(Int64(entry.descriptor.androidId)),
            "selection": .string(selection.uuidString), "account": .integer(Int64(scope.account)),
            "accountRecordId": .string(String(scope.id.accountId)), "generation": .string(scope.id.generation.uuidString)
        ]) }, update: update)
        entry.selections[selection.id] = selection
        self.lock.unlock()
        self.send(entry: entry, selection: selection, name: "start", extra: [])
        self.send(entry: entry, selection: selection, name: "update", extra: [.bool(false)])
        return PillCancellation { [weak self] in self?.detach(id, selectionId: selection.id) }
    }

    private func detach(_ id: UUID, selectionId: UUID) {
        self.lock.lock()
        guard let entry = self.entries[id], let selection = entry.selections.removeValue(forKey: selectionId) else { self.lock.unlock(); return }
        selection.update = nil; selection.pending = nil
        let shouldNotify = !entry.retired && self.scope === selection.scope && selection.scope.valid && self.isCurrent(entry.owner)
        self.lock.unlock()
        if shouldNotify { self.sendStop(entry: entry, selection: selection) }
    }
    private func sendStop(entry: Entry, selection: Selection) {
        if let arguments = try? NativeServiceWire.json(.array([selection.context])) {
            _ = entry.callbacks.send("stop", arguments: arguments, gate: { [weak self] in self?.entryCurrent(entry.id, scope: selection.scope.id) == true })
        }
    }

    private func entryCurrent(_ id: UUID, scope: PillAccountScope) -> Bool {
        self.lock.lock()
        guard let entry = self.entries[id], !entry.retired, let current = self.scope, current.id == scope, current.valid else { self.lock.unlock(); return false }
        self.lock.unlock()
        return self.isCurrent(entry.owner) && current.nativeLease.isValid
    }
    private func selectionCurrent(_ id: UUID, selection: UUID) -> Bool {
        self.lock.lock()
        guard self.foreground, let entry = self.entries[id], !entry.retired, let selection = entry.selections[selection], selection.update != nil,
              self.scope === selection.scope, selection.scope.valid else { self.lock.unlock(); return false }
        self.lock.unlock()
        return self.isCurrent(entry.owner) && selection.scope.nativeLease.isValid
    }
    private func send(entry: Entry, selection: Selection, name: String, extra: [PluginJSONValue]) {
        guard let arguments = try? NativeServiceWire.json(.array([selection.context] + extra)) else { return }
        if !entry.callbacks.send(name, arguments: arguments, gate: { [weak self] in self?.selectionCurrent(entry.id, selection: selection.id) == true }) {
            self.retire(entry.id)
        }
    }

    fileprivate func action(_ id: UUID, action: PillPluginAction, request: PillPluginRequest, force: Bool = false,
                            longPressCompletion: (@Sendable (Bool) -> Void)? = nil) {
        self.lock.lock()
        guard self.foreground, let entry = self.entries[id], !entry.retired, entry.nativeId == request.id,
              self.scope?.id == request.scope, self.scope?.valid == true, self.isCurrent(entry.owner) else { self.lock.unlock(); return }
        let candidates = entry.selections.values.filter { $0.scope.id == request.scope && $0.update != nil }
        let selected: [Selection]
        if action == .refresh && !force {
            let now = ProcessInfo.processInfo.systemUptime
            selected = candidates.filter { entry.descriptor.refreshIntervalMs != 0 && now - $0.lastAutomaticUpdate >= Double(entry.descriptor.refreshIntervalMs) / 1000 }
            for selection in selected { selection.lastAutomaticUpdate = now }
        } else {
            // Core actions identify an account/pill, not a view. Never duplicate a tap side effect across surfaces.
            selected = candidates.max(by: { $0.created < $1.created }).map { [$0] } ?? []
        }
        self.lock.unlock()
        for selection in selected {
            switch action {
            case .refresh:
                if force || entry.descriptor.refreshIntervalMs != 0 { self.send(entry: entry, selection: selection, name: "update", extra: [.bool(force)]) }
            case .tap: self.send(entry: entry, selection: selection, name: "tap", extra: [])
            case .longPress:
                guard let arguments = try? NativeServiceWire.json(.array([selection.context])) else { continue }
                let accepted = entry.callbacks.longPress(arguments: arguments, gate: { [weak self] in self?.selectionCurrent(id, selection: selection.id) == true }) { [weak self] handled in
                    guard let longPressCompletion else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard self?.selectionCurrent(id, selection: selection.id) == true else { return }
                        longPressCompletion(handled)
                    }
                }
                if !accepted { self.retire(id) }
            }
        }
    }

    /// Main-thread callers only enqueue native owner work; they do not invoke Python.
    func route(nativeId: Int, scope: PillAccountScope, action: PillPluginAction, force: Bool,
               completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        self.lock.lock(); let id = self.nativeIds[nativeId]; self.lock.unlock()
        guard let id else { return false }
        self.action(id, action: action, request: .init(id: nativeId, scope: scope), force: force, longPressCompletion: completion)
        return true
    }

    private func publish(owner: Owner, id: UUID, value: PluginJSONValue) throws {
        self.lock.lock(); let entry = self.entries[id]; self.lock.unlock()
        guard let entry, entry.owner == owner, let nativeId = entry.nativeId else { throw BridgeFailure.invalidHandle("Unknown pill registration") }
        let (selectionId, model) = try PluginPillWire.model(value, nativeId: nativeId, descriptor: entry.descriptor, pluginId: owner.pluginId)
        guard self.selectionCurrent(id, selection: selectionId) else { throw BridgeFailure.invalidHandle("Pill update belongs to an inactive native selection") }
        self.lock.lock()
        guard self.foreground, self.entries[id] === entry, !entry.retired, let selection = entry.selections[selectionId], selection.update != nil,
              self.scope === selection.scope, selection.scope.valid, self.isCurrent(owner) else { self.lock.unlock(); throw BridgeFailure.invalidHandle("Pill update belongs to an inactive selection or account generation") }
        selection.pending = model
        let schedule = !selection.scheduled
        selection.scheduled = true
        let delay = max(0, (selection.lastDelivery ?? -1) + 0.26 - ProcessInfo.processInfo.systemUptime)
        self.lock.unlock()
        if schedule { self.deliveries.asyncAfter(deadline: .now() + delay) { [weak self] in self?.deliver(id, selection: selectionId) } }
    }
    private func deliver(_ id: UUID, selection selectionId: UUID) {
        self.lock.lock()
        guard self.foreground, let entry = self.entries[id], !entry.retired, let selection = entry.selections[selectionId],
              self.scope === selection.scope, selection.scope.valid, self.isCurrent(entry.owner), let update = selection.update else { self.lock.unlock(); return }
        let model = selection.pending; selection.pending = nil; selection.scheduled = false
        selection.lastDelivery = ProcessInfo.processInfo.systemUptime
        self.lock.unlock()
        if let model, selection.scope.valid, selection.scope.nativeLease.isValid { update(model) } // Registry/header also recheck their subscription tokens.
    }

    private func getLayout(owner: Owner) throws -> PluginJSONValue {
        self.lock.lock(); let scope = self.scope; self.lock.unlock()
        guard let scope, scope.valid, scope.nativeLease.isValid else { throw BridgeFailure.unavailable("Pill layout requires an active account scope") }
        let identities = try self.identities.identities(pluginId: owner.pluginId)
        let snapshot = try self.layoutSnapshot()
        let config = try PillConfiguration(values: snapshot.values)
        let revision = UUID(); let now = ProcessInfo.processInfo.systemUptime
        self.lock.lock()
        self.receipts = self.receipts.filter { now - $0.value.created < 300 && self.isCurrent($0.value.owner) }
        guard self.scope === scope, scope.valid, self.isCurrent(owner), self.receipts.count < 64,
              self.receipts.values.filter({ $0.owner == owner }).count < 32 else { self.lock.unlock(); throw BridgeFailure.unavailable("Pill layout snapshot scope/budget unavailable") }
        self.receipts[revision] = LayoutReceipt(owner: owner, scope: scope, snapshot: snapshot, created: now)
        self.lock.unlock()
        return PluginPillWire.layout(config.layout, revision: revision, identities: identities)
    }

    private func saveLayout(owner: Owner, value: PluginJSONValue) throws {
        let object = try NativeServiceWire.object(value, name: "Pill layout", keys: ["revision", "idSpace", "active", "hidden", "selected", "infiniteScrolling"])
        guard object["idSpace"] == .string("native") else { throw BridgeFailure.malformed("Pill layout IDs must use the native namespace") }
        let revision = try PluginPillWire.uuid(object["revision"], name: "revision")
        let active = try PluginPillWire.ids(object["active"], name: "active")
        let hidden = try PluginPillWire.ids(object["hidden"], name: "hidden")
        let selected = try NativeServiceWire.integer(object["selected"], name: "selected")
        guard let selected = Int(exactly: selected), Set(active).isDisjoint(with: hidden), selected == -1 || active.contains(selected) else { throw BridgeFailure.malformed("Pill layout lists overlap or selected ID is not active") }
        let loop = try NativeServiceWire.bool(object["infiniteScrolling"], name: "infiniteScrolling")
        self.lock.lock()
        guard let receipt = self.receipts[revision], receipt.owner == owner, self.scope === receipt.scope,
              receipt.scope.valid, ProcessInfo.processInfo.systemUptime - receipt.created < 300 else { self.lock.unlock(); throw BridgeFailure.invalidHandle("Pill layout revision expired or belongs to another scope") }
        self.receipts.removeValue(forKey: revision)
        self.lock.unlock()
        let config = try PillConfiguration(values: receipt.snapshot.values)
        let available = Set(PillRegistry.descriptors(configuration: config, plugins: self.registry.descriptors).map(\.id))
        let layout = PluginPillWire.preservingDormant(.init(active: active, hidden: hidden, selected: selected, loop: loop), previous: config.layout, available: available)
        var patch = layout.patch
        patch["chats.rateInstancesRaw"] = receipt.snapshot.values["chats.rateInstancesRaw"] ?? .string("")
        try receipt.scope.gate.withCurrent {
            guard receipt.scope.nativeLease.isValid else { throw BridgeFailure.invalidHandle("Pill account generation retired") }
            try self.requireSettings(owner)
            try self.settings.applyPublic(patch, expected: receipt.snapshot)
        }
    }
}

private final class PluginPillNativeProvider: PillPluginProvider, @unchecked Sendable {
    private weak var bridge: PluginPillBridgeExtension?
    private let registrationId: UUID
    init(bridge: PluginPillBridgeExtension, registrationId: UUID) { self.bridge = bridge; self.registrationId = registrationId }
    func start(_ request: PillPluginRequest, update: @escaping @Sendable (PillModel) -> Void) -> PillCancellation {
        self.bridge?.attach(self.registrationId, request: request, update: update) ?? PillCancellation()
    }
    func perform(_ action: PillPluginAction, request: PillPluginRequest) { self.bridge?.action(self.registrationId, action: action, request: request) }
}
