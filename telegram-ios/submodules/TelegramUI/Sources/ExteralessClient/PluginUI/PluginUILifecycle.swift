import Foundation

struct PluginUIScope: Equatable, Sendable {
    let id: UUID
    let accountRecordId: Int64
}

enum PluginUILeaseContent: Equatable, Sendable {
    case presentation(PluginUIModel)
    case menu(PluginUIMenuModel)
    case navigation(PluginUINavigationModel)

    var kind: String {
        switch self {
        case let .presentation(model): return model.kind.rawValue
        case .menu: return "menuRegistration"
        case let .navigation(model): return model.route
        }
    }

    var isMenu: Bool { if case .menu = self { return true }; return false }
}

enum PluginUIPhase: String, Sendable {
    case accepted, presenting, presented, registered, dismissing, closed, failed
}

struct PluginUIState: Equatable, Sendable {
    let id: UUID
    let pluginId: String
    var scope: PluginUIScope
    let kind: String
    var phase: PluginUIPhase
    var isPresented = false
    var hasAppeared = false
    var revision: Int64 = 0
    var reason: String?
    var error: PluginUIFailure?
    var values: [String: PluginUIJSON] = [:]
    var valueByteCount = 0

    var json: PluginUIJSON {
        return .object([
            "id": .string(self.id.uuidString), "kind": .string(self.kind),
            "phase": .string(self.phase.rawValue), "visible": .bool(self.isPresented),
            "isPresented": .bool(self.isPresented), "revision": .integer(self.revision),
            "reason": self.reason.map(PluginUIJSON.string) ?? .null,
            "error": self.error?.json ?? .null, "values": .object(self.values),
            "accountRecordId": .integer(self.scope.accountRecordId), "scope": .string(self.scope.id.uuidString)
        ])
    }

    var callbackMetadata: [String: PluginUIJSON] {
        return ["_uiPlugin": .string(self.pluginId), "_uiScope": .string(self.scope.id.uuidString), "_uiLease": .string(self.id.uuidString), "_uiRevision": .integer(self.revision)]
    }
}

/// The lock protects data only. UIKit and reverse callbacks are never called
/// under it. Owner is generic so the exact shipping lifecycle runs in fixtures
/// without constructing an interpreter, account, window or network stack.
final class PluginUILeaseStore<Owner: Hashable & Sendable>: @unchecked Sendable {
    struct Entry: Sendable {
        let owner: Owner
        var state: PluginUIState
        var content: PluginUILeaseContent
        let callbacks: [String: PluginUICallback]
        let permissionIsCurrent: @Sendable () -> Bool
        var terminalActionDelivered = false
        var settingsUpdate: PluginUISettingsUpdate?
    }

    struct Delivery: Sendable {
        let owner: Owner
        let handle: Int64
        let arguments: PluginUIJSON
        let permissionIsCurrent: @Sendable () -> Bool
        init(owner: Owner, handle: Int64, arguments: PluginUIJSON,
             permissionIsCurrent: @escaping @Sendable () -> Bool = { true }) {
            self.owner = owner; self.handle = handle; self.arguments = arguments
            self.permissionIsCurrent = permissionIsCurrent
        }
    }

    struct Retirement: Sendable {
        let id: UUID
        let pluginId: String
        let owner: Owner
        let handles: [Int64]
        let deliveries: [Delivery]
        let isMenu: Bool
    }

    struct Cleanup: Sendable {
        let id: UUID?
        let changed: Bool
        let retirement: Retirement?
    }

    struct Limits: Sendable {
        var presentationsPerPlugin = 16
        var presentations = 128
        var menusPerPlugin = 64
        var menus = 512
        var terminalHistory = 256
        var valueBytes = 256 * 1024
    }

    private let lock = NSLock()
    private let limits: Limits
    private var scope: PluginUIScope?
    private var entries: [UUID: Entry] = [:]
    private var handles: [Owner: Set<Int64>] = [:]
    private var retiring: [UUID: Retirement] = [:]
    private var history: [UUID: PluginUIState] = [:]
    private var historyOwners: [UUID: Owner] = [:]
    private var historyOrder: [UUID] = []

    init(limits: Limits = Limits()) { self.limits = limits }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return try body()
    }

    var currentScope: PluginUIScope? { return self.locked { self.scope } }
    var liveCount: Int { return self.locked { self.entries.count } }

    /// A new UUID even for the same account record prevents an A -> B -> A
    /// switch from resurrecting actions captured in A's old navigation stack.
    func replaceScope(accountRecordId: Int64?) -> [Retirement] {
        return self.locked {
            let expired = self.entries.values.filter { !$0.content.isMenu }.map { $0.state.id }
            var retired = expired.sorted { $0.uuidString < $1.uuidString }.compactMap {
                self.retireLocked($0, reason: "accountChanged", notify: false, failure: nil)
            }
            self.scope = accountRecordId.map { PluginUIScope(id: UUID(), accountRecordId: $0) }
            // Original menu registrations belong to the plugin lifetime, not
            // one account. Hide them while there is no account; rebind on a new
            // scope and invalidate every previously rendered menu snapshot.
            if let scope = self.scope {
                for id in Array(self.entries.keys) {
                    guard var entry = self.entries[id], entry.content.isMenu else { continue }
                    if entry.state.revision == Int64.max {
                        if let value = self.retireLocked(id, reason: "revisionExhausted", notify: false, failure: nil) { retired.append(value) }
                    } else {
                        entry.state.scope = scope
                        entry.state.revision += 1
                        self.entries[id] = entry
                    }
                }
            }
            return retired
        }
    }

    func accept(pluginId: String, owner: Owner, content: PluginUILeaseContent, callbacks: [String: PluginUICallback], expectedScope: PluginUIScope? = nil, admission: () throws -> Void = {}, permissionIsCurrent: @escaping @Sendable () -> Bool = { true }) throws -> Entry {
        return try self.locked {
            try self.requireScopeLocked(expectedScope)
            try admission()
            guard permissionIsCurrent() else { throw PluginUIFailure.permission("UI permission admission expired") }
            return try self.acceptLocked(pluginId: pluginId, owner: owner, content: content, callbacks: callbacks, permissionIsCurrent: permissionIsCurrent)
        }
    }

    private func acceptLocked(pluginId: String, owner: Owner, content: PluginUILeaseContent, callbacks: [String: PluginUICallback], replacing: Set<UUID> = [], permissionIsCurrent: @escaping @Sendable () -> Bool = { true }) throws -> Entry {
        guard !pluginId.isEmpty else { throw PluginUIFailure.permission("Native plugin identity is required") }
        guard let scope = self.scope else { throw PluginUIFailure.unavailable("No active account UI") }
        guard !self.retiring.values.contains(where: { $0.owner == owner }) else {
            throw PluginUIFailure.unavailable("Owner callback cleanup is awaiting FIFO admission")
        }
        if case let .presentation(model) = content { try model.validateCallbacks(Set(callbacks.keys)) }
        let remaining = self.entries.values.filter { !replacing.contains($0.state.id) && $0.content.isMenu == content.isMenu }
        let ownerCount = remaining.filter { $0.state.pluginId == pluginId }.count
        let retiringCount = self.retiring.values.filter { $0.isMenu == content.isMenu }.count
        guard remaining.count + retiringCount < (content.isMenu ? self.limits.menus : self.limits.presentations),
              ownerCount < (content.isMenu ? self.limits.menusPerPlugin : self.limits.presentationsPerPlugin) else {
            throw PluginUIFailure.unavailable("Native UI lease limit reached")
        }
        let incomingHandles = Set(callbacks.values.map { $0.handle })
        guard incomingHandles.isDisjoint(with: self.handles[owner] ?? []) else {
            throw PluginUIFailure.invalidHandle("Callback handle is already leased; use distinct UI wrappers per presentation/registration")
        }
        let id = UUID()
        var state = PluginUIState(id: id, pluginId: pluginId, scope: scope, kind: content.kind, phase: content.isMenu ? .registered : .accepted)
        if case let .presentation(model) = content {
            state.values = model.valueDefaults
            state.valueByteCount = try self.valueBytes(state.values)
            guard state.valueByteCount <= self.limits.valueBytes else { throw PluginUIFailure.malformed("Aggregate UI input values exceed their 256 KiB budget") }
        }
        let entry = Entry(owner: owner, state: state, content: content, callbacks: callbacks, permissionIsCurrent: permissionIsCurrent)
        self.entries[id] = entry
        self.handles[owner, default: []].formUnion(incomingHandles)
        return entry
    }

    func registerMenu(pluginId: String, owner: Owner, model: PluginUIMenuModel, callback: PluginUICallback, expectedScope: PluginUIScope? = nil, admission: () throws -> Void = {}) throws -> (entry: Entry, retired: [Retirement]) {
        return try self.locked {
            try self.requireScopeLocked(expectedScope)
            try admission()
            let replaced = Set(self.entries.values.compactMap { entry -> UUID? in
                guard entry.state.pluginId == pluginId, case let .menu(previous) = entry.content else { return nil }
                let matches = model.itemId.map { previous.itemId == $0 } ?? (previous == model)
                return matches ? entry.state.id : nil
            })
            let entry = try self.acceptLocked(pluginId: pluginId, owner: owner, content: .menu(model), callbacks: ["click": callback], replacing: replaced)
            let retired = replaced.compactMap { self.retireLocked($0, reason: "replaced", notify: false, failure: nil) }
            return (entry, retired)
        }
    }

    func menuId(pluginId: String, itemId: String) -> UUID? {
        return self.locked {
            return self.entries.values.first { entry in
                guard entry.state.pluginId == pluginId, case let .menu(model) = entry.content else { return false }
                return model.itemId == itemId
            }?.state.id
        }
    }

    func removeMenu(id: UUID, pluginId: String, owner: Owner, admission: () throws -> Void) throws -> Retirement? {
        return try self.locked {
            try admission()
            guard let entry = self.entries[id], entry.content.isMenu, entry.state.pluginId == pluginId, entry.owner == owner else {
                throw PluginUIFailure.invalidHandle("Menu removal targets an unknown or retired owner")
            }
            return self.retireLocked(id, reason: "removed", notify: false, failure: nil)
        }
    }

    /// C cleanup may arrive after Host removed the active callback owner. Its
    /// only authority is the immutable owner already stored on this resource.
    /// Validation and revocation are one locked operation; no current-owner
    /// lookup, account requirement, permission grant or new lease is involved.
    func revoke(reference: String, pluginId: String, menu: Bool, validateOwner: (Owner) throws -> Void) throws -> Cleanup {
        return try self.locked {
            guard !reference.isEmpty, reference.utf8.count <= 256 else { throw PluginUIFailure.invalidHandle("Invalid UI cleanup reference") }
            let alias = menu ? self.entries.values.first(where: { entry in
                guard entry.state.pluginId == pluginId, case let .menu(model) = entry.content else { return false }
                return model.itemId == reference
            })?.state.id : nil
            guard let id = alias ?? UUID(uuidString: reference) else {
                if menu { return Cleanup(id: nil, changed: false, retirement: nil) }
                throw PluginUIFailure.invalidHandle("UI dismissal requires a native UUID")
            }
            guard var entry = self.entries[id] else {
                if let old = self.history[id], let owner = self.historyOwners[id] {
                    guard old.pluginId == pluginId else { throw PluginUIFailure.permission("UI cleanup belongs to another plugin") }
                    try validateOwner(owner)
                    guard (old.kind == "menuRegistration") == menu else { throw PluginUIFailure.invalidHandle("Wrong UI cleanup operation") }
                } else if let old = self.retiring[id] {
                    guard old.pluginId == pluginId else { throw PluginUIFailure.permission("UI cleanup belongs to another plugin") }
                    try validateOwner(old.owner)
                    guard old.isMenu == menu else { throw PluginUIFailure.invalidHandle("Wrong UI cleanup operation") }
                }
                // Evicted/unknown terminal ids own no resource. Idempotent
                // cleanup must not make an otherwise healthy SDK unload fail.
                return Cleanup(id: id, changed: false, retirement: nil)
            }
            guard entry.state.pluginId == pluginId else { throw PluginUIFailure.permission("UI cleanup belongs to another plugin") }
            try validateOwner(entry.owner)
            guard entry.content.isMenu == menu else { throw PluginUIFailure.invalidHandle("Wrong UI cleanup operation") }
            if menu {
                return Cleanup(id: id, changed: true, retirement: self.retireLocked(id, reason: "removed", notify: false, failure: nil))
            }
            guard entry.state.phase != .dismissing else { return Cleanup(id: id, changed: false, retirement: nil) }
            entry.state.phase = .dismissing
            entry.state.isPresented = false
            entry.state.reason = "programmatic"
            self.entries[id] = entry
            return Cleanup(id: id, changed: true, retirement: nil)
        }
    }

    func entry(id: UUID, pluginId: String) throws -> Entry {
        return try self.locked {
            guard let entry = self.entries[id] else { throw PluginUIFailure.invalidHandle("Unknown or closed UI lease") }
            guard entry.state.pluginId == pluginId else { throw PluginUIFailure.permission("UI lease belongs to another plugin") }
            return entry
        }
    }

    func entry(id: UUID) -> Entry? { return self.locked { self.entries[id] } }

    func state(id: UUID, pluginId: String) throws -> PluginUIState {
        return try self.locked {
            guard let state = self.entries[id]?.state ?? self.history[id] else { throw PluginUIFailure.invalidHandle("Unknown UI lease (terminal history is bounded)") }
            guard state.pluginId == pluginId else { throw PluginUIFailure.permission("UI lease belongs to another plugin") }
            return state
        }
    }

    /// Recheck at owner-worker execution, after any dispatcher/worker queue wait.
    /// Closing bookkeeping may cross account changes; user actions may not.
    func permitsCallback(pluginId: String, metadata: [String: PluginUIJSON]) -> Bool {
        return self.locked {
            if metadata["event"] == .string("closed") { return true }
            guard metadata["_uiPlugin"] == .string(pluginId), let scope = self.scope, metadata["_uiScope"] == .string(scope.id.uuidString),
                  let idString = metadata["_uiLease"]?.string, let id = UUID(uuidString: idString) else { return false }
            guard let state = self.entries[id]?.state ?? self.history[id] else {
                // These markers are emitted only by native final decisions, after
                // updates became impossible. Bounded history eviction must not
                // cancel an admitted undo/commit/dismiss behind a full FIFO. The
                // provider still checks the exact owner and current account scope.
                return metadata["_uiFinal"] == .bool(true) || metadata["_uiTerminal"] == .bool(true)
            }
            guard state.pluginId == pluginId, state.scope == scope, metadata["_uiRevision"] == .integer(state.revision) else { return false }
            if state.kind == "menuRegistration" && state.phase != .registered { return false }
            return true
        }
    }

    func beginPresentation(id: UUID) -> Entry? {
        return self.locked {
            guard var entry = self.entries[id], entry.state.scope == self.scope, entry.state.phase == .accepted else { return nil }
            guard entry.permissionIsCurrent() else { return nil }
            entry.state.phase = .presenting
            self.entries[id] = entry
            return entry
        }
    }

    /// true is supplied only by an actual appearance observation with a window;
    /// neither uiPresent acceptance nor a queued main-thread block can set it.
    func observeVisibility(id: UUID, visible: Bool) -> Delivery? {
        return self.locked {
            guard var entry = self.entries[id], entry.state.scope == self.scope, !entry.content.isMenu else { return nil }
            guard entry.state.phase == .presenting || entry.state.phase == .presented else { return nil }
            let firstAppearance = visible && !entry.state.hasAppeared
            entry.state.isPresented = visible
            if visible {
                entry.state.phase = .presented
                entry.state.hasAppeared = true
            }
            self.entries[id] = entry
            return firstAppearance ? self.delivery(entry, name: "show", payload: [:]) : nil
        }
    }

    func reserveSettingsUpdate(id: UUID, pluginId: String, owner: Owner, patch: PluginUIJSON, request: PluginUIJSON,
                               expectedScope: PluginUIScope, admission: () throws -> Void) throws -> PluginUISettingsUpdate {
        return try self.locked {
            try self.requireScopeLocked(expectedScope)
            try admission()
            guard var entry = self.entries[id], entry.owner == owner, entry.state.pluginId == pluginId,
                  entry.state.scope == self.scope, entry.state.phase != .dismissing, entry.settingsUpdate == nil,
                  entry.permissionIsCurrent(), case let .presentation(model) = entry.content else {
                throw PluginUIFailure.invalidHandle("Settings update requires its current, idle presentation owner")
            }
            let candidate = try model.applying(patch)
            let update = try PluginUISettingsUpdate(request, previous: model, candidate: candidate, revision: entry.state.revision)
            guard entry.callbacks.count < 128, !(self.handles[owner] ?? []).contains(update.completion.handle) else {
                throw PluginUIFailure.invalidHandle("Settings completion must be a unique bounded callback lease")
            }
            entry.settingsUpdate = update
            self.entries[id] = entry
            self.handles[owner, default: []].insert(update.completion.handle)
            return update
        }
    }

    /// Settles only the reserved update. Failure before commit leaves S1's model,
    /// revision, visibility and callbacks intact. Completion retains its credit
    /// through the same ACK/release retirement queue as other native controls.
    func finishSettingsUpdate(id: UUID, updateId: UUID, failure: PluginUIFailure? = nil) -> Retirement? {
        return self.locked {
            guard var entry = self.entries[id], var update = entry.settingsUpdate, update.id == updateId,
                  self.retiring[updateId] == nil else { return nil }
            let committed = update.committed == true
            update.committed = committed
            entry.settingsUpdate = update
            self.entries[id] = entry
            var event = entry.state.callbackMetadata
            event["id"] = .string(id.uuidString)
            event["event"] = .string("settingsUpdate")
            event["_uiTerminal"] = .bool(true)
            event["updateId"] = .string(update.id.uuidString)
            event["previousSnapshotId"] = .string(update.previousSnapshotId)
            event["snapshotId"] = .string(update.snapshotId)
            event["committed"] = .bool(committed)
            if !committed, let failure {
                event["error"] = PluginUIFailure(kind: failure.kind, message: String(failure.message.prefix(2048))).json
            }
            let delivery = Delivery(owner: entry.owner, handle: update.completion.handle, arguments: .array([.object(event)]),
                permissionIsCurrent: entry.permissionIsCurrent)
            let retirement = Retirement(id: update.id, pluginId: entry.state.pluginId, owner: entry.owner,
                handles: [update.completion.handle], deliveries: [delivery], isMenu: false)
            self.retiring[update.id] = retirement
            return retirement
        }
    }

    func update(id: UUID, pluginId: String, patch: PluginUIJSON, expectedScope: PluginUIScope? = nil,
                settingsUpdateId: UUID? = nil, admission: () throws -> Void = {}) throws -> Entry {
        return try self.locked {
            try self.requireScopeLocked(expectedScope)
            try admission()
            guard var entry = self.entries[id], entry.state.pluginId == pluginId, entry.state.scope == self.scope else {
                throw PluginUIFailure.invalidHandle("UI update targets an unknown or outdated lease")
            }
            guard entry.state.phase != .dismissing, case let .presentation(model) = entry.content else {
                throw PluginUIFailure.invalidHandle("UI lease is closing or is a persistent menu registration")
            }
            guard entry.state.revision < Int64.max else { throw PluginUIFailure.unavailable("UI revision exhausted") }
            let updated = try model.applying(patch)
            if model.raw["settingsSnapshotId"] != nil || updated.raw["settingsSnapshotId"] != nil {
                guard let ticket = entry.settingsUpdate, ticket.id == settingsUpdateId, entry.permissionIsCurrent() else {
                    throw PluginUIFailure.invalidHandle("Settings snapshots require their reserved native commit")
                }
                try ticket.check(previous: model, candidate: updated, revision: entry.state.revision)
            } else if settingsUpdateId != nil {
                throw PluginUIFailure.invalidHandle("Unexpected settings update transaction")
            }
            try updated.validateCallbacks(Set(entry.callbacks.keys))
            let previous = model.valueDefaults
            var values = updated.valueDefaults
            for (key, value) in values where previous[key] == value {
                if let current = entry.state.values[key] { values[key] = current }
            }
            let bytes = try self.valueBytes(values)
            guard bytes <= self.limits.valueBytes else { throw PluginUIFailure.malformed("Aggregate UI input values exceed their 256 KiB budget") }
            entry.state.values = values
            entry.state.valueByteCount = bytes
            entry.content = .presentation(updated)
            entry.state.revision += 1
            if settingsUpdateId != nil { entry.settingsUpdate?.committed = true }
            self.entries[id] = entry
            return entry
        }
    }

    /// Claim before scheduling a callback or navigating. The rendered revision,
    /// account scope, visible native controller and accepted owner must all agree.
    func action(id: UUID, revision: Int64, scope: PluginUIScope, name: String, payload: [String: PluginUIJSON], dismissReason: String? = nil) -> (accepted: Bool, delivery: Delivery?) {
        return self.locked {
            guard var entry = self.entries[id], scope == self.scope, entry.state.scope == scope,
                  entry.state.revision == revision,
                  (entry.content.isMenu && entry.state.phase == .registered) || (entry.state.phase == .presented && entry.state.isPresented) else {
                return (false, nil)
            }
            guard entry.permissionIsCurrent() else { return (false, nil) }
            guard entry.settingsUpdate?.committed != true else { return (false, nil) }
            if let key = payload["key"]?.string, let value = payload["value"] {
                guard let previous = entry.state.values[key],
                      let oldCost = try? self.valueCost(key: key, value: previous),
                      let newCost = try? self.valueCost(key: key, value: value),
                      entry.state.valueByteCount - oldCost + newCost <= self.limits.valueBytes else { return (false, nil) }
                entry.state.valueByteCount += newCost - oldCost
                entry.state.values[key] = value
            }
            if let dismissReason {
                entry.state.phase = .dismissing
                entry.state.isPresented = false
                entry.state.reason = dismissReason
                entry.terminalActionDelivered = name == "action" || name == "undo"
            }
            self.entries[id] = entry
            var event = payload
            if dismissReason != nil && !entry.content.isMenu { event["_uiFinal"] = .bool(true) }
            return (true, self.delivery(entry, name: name, payload: event))
        }
    }

    /// Programmatic/native cancellation is also allowed before appearance. A
    /// queued show subsequently sees .dismissing and cannot resurrect the lease.
    func beginDismiss(id: UUID, pluginId: String, reason: String, callbackName: String? = nil, payload: [String: PluginUIJSON] = [:], admission: () throws -> Void = {}) throws -> (changed: Bool, delivery: Delivery?) {
        return try self.locked {
            try admission()
            guard var entry = self.entries[id] else {
                if let old = self.history[id], old.pluginId == pluginId { return (false, nil) }
                throw PluginUIFailure.invalidHandle("Unknown UI lease")
            }
            guard entry.state.pluginId == pluginId else { throw PluginUIFailure.permission("UI lease belongs to another plugin") }
            guard entry.state.phase != .dismissing else { return (false, nil) }
            entry.state.phase = .dismissing
            entry.state.isPresented = false
            entry.state.reason = reason
            entry.terminalActionDelivered = callbackName == "action" || callbackName == "undo"
            self.entries[id] = entry
            var event = payload
            event["reason"] = .string(reason)
            if !entry.content.isMenu { event["_uiFinal"] = .bool(true) }
            return (true, callbackName.flatMap { self.delivery(entry, name: $0, payload: event) })
        }
    }

    func finish(id: UUID, reason: String? = nil, notify: Bool = true, failure: PluginUIFailure? = nil) -> Retirement? {
        return self.locked { self.retireLocked(id, reason: reason, notify: notify, failure: failure) }
    }

    /// Keep callback handles and quota reserved until every terminal callback and
    /// its release have entered the same owner's FIFO, or Host retired that owner.
    func completeRetirement(id: UUID, owner: Owner) {
        self.locked {
            guard let retirement = self.retiring[id], retirement.owner == owner else { return }
            self.retiring.removeValue(forKey: id)
            for presentationId in Array(self.entries.keys) {
                if self.entries[presentationId]?.owner == owner, self.entries[presentationId]?.settingsUpdate?.id == id {
                    self.entries[presentationId]?.settingsUpdate = nil
                }
            }
            self.handles[owner]?.subtract(retirement.handles)
            if self.handles[owner]?.isEmpty == true { self.handles.removeValue(forKey: owner) }
        }
    }

    func refresh(id: UUID) -> Delivery? {
        return self.locked {
            guard let entry = self.entries[id], entry.state.scope == self.scope,
                  entry.state.phase != .dismissing else { return nil }
            return self.delivery(entry, name: "refresh", payload: [:])
        }
    }

    func release(pluginId: String) -> [Retirement] {
        return self.locked {
            let ids = self.entries.values.filter { $0.state.pluginId == pluginId }.map { $0.state.id }
            return ids.compactMap { self.retireLocked($0, reason: "unload", notify: false, failure: nil) }
        }
    }

    func retirePermissions(pluginId: String) -> [Retirement] {
        self.locked {
            let ids = self.entries.values.filter { $0.state.pluginId == pluginId && !$0.permissionIsCurrent() }.map { $0.state.id }
            return ids.compactMap {
                self.retireLocked($0, reason: "permissionsChanged", notify: true,
                    failure: .permission("Plugin access was reduced"))
            }
        }
    }

    func menus() -> [Entry] {
        return self.locked {
            return self.entries.values.filter { $0.content.isMenu && $0.state.scope == self.scope && $0.state.phase == .registered }.sorted { lhs, rhs in
                guard case let .menu(l) = lhs.content, case let .menu(r) = rhs.content else { return false }
                if l.priority != r.priority { return l.priority > r.priority }
                if lhs.state.pluginId != rhs.state.pluginId { return lhs.state.pluginId < rhs.state.pluginId }
                return (l.itemId ?? lhs.state.id.uuidString) < (r.itemId ?? rhs.state.id.uuidString)
            }
        }
    }

    private func delivery(_ entry: Entry, name: String, payload: [String: PluginUIJSON]) -> Delivery? {
        guard let callback = entry.callbacks[name] else { return nil }
        var event = payload
        for (key, value) in entry.state.callbackMetadata { event[key] = value }
        event.removeValue(forKey: "_uiSettingsSnapshot")
        if case let .presentation(model) = entry.content, let snapshot = model.raw["settingsSnapshotId"] {
            event["_uiSettingsSnapshot"] = snapshot
        }
        event["id"] = .string(entry.state.id.uuidString)
        event["event"] = .string(name)
        let permission: @Sendable () -> Bool
        if name == "closed" {
            permission = { true }
        } else {
            permission = entry.permissionIsCurrent
        }
        return Delivery(owner: entry.owner, handle: callback.handle, arguments: .array([.object(event)]), permissionIsCurrent: permission)
    }

    private func valueCost(key: String, value: PluginUIJSON) throws -> Int {
        return try PluginUIJSON.string(key).encoded().utf8.count + value.encoded().utf8.count + 2
    }

    private func requireScopeLocked(_ expected: PluginUIScope?) throws {
        if let expected, self.scope != expected { throw PluginUIFailure.invalidHandle("UI account changed before native admission") }
    }

    private func valueBytes(_ values: [String: PluginUIJSON]) throws -> Int {
        var count = 2
        for (key, value) in values { count += try self.valueCost(key: key, value: value) }
        return count
    }

    private func retireLocked(_ id: UUID, reason: String?, notify: Bool, failure: PluginUIFailure?) -> Retirement? {
        guard var entry = self.entries.removeValue(forKey: id) else { return nil }
        entry.state.phase = failure == nil ? .closed : .failed
        entry.state.isPresented = false
        entry.state.reason = reason ?? entry.state.reason ?? "nativeDismissal"
        entry.state.error = failure
        // History records lifecycle, not sensitive input drafts or unbounded
        // accumulated values from pages that have already been replaced/closed.
        entry.state.values.removeAll()
        entry.state.valueByteCount = 0
        var handles = Set(entry.callbacks.values.map { $0.handle })
        if let update = entry.settingsUpdate, self.retiring[update.id] == nil {
            handles.insert(update.completion.handle)
        }
        self.history[id] = entry.state
        self.historyOwners[id] = entry.owner
        self.historyOrder.append(id)
        while self.historyOrder.count > max(0, self.limits.terminalHistory) {
            let expired = self.historyOrder.removeFirst()
            self.history.removeValue(forKey: expired)
            self.historyOwners.removeValue(forKey: expired)
        }
        var deliveries: [Delivery] = []
        if notify && !entry.content.isMenu {
            var payload: [String: PluginUIJSON] = ["reason": .string(entry.state.reason ?? "nativeDismissal"), "_uiTerminal": .bool(true)]
            if notify, let failure {
                // Reserved dispatcher controls are at most 16 KiB. Terminal
                // payloads contain no input values and keep a bounded diagnostic.
                payload["error"] = PluginUIFailure(kind: failure.kind, message: String(failure.message.prefix(2048))).json
                if let delivery = self.delivery(entry, name: "error", payload: payload) { deliveries.append(delivery) }
            } else if notify && entry.state.hasAppeared {
                if case let .presentation(model) = entry.content, model.kind.isTransient, model.style == "undo", !entry.terminalActionDelivered,
                   let delivery = self.delivery(entry, name: "action", payload: payload) { deliveries.append(delivery) }
                if let delivery = self.delivery(entry, name: "dismiss", payload: payload) { deliveries.append(delivery) }
            }
            if let delivery = self.delivery(entry, name: "closed", payload: payload) { deliveries.append(delivery) }
        }
        let retirement = Retirement(id: id, pluginId: entry.state.pluginId, owner: entry.owner, handles: handles.sorted(), deliveries: deliveries, isMenu: entry.content.isMenu)
        if !handles.isEmpty { self.retiring[id] = retirement }
        return retirement
    }
}
