import AccountContext
import Display
import Foundation
import PluginHost
import TelegramCore
import UIKit
import UniformTypeIdentifiers

/// Runtime UI extension. Synchronous dispatch validates/captures the native
/// owner; UIKit is confined to main, Python invocation/release to injected FIFO
/// owner-queue closures. Never resolve a delayed action by plugin id alone.
public final class PluginUIBridgeExtension: PluginBridgeExtension, @unchecked Sendable {
    public let exportedMethods: [String: Set<String>] = [PluginUIRequest.runtime: PluginUIRequest.members]
    public static let menuItemsDidChange = Notification.Name("ExteralessNativePluginMenuItemsDidChange")
    public typealias CaptureOwner = @Sendable (String) -> PluginHost.CallbackOwner?
    public typealias Callback = @Sendable (PluginHost.CallbackOwner, Int64, String, String) -> Bool
    public typealias ControlledCallback = @Sendable (PluginHost.CallbackOwner, Int64, String, String, @escaping @Sendable () -> Bool) -> Bool
    public typealias Release = @Sendable (PluginHost.CallbackOwner, [Int64]) -> Bool
    public typealias Permission = @Sendable (String, PluginPermission) -> Bool
    public typealias AccountIndex = @Sendable (Int64) -> Int32?
    public typealias SettingsController = @MainActor (AccountContext, String, String, [String]) -> ViewController?
    public typealias Presenter = @MainActor (AccountContext) -> ViewController?
    public typealias ResolveShareFile = @Sendable (String, String) throws -> URL
    public typealias ClassifyShareFile = @Sendable (String, String) throws -> PluginResourcePath
    public typealias SchedulePresentation = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    typealias LinkInterceptor = @MainActor (URL, @escaping @MainActor () -> Void) -> Bool
    typealias LinkOpener = @MainActor (URL, @escaping @Sendable () -> Void) -> Void

    typealias Store = PluginUILeaseStore<PluginHost.CallbackOwner>
    let leases: Store
    let captureOwner: CaptureOwner
    let hasPermission: Permission
    let accountIndex: AccountIndex
    private let deliveryCallback: @Sendable (Store.Delivery) -> Bool
    private let permissionAdmission: PluginPermissionAdmission
    private let releaseQueue: PluginUIReleaseQueue<PluginHost.CallbackOwner>
    private let settingsController: SettingsController
    private let presenter: Presenter?
    private let resolveShareFile: ResolveShareFile?
    private let classifyShareFile: ClassifyShareFile?
    private let schedulePresentation: SchedulePresentation
    private let effectBudget: PluginNativeEffectBudget
    private let menuUpdateLock = NSLock()
    private var menuUpdateScheduled = false

    // Every access to these UIKit/AccountContext values is on main. Keeping the
    // dispatch object nonisolated is required by the synchronous C bridge.
    @MainActor private(set) var accountContext: AccountContext?
    @MainActor private var presentations: [UUID: NativePresentation] = [:]
    @MainActor private var screens: [UUID: WeakScreen] = [:]
    @MainActor private var screenOrder: [UUID] = []

    public init(captureOwner: @escaping CaptureOwner, callback: @escaping Callback,
                release: @escaping Release, hasPermission: @escaping Permission,
                accountIndex: @escaping AccountIndex, settingsController: @escaping SettingsController,
                presenter: Presenter? = nil, resolveShareFile: ResolveShareFile? = nil,
                effectBudget: PluginNativeEffectBudget = PluginNativeEffectBudget(),
                permissionAdmission: PluginPermissionAdmission? = nil,
                controlledCallback: ControlledCallback? = nil,
                classifyShareFile: ClassifyShareFile? = nil,
                schedulePresentation: @escaping SchedulePresentation = { work in DispatchQueue.main.async { work() } }) {
        self.captureOwner = captureOwner
        self.permissionAdmission = permissionAdmission ?? { id, required in
            { required.allSatisfy { hasPermission(id, $0) } }
        }
        let deliveryCallback: @Sendable (Store.Delivery) -> Bool = { delivery in
            guard let json = try? delivery.arguments.encoded() else { return false }
            if let controlledCallback {
                return controlledCallback(delivery.owner, delivery.handle, "__call__", json, delivery.permissionIsCurrent)
            }
            // Legacy synchronous native fixture transport: a revoked body is
            // consumed, not retried forever ahead of its owner-FIFO release.
            guard delivery.permissionIsCurrent() else { return true }
            return callback(delivery.owner, delivery.handle, "__call__", json)
        }
        self.deliveryCallback = deliveryCallback
        let leases = Store()
        self.leases = leases
        self.releaseQueue = PluginUIReleaseQueue(isCurrent: { captureOwner($0.pluginId) == $0 }, callback: deliveryCallback, release: release, completed: { retirement in
            leases.completeRetirement(id: retirement.id, owner: retirement.owner)
        })
        self.hasPermission = hasPermission
        self.accountIndex = accountIndex
        self.settingsController = settingsController
        self.presenter = presenter
        self.resolveShareFile = resolveShareFile
        self.classifyShareFile = classifyShareFile
        self.schedulePresentation = schedulePresentation
        self.effectBudget = effectBudget
    }

    @MainActor public func update(context: AccountContext) {
        guard self.accountContext !== context else { return }
        self.clearContext()
        self.accountContext = context
        let retired = self.leases.replaceScope(accountRecordId: context.account.id.int64)
        for retirement in retired { self.retire(retirement) }
        self.notifyMenuChanges()
    }

    @MainActor public func clearContext() {
        let retired = self.leases.replaceScope(accountRecordId: nil)
        self.accountContext = nil
        self.screens.removeAll()
        self.screenOrder.removeAll()
        for retirement in retired {
            self.retire(retirement)
            self.removeNative(id: retirement.id, animated: false)
        }
        self.notifyMenuChanges()
    }

    public func releaseInstances(pluginId: String) {
        // Invalidate synchronously. A tap racing the subsequent main hop cannot
        // claim an action, and a new lifetime's UI is not removed by plugin id.
        let retired = self.leases.release(pluginId: pluginId)
        for retirement in retired { self.retire(retirement) }
        self.notifyMenuChanges()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for retirement in retired { self.removeNative(id: retirement.id, animated: false) }
        }
    }

    public func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        do {
            guard let request = try PluginUIRequest.claimed(requestJSON), let member = request["member"]?.string else { return nil }
            let operation = request["op"]?.string ?? ""
            let args = try request.uiArray("args", limit: 4)
            if let kwargs = request["kwargs"], kwargs != .null {
                guard let object = kwargs.object, object.isEmpty else { throw PluginUIFailure.malformed("UI Runtime methods take positional arguments only") }
            }
            guard request["instance"] == nil || request["instance"] == .null,
                  request["value"] == nil || request["value"] == .null else {
                throw PluginUIFailure.malformed("UI Runtime operations are static methods")
            }
            if operation == "member_kind" {
                guard args.isEmpty else { throw PluginUIFailure.malformed("member_kind does not take args") }
                return try self.reply(.string("method"))
            }
            guard operation == "call" else {
                throw PluginUIFailure(kind: "JavaMemberError", message: "\(member) is a native method, not a field or constructor")
            }
            guard !pluginId.isEmpty else { throw PluginUIFailure.permission("Native interpreter identity is required") }
            let origin = try PluginUIRequestOrigin(request)
            if member == "uiDismiss" || member == "menuRemove" {
                return try self.reply(self.cleanup(member, args: args, pluginId: pluginId, origin: origin))
            }
            let acceptedOwner = try self.owner(pluginId, origin: origin)
            try self.require(.ui, pluginId: pluginId)
            // This runs on the originating C worker, before any main/readback
            // hop. The shared constructor retains Host batch revocation.
            // Account checks live in the store/retained effect, outside this
            // closure, so admission can call it under the store's own lock.
            let execution = PluginNativeCallLease { [weak self] in
                guard let self else { return false }
                return self.captureOwner(pluginId) == acceptedOwner && self.hasPermission(pluginId, .ui)
            }
            try execution.check()
            let value = try self.call(member, args: args, pluginId: pluginId, origin: origin, acceptedOwner: acceptedOwner, execution: execution)
            return try self.reply(value)
        } catch let error as PluginUIFailure {
            return try PluginUIJSON.object(["ok": .bool(false), "error": error.json]).encoded()
        } catch let error as BridgeFailure {
            return try PluginUIJSON.object(["ok": .bool(false), "error": PluginUIFailure(kind: error.kind, message: error.description).json]).encoded()
        } catch {
            return try PluginUIJSON.object(["ok": .bool(false), "error": PluginUIFailure.malformed("Invalid native UI request").json]).encoded()
        }
    }

    private func reply(_ value: PluginUIJSON) throws -> String { return try PluginUIJSON.object(["ok": .bool(true), "value": value]).encoded() }

    private func call(_ member: String, args: [PluginUIJSON], pluginId: String, origin: PluginUIRequestOrigin, acceptedOwner: PluginHost.CallbackOwner, execution: PluginNativeCallLease) throws -> PluginUIJSON {
        func arity(_ count: Int) throws {
            guard args.count == count else { throw PluginUIFailure.malformed("\(member) expects \(count) arguments") }
        }
        func id(_ value: PluginUIJSON) throws -> UUID {
            guard let string = value.string, let id = UUID(uuidString: string) else { throw PluginUIFailure.invalidHandle("Expected a native UI UUID") }
            return id
        }
        switch member {
        case "uiPresent":
            try arity(3)
            guard let name = args[0].string, let kind = PluginUIPresentationKind(rawValue: name) else { throw PluginUIFailure.unsupported("Unknown native UI presentation kind") }
            let model = try PluginUIModel(kind: kind, value: args[1])
            let callbacks = try PluginUICallback.map(args[2])
            let scope = try self.scope()
            try self.requireModelPermissions(model, pluginId: pluginId)
            let resources = try self.admitModelResources(model, pluginId: pluginId)
            let effect = try self.retainedEffect(owner: acceptedOwner, scope: scope, execution: execution,
                bytes: args[1].encoded().utf8.count + resources.files.reduce(0) { $0 + $1.url.path.utf8.count },
                permissionIsCurrent: resources.permissionIsCurrent)
            try self.validateAssets(model, effect: effect, scope: scope)
            let entry = try self.leases.accept(pluginId: pluginId, owner: acceptedOwner, content: .presentation(model), callbacks: callbacks,
                expectedScope: scope, admission: { try self.validateNewLease(origin, owner: acceptedOwner, execution: execution) },
                permissionIsCurrent: resources.permissionIsCurrent)
            self.enqueuePresentation(entry.state.id, effect: effect, shareFiles: resources.files)
            return .object(["id": .string(entry.state.id.uuidString)])
        case "uiUpdate":
            guard args.count == 2 || args.count == 3 else { throw PluginUIFailure.malformed("uiUpdate expects model and optional settings transaction") }
            let uuid = try id(args[0])
            let previous = try self.leases.entry(id: uuid, pluginId: pluginId)
            guard previous.owner == acceptedOwner else { throw PluginUIFailure.invalidHandle("UI update belongs to another interpreter lifetime") }
            try self.requireOwner(previous)
            guard previous.state.phase != .dismissing, case let .presentation(previousModel) = previous.content else {
                throw PluginUIFailure.invalidHandle("uiUpdate requires an open presentation lease")
            }
            let patch = args[1]
            let scope = previous.state.scope
            let candidate = try previousModel.applying(patch)
            try candidate.validateCallbacks(Set(previous.callbacks.keys))
            let effect = try self.retainedEffect(owner: acceptedOwner, scope: scope, execution: execution,
                bytes: patch.encoded().utf8.count + PluginUIJSON.object(candidate.raw).encoded().utf8.count,
                additionalPermissions: self.modelPermissions(candidate, pluginId: pluginId))
            try self.validateAssets(candidate, effect: effect, scope: scope)
            try self.validateOrigin(origin, owner: acceptedOwner, execution: execution)
            let settingsUpdate: PluginUISettingsUpdate?
            if args.count == 3 {
                settingsUpdate = try self.leases.reserveSettingsUpdate(id: uuid, pluginId: pluginId, owner: acceptedOwner,
                    patch: patch, request: args[2], expectedScope: scope,
                    admission: { try self.validateOrigin(origin, owner: acceptedOwner, execution: execution) })
            } else {
                guard previousModel.raw["settingsSnapshotId"] == nil else {
                    throw PluginUIFailure.invalidHandle("Settings snapshot update requires a native completion lease")
                }
                settingsUpdate = nil
            }
            // No committed model/revision is changed on the C worker. A revoked
            // queued patch cannot leak into a later independent partial update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { effect.finish(); return }
                self.applyUpdate(id: uuid, pluginId: pluginId, owner: acceptedOwner, scope: scope,
                    patch: patch, origin: origin, execution: execution, effect: effect, settingsUpdateId: settingsUpdate?.id)
            }
            return settingsUpdate.map { .object(["id": .string($0.id.uuidString)]) } ?? .null
        case "uiState":
            try arity(1)
            let uuid = try id(args[0])
            try self.validateOrigin(origin, owner: acceptedOwner, execution: execution)
            if let entry = self.leases.entry(id: uuid), entry.owner != acceptedOwner { throw PluginUIFailure.invalidHandle("UI state belongs to another interpreter lifetime") }
            _ = try self.leases.state(id: uuid, pluginId: pluginId)
            return try PluginUIReadback.read { [weak self] in
                guard let self else { throw PluginUIFailure.unavailable("Native UI provider was released") }
                try self.validateOrigin(origin, owner: acceptedOwner, execution: execution)
                let state = try self.leases.state(id: uuid, pluginId: pluginId)
                var value = state.json.object ?? [:]
                let native = self.presentations[uuid]
                let actuallyPresented = state.phase == .presented && state.isPresented && native?.controller.viewIfLoaded?.window != nil && native?.controller.isBeingDismissed == false
                value["visible"] = .bool(actuallyPresented)
                value["isPresented"] = .bool(actuallyPresented)
                return .object(value)
            }
        case "menuRegister":
            try arity(2)
            let model = try PluginUIMenuModel(args[0])
            let callback = try PluginUICallback(args[1])
            let scope = try self.scope()
            let effect = try self.retainedEffect(owner: acceptedOwner, scope: scope, execution: execution, bytes: args[0].encoded().utf8.count)
            if let icon = model.icon {
                _ = try PluginUIReadback.read {
                    guard effect.permitsExecution else { throw PluginUIFailure.invalidHandle("Menu admission execution expired") }
                    _ = try PluginUIResources.image(icon)
                    return .null
                }
            }
            // Registration/replacement itself is the synchronous native commit.
            // The coalesced main notification only projects current registry data.
            let result = try self.leases.registerMenu(pluginId: pluginId, owner: acceptedOwner, model: model, callback: callback,
                expectedScope: scope, admission: { try self.validateNewLease(origin, owner: acceptedOwner, execution: execution) })
            effect.finish()
            for retirement in result.retired { self.retire(retirement) }
            self.notifyMenuChanges()
            return .object(["id": .string(result.entry.state.id.uuidString)])
        case "uiActiveFragment":
            try arity(0)
            try self.validateOrigin(origin, owner: acceptedOwner, execution: execution)
            let scope = try self.scope()
            return try PluginUIReadback.read { [weak self] in
                try execution.check()
                guard let self, self.isCurrent(owner: acceptedOwner, scope: scope), let context = self.accountContext,
                      let controller = self.currentPresenter(context), controller.viewIfLoaded?.window != nil,
                      let account = self.accountIndex(scope.accountRecordId) else { return .null }
                let id = self.screenId(controller, scope: scope)
                return .object(["id": .string(id.uuidString), "scope": .string(scope.id.uuidString), "title": .string(controller.title ?? ""),
                    "kind": .string(controller is ChatController ? "chat" : (controller is PluginSettingsController ? "settings" : "screen")),
                    "account": .integer(Int64(account)), "accountRecordId": .integer(scope.accountRecordId), "isPresented": .bool(true)])
            }
        case "uiNavigate":
            guard args.count == 1 || args.count == 2 else { throw PluginUIFailure.malformed("uiNavigate expects a route model and optional callbacks") }
            try self.require(.intents, pluginId: pluginId)
            let permissionCurrent = self.permissionAdmission(pluginId, [.ui, .intents])
            let scope = try self.scope()
            let effect = try self.retainedEffect(owner: acceptedOwner, scope: scope, execution: execution, bytes: args[0].encoded().utf8.count, intents: true)
            let callbacks: [String: PluginUICallback]
            if args.count == 2 { callbacks = try PluginUICallback.map(args[1]) } else { callbacks = [:] }
            guard var object = args[0].object else { throw PluginUIFailure.malformed("uiNavigate requires a page or route model") }
            let content: PluginUILeaseContent
            if object["route"] == .string("page") || object["route"] == .string("settings") || (object["route"] == nil && (object["rows"] != nil || object["type"] != nil)) {
                let kind: PluginUIPresentationKind = object["route"] == .string("settings") ? .settings : .page
                object.removeValue(forKey: "route")
                if object["type"] != nil {
                    let sourceId = object.removeValue(forKey: "sourceId")
                    object = ["rows": .array([.object(object)])]
                    if let sourceId { object["sourceId"] = sourceId }
                }
                content = .presentation(try PluginUIModel(kind: kind, value: .object(object)))
            } else { content = .navigation(try PluginUINavigationModel(args[0])) }
            if case let .presentation(model) = content { try self.validateAssets(model, effect: effect, scope: scope) }
            let entry = try self.leases.accept(pluginId: pluginId, owner: acceptedOwner, content: content, callbacks: callbacks,
                expectedScope: scope, admission: { try self.validateNewLease(origin, owner: acceptedOwner, execution: execution) },
                permissionIsCurrent: permissionCurrent)
            self.enqueuePresentation(entry.state.id, effect: effect)
            return .object(["id": .string(entry.state.id.uuidString)])
        case "uiRefreshSettings":
            try arity(0)
            try self.validateOrigin(origin, owner: acceptedOwner, execution: execution)
            let scope = try self.scope()
            let effect = try self.retainedEffect(owner: acceptedOwner, scope: scope, execution: execution, bytes: 0)
            DispatchQueue.main.async { [weak self] in
                defer { effect.finish() }
                guard let self, effect.permitsExecution, self.isCurrent(owner: acceptedOwner, scope: scope) else { return }
                PluginUISettingsRefresh.invalidate(pluginId: pluginId)
            }
            return .null
        case "addToClipboard", "openURL":
            try arity(1)
            guard let text = args[0].string, text.utf8.count <= 256 * 1024 else { throw PluginUIFailure.malformed("\(member) requires bounded text") }
            try self.validateOrigin(origin, owner: acceptedOwner, execution: execution)
            let scope = try self.scope()
            let url: URL?
            if member == "openURL" {
                try self.require(.intents, pluginId: pluginId)
                guard text.utf8.count <= 8192 else { throw PluginUIFailure.malformed("URL exceeds 8 KiB") }
                url = try PluginUIModel.validateURL(text)
            } else { url = nil }
            // Reserve before the producer can enqueue any main work. The URL
            // path retains both its source text and parsed absolute URL.
            let effect = try self.retainedEffect(owner: acceptedOwner, scope: scope, execution: execution,
                bytes: text.utf8.count + (url?.absoluteString.utf8.count ?? 0), intents: url != nil)
            DispatchQueue.main.async { [weak self] in
                guard let self, effect.permitsExecution else { effect.finish(); return }
                if let url {
                    guard self.hasPermission(pluginId, .intents), let context = self.accountContext else { effect.finish(); return }
                    let original: @MainActor () -> Void = { [weak self] in
                        guard let self, effect.permitsExecution, self.accountContext === context,
                              self.hasPermission(pluginId, .intents) else { effect.finish(); return }
                        UIApplication.shared.open(url, options: [:], completionHandler: { _ in effect.finish() })
                    }
                    if !NativeServiceOpenHooks.shared.interceptURL(context: context, url: url, original: original) { original() }
                    // Deferred barriers retain `original`/effect. Handled or
                    // cancelled barriers refund only when that closure is freed.
                } else {
                    defer { effect.finish() }
                    UIPasteboard.general.string = text
                }
            }
            return .null
        default: throw PluginUIFailure(kind: "JavaMemberError", message: "Unknown native UI operation: \(member)")
        }
    }

    private func cleanup(_ member: String, args: [PluginUIJSON], pluginId: String, origin: PluginUIRequestOrigin) throws -> PluginUIJSON {
        guard args.count == 1, let reference = args[0].string else { throw PluginUIFailure.malformed("\(member) requires one native UI reference") }
        let menu = member == "menuRemove"
        let result = try self.leases.revoke(reference: reference, pluginId: pluginId, menu: menu, validateOwner: { owner in
            guard owner.pluginId == pluginId else { throw PluginUIFailure.permission("UI cleanup belongs to another plugin") }
            try origin.validate(currentToken: owner.wireToken)
        })
        if let retirement = result.retirement { self.retire(retirement) }
        if result.changed {
            if menu { self.notifyMenuChanges() }
            else if let id = result.id {
                DispatchQueue.main.async { [weak self] in self?.dismissPresentation(id: id, animated: true) }
            }
        }
        return .null
    }

    private func require(_ permission: PluginPermission, pluginId: String) throws {
        guard self.hasPermission(pluginId, permission) else { throw PluginUIFailure.permission("Native UI requires \(permission.rawValue)") }
    }

    private func owner(_ pluginId: String, origin: PluginUIRequestOrigin) throws -> PluginHost.CallbackOwner {
        guard let owner = self.captureOwner(pluginId), owner.pluginId == pluginId else { throw PluginUIFailure.unavailable("Plugin callback owner is no longer active") }
        try origin.validate(currentToken: owner.wireToken)
        return owner
    }

    /// Runs again under the UI store admission lock. Host retirement calls
    /// releaseInstances outside its state lock, so a retire/admit race cannot
    /// replace or remove a newer owner's menu while this snapshot is checked.
    private func validateOrigin(_ origin: PluginUIRequestOrigin, owner: PluginHost.CallbackOwner, execution: PluginNativeCallLease) throws {
        try execution.check()
        try origin.validate(currentToken: owner.wireToken)
        let current = self.captureOwner(owner.pluginId)
        try origin.validate(currentToken: current?.wireToken)
        guard current == owner else { throw PluginUIFailure.permission("Native UI owner changed during admission") }
    }

    private func validateNewLease(_ origin: PluginUIRequestOrigin, owner: PluginHost.CallbackOwner, execution: PluginNativeCallLease) throws {
        try self.validateOrigin(origin, owner: owner, execution: execution)
        // The lease store atomically reserves cleanup quota alongside admission.
    }

    private func scope() throws -> PluginUIScope {
        guard let scope = self.leases.currentScope else { throw PluginUIFailure.unavailable("No active account UI") }
        return scope
    }

    private func requireOwner(_ entry: Store.Entry) throws {
        guard entry.permissionIsCurrent() else { throw PluginUIFailure.permission("UI permission lease expired") }
        guard self.isCurrent(owner: entry.owner, scope: entry.state.scope) else { throw PluginUIFailure.invalidHandle("UI lease belongs to a retired plugin/account lifetime") }
    }

    func isCurrent(owner: PluginHost.CallbackOwner, scope: PluginUIScope) -> Bool {
        return self.captureOwner(owner.pluginId) == owner && self.leases.currentScope == scope && self.hasPermission(owner.pluginId, .ui)
    }

    /// Bind this as the callback dispatcher's final owner-worker admission guard.
    /// An owner token alone does not detect an account switch in the same running
    /// interpreter. The coordinator must recheck here immediately before Python
    /// entry, not only when enqueueing on main (see handoff for the exact binding).
    public func callbackIsCurrent(owner: PluginHost.CallbackOwner, argumentsJSON: String) -> Bool {
        guard self.captureOwner(owner.pluginId) == owner,
              let value = try? PluginUIJSON.decode(argumentsJSON), let metadata = value.array?.first?.object else { return false }
        if metadata["event"] != .string("closed") && !self.hasPermission(owner.pluginId, .ui) { return false }
        return self.leases.permitsCallback(pluginId: owner.pluginId, metadata: metadata)
    }

    private func requireModelPermissions(_ model: PluginUIModel, pluginId: String) throws {
        try self.require(.ui, pluginId: pluginId)
        if model.kind == .share {
            try self.require(.intents, pluginId: pluginId)
            if !model.files.isEmpty && self.classifyShareFile == nil { throw PluginUIFailure.unavailable("Native share-file ownership classifier is not installed") }
        }
    }

    private func retainedEffect(owner: PluginHost.CallbackOwner, scope: PluginUIScope, execution: PluginNativeCallLease,
                                bytes: Int, intents: Bool = false, additionalPermissions: Set<PluginPermission> = [],
                                permissionIsCurrent: (@Sendable () -> Bool)? = nil) throws -> PluginUIRetainedEffect {
        let required: Set<PluginPermission> = intents ? [.ui, .intents] : [.ui]
        let permissionCurrent = permissionIsCurrent ?? self.permissionAdmission(owner.pluginId, required.union(additionalPermissions))
        return try PluginUIRetainedEffect(budget: self.effectBudget, pluginId: owner.pluginId, bytes: bytes, isCurrent: { [weak self] in
            guard let self else { return false }
            return execution.isCurrent && self.isCurrent(owner: owner, scope: scope)
                && permissionCurrent()
        })
    }

    private func modelPermissions(_ model: PluginUIModel, pluginId: String) -> Set<PluginPermission> {
        var required: Set<PluginPermission> = [.ui]
        if model.kind == .share {
            required.insert(.intents)
        }
        return required
    }

    struct ModelResources: Sendable {
        let files: [PluginResourcePath]
        let permissionIsCurrent: @Sendable () -> Bool
    }

    /// Runs on the originating C worker, before resource validation/main hops.
    /// Ownership determines dependencies; current grants never classify a path.
    func admitModelResources(_ model: PluginUIModel, pluginId: String) throws -> ModelResources {
        var required = self.modelPermissions(model, pluginId: pluginId)
        var files: [PluginResourcePath] = []
        if model.kind == .share && !model.files.isEmpty {
            guard let classify = self.classifyShareFile else { throw PluginUIFailure.unavailable("Native share-file ownership classifier is not installed") }
            files = try model.files.map { try classify(pluginId, $0) }
            if files.contains(where: \.requiresFiles) { required.insert(.files) }
        }
        let permissionCurrent = self.permissionAdmission(pluginId, required)
        guard permissionCurrent() else { throw PluginUIFailure.permission("Share permission admission expired or missing") }
        for file in files {
            let url = try file.validatedURL()
            if let resolve = self.resolveShareFile {
                guard try resolve(pluginId, url.path) == url else { throw PluginUIFailure.invalidHandle("Share resolver changed the admitted resource") }
            }
            guard permissionCurrent() else { throw PluginUIFailure.permission("Share permission expired during file validation") }
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw PluginUIFailure.unavailable("Shared file is missing or is not a regular file")
            }
        }
        guard permissionCurrent() else { throw PluginUIFailure.permission("Share permission expired before presentation admission") }
        return ModelResources(files: files, permissionIsCurrent: permissionCurrent)
    }

    public func permissionsChanged(pluginId: String) {
        let retired = self.leases.retirePermissions(pluginId: pluginId)
        for retirement in retired { self.retire(retirement) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for retirement in retired { self.removeNative(id: retirement.id, animated: false) }
        }
    }

    private func enqueuePresentation(_ id: UUID, effect: PluginUIRetainedEffect, shareFiles: [PluginResourcePath] = []) {
        self.schedulePresentation { [weak self] in
            guard let self else { effect.finish(); return }
            self.presentPending(id: id, effect: effect, shareFiles: shareFiles)
        }
    }

    private func validateAssets(_ model: PluginUIModel, effect: PluginUIRetainedEffect, scope: PluginUIScope) throws {
        _ = try PluginUIReadback.read { [weak self] in
            guard let self, effect.permitsExecution, self.leases.currentScope == scope,
                  let context = self.accountContext else { throw PluginUIFailure.unavailable("No current UI execution/context for resource resolution") }
            try PluginUIResources.validate(model, data: context.sharedContext.currentPresentationData.with { $0 })
            return .null
        }
    }

    private func notifyMenuChanges() {
        self.menuUpdateLock.lock()
        if self.menuUpdateScheduled { self.menuUpdateLock.unlock(); return }
        self.menuUpdateScheduled = true
        self.menuUpdateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuUpdateLock.lock()
            self.menuUpdateScheduled = false
            self.menuUpdateLock.unlock()
            NotificationCenter.default.post(name: Self.menuItemsDidChange, object: nil)
        }
    }

    @MainActor private func presentPending(id: UUID, effect: PluginUIRetainedEffect, shareFiles: [PluginResourcePath]) {
        defer { effect.finish() }
        guard effect.permitsExecution else {
            self.finishPresentation(id: id, reason: "executionRevoked", notify: false)
            return
        }
        guard let entry = self.leases.beginPresentation(id: id) else {
            if self.leases.entry(id: id)?.state.phase == .dismissing { self.finishPresentation(id: id) }
            return
        }
        do {
            try self.requireOwner(entry)
            guard let context = self.accountContext, context.account.id.int64 == entry.state.scope.accountRecordId,
                  let presenter = self.currentPresenter(context), presenter.viewIfLoaded?.window != nil else {
                throw PluginUIFailure.unavailable("No visible native presenter for the captured account")
            }
            switch entry.content {
            case .menu: throw PluginUIFailure.invalidHandle("Persistent menu registrations are not presentations")
            case let .navigation(model):
                try self.require(.intents, pluginId: entry.state.pluginId)
                if let sourceId = model.sourceId {
                    guard let screen = self.screens[sourceId], screen.scope == entry.state.scope, screen.controller === presenter,
                          screen.contextKey == pluginUIScreenContextKey(presenter) else {
                        throw PluginUIFailure.invalidHandle("Native fragment is no longer the active screen")
                    }
                }
                guard let navigation = self.navigationController(context, presenter: presenter) else { throw PluginUIFailure.unavailable("Native navigation controller is unavailable") }
                if model.route == "back" {
                    guard navigation.viewControllers.count > 1, navigation.topViewController === presenter else { throw PluginUIFailure.unavailable("The current native screen cannot go back") }
                    try self.requireOwner(entry)
                    try self.requireNativeEffect(effect)
                    navigation.filterController(presenter, animated: true)
                    self.finishPresentation(id: id, reason: "navigation")
                    return
                }
                guard let peerType = model.peerType, let peerValue = model.peerId else { throw PluginUIFailure.malformed("Missing native peer destination") }
                let namespace: EnginePeer.Id.Namespace
                switch peerType {
                case "group": namespace = Namespaces.Peer.CloudGroup
                case "channel": namespace = Namespaces.Peer.CloudChannel
                default: namespace = Namespaces.Peer.CloudUser
                }
                let peerId = EnginePeer.Id(namespace: namespace, id: ._internalFromInt64Value(peerValue))
                let subject: ChatControllerSubject? = model.messageId.map { .message(id: .id(EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: $0)), highlight: nil, timecode: nil, setupReply: false) }
                try self.requireOwner(entry)
                try self.requireNativeEffect(effect)
                let controller = context.sharedContext.makeChatController(context: context, chatLocation: .peer(id: peerId), subject: subject, botStart: nil, mode: .standard(.default), params: nil)
                self.installNative(controller, id: id, share: false)
                navigation.pushViewController(controller)
            case let .presentation(model):
                try self.requireModelPermissions(model, pluginId: entry.state.pluginId)
                if let sourceId = model.sourceId {
                    guard let screen = self.screens[sourceId], screen.scope == entry.state.scope, screen.controller === presenter,
                          screen.contextKey == pluginUIScreenContextKey(presenter) else {
                        throw PluginUIFailure.invalidHandle("Native fragment is no longer the active screen")
                    }
                }
                if model.kind == .share {
                    try self.presentShare(model, entry: entry, presenter: presenter, effect: effect, files: shareFiles)
                } else if model.kind == .settings && model.raw["rows"] == nil {
                    try self.requireNativeEffect(effect)
                    guard let navigation = self.navigationController(context, presenter: presenter),
                          let controller = self.settingsController(context, entry.state.pluginId, model.title ?? pluginText("Settings.Title", "Plugin settings"), model.pagePath) else {
                        throw PluginUIFailure.unavailable("Plugin settings controller is unavailable")
                    }
                    try self.requireOwner(entry)
                    try self.requireNativeEffect(effect)
                    self.installNative(controller, id: id, share: false)
                    navigation.pushViewController(controller)
                } else {
                    try self.requireNativeEffect(effect)
                    let controller = PluginUIContentController(context: context, model: model, revision: entry.state.revision,
                        event: { [weak self] revision, name, payload, reason in
                            return self?.handleEvent(id: id, revision: revision, name: name, payload: payload, reason: reason) ?? false
                        }, canAct: { [weak self] revision in self?.canAct(id: id, revision: revision) ?? false },
                        visibilityChanged: { [weak self] visible in self?.observed(id: id, visible: visible) },
                        closed: { [weak self] in self?.nativeDisappeared(id: id) }, timedOut: { [weak self] in self?.timeout(id: id) },
                        openLink: { [weak self] revision, url in
                            guard let self else { throw PluginUIFailure.unavailable("Native UI provider was released") }
                            try self.openLink(id: id, revision: revision, url: url)
                        }, failed: { [weak self] failure in self?.failPresentation(id: id, failure: failure) })
                    self.presentations[id] = NativePresentation(controller: controller, isShare: false)
                    if model.kind == .settings {
                        self.presentations[id]?.settingsObservation = PluginUISettingsRefresh.observe(pluginId: entry.state.pluginId) { [weak self] in
                            guard let self, let current = self.leases.entry(id: id), self.isCurrent(owner: current.owner, scope: current.state.scope),
                                  let delivery = self.leases.refresh(id: id) else { return }
                            if !self.deliver(delivery) {
                                self.failPresentation(id: id, failure: .unavailable("Owner queue could not accept settings refresh"))
                            }
                        }
                    }
                    if model.kind.isPage {
                        guard let navigation = self.navigationController(context, presenter: presenter) else { throw PluginUIFailure.unavailable("Native navigation controller is unavailable") }
                        try self.requireOwner(entry)
                        try self.requireNativeEffect(effect)
                        navigation.pushViewController(controller)
                    } else {
                        guard presenter.window != nil else { throw PluginUIFailure.unavailable("Native presentation window is unavailable") }
                        try self.requireOwner(entry)
                        try self.requireNativeEffect(effect)
                        presenter.present(controller, in: .window(.root))
                    }
                }
            }
            // A lost/blocked native presentation must close its accepted lease.
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
                guard let self, self.leases.entry(id: id)?.state.phase == .presenting else { return }
                self.failPresentation(id: id, failure: .unavailable("Native controller did not appear within 3 seconds"))
            }
        } catch let failure as PluginUIFailure {
            self.failPendingPresentation(id: id, effect: effect, failure: failure)
        } catch let failure as BridgeFailure {
            self.failPendingPresentation(id: id, effect: effect, failure: PluginUIFailure(kind: failure.kind, message: failure.description))
        } catch {
            self.failPendingPresentation(id: id, effect: effect, failure: .unavailable("Native presentation failed"))
        }
    }

    @MainActor private func failPendingPresentation(id: UUID, effect: PluginUIRetainedEffect, failure: PluginUIFailure) {
        if effect.permitsExecution { self.failPresentation(id: id, failure: failure) }
        else {
            self.removeNative(id: id, animated: false)
            self.finishPresentation(id: id, reason: "executionRevoked", notify: false)
        }
    }

    @MainActor private func requireNativeEffect(_ effect: PluginUIRetainedEffect) throws {
        guard effect.permitsExecution else { throw PluginUIFailure.invalidHandle("Originating native UI execution expired") }
    }

    @MainActor private func presentShare(_ model: PluginUIModel, entry: Store.Entry, presenter: ViewController, effect: PluginUIRetainedEffect, files: [PluginResourcePath]) throws {
        guard files.count == model.files.count else { throw PluginUIFailure.invalidHandle("Share resources were not admitted with this presentation") }
        var items: [Any] = []
        let mime = try model.raw.uiString("mimeType", limit: 256)
        let type: UTType?
        if let mime {
            let wildcards: [String: UTType] = ["*/*": .data, "image/*": .image, "video/*": .movie, "audio/*": .audio, "text/*": .text]
            guard let value = wildcards[mime] ?? UTType(mimeType: mime) else { throw PluginUIFailure.resource("Unavailable native share MIME type: \(mime)") }
            if model.files.isEmpty && !value.conforms(to: .text) && mime != "*/*" && mime != "text/uri-list" {
                throw PluginUIFailure.malformed("Share MIME type \(mime) requires a matching file")
            }
            type = value
        } else { type = nil }
        if !model.text.isEmpty {
            let textType = model.files.isEmpty && mime != "*/*" ? type : nil
            items.append(PluginUIShareItemSource(text: model.text, title: model.title, type: textType))
        }
        if let text = model.url { items.append(PluginUIShareItemSource(url: try PluginUIModel.validateURL(text), type: nil, title: model.title)) }
        for file in files {
            try self.requireOwner(entry)
            try self.requireNativeEffect(effect)
            // Replaces the former main-thread resolver/stat work. No new roots,
            // grant decisions or resource targets are chosen at presentation.
            let url = try file.validatedURL()
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw PluginUIFailure.unavailable("An authorised share file is no longer available")
            }
            items.append(PluginUIShareItemSource(url: url, type: type, title: model.title))
        }
        guard presenter.view.window?.rootViewController?.presentedViewController == nil else { throw PluginUIFailure.unavailable("A native system controller is already presented") }
        let id = entry.state.id
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.title = model.title
        controller.isModalInPresentation = !model.cancelable
        controller.overrideUserInterfaceStyle = presenter.overrideUserInterfaceStyle
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: max(0, presenter.view.bounds.maxY - presenter.view.safeAreaInsets.bottom - 1), width: 1, height: 1)
        controller.completionWithItemsHandler = { [weak self] activity, completed, _, error in
            self?.completeShare(id: id, completed: completed, activity: activity?.rawValue, failed: error != nil)
        }
        self.installNative(controller, id: id, share: true)
        let delegate = PluginUIShareDismissDelegate { [weak self] in self?.completeShare(id: id, completed: false, activity: nil, failed: false) }
        self.presentations[id]?.shareDelegate = delegate
        try self.requireOwner(entry)
        try self.requireNativeEffect(effect)
        presenter.present(controller, animated: true, completion: { [weak self, weak controller] in
            self?.observed(id: id, visible: controller?.viewIfLoaded?.window != nil)
        })
        controller.presentationController?.delegate = delegate
    }

    @MainActor private func installNative(_ controller: UIViewController, id: UUID, share: Bool) {
        let record = NativePresentation(controller: controller, isShare: share)
        let observer = PluginUIAppearanceObserver(appeared: { [weak self] visible in self?.observed(id: id, visible: visible) }, disappeared: { [weak self] in self?.nativeDisappeared(id: id) })
        record.observer = observer
        self.presentations[id] = record
        observer.attach(to: controller)
    }

    @MainActor private func observed(id: UUID, visible: Bool) {
        guard let entry = self.leases.entry(id: id), self.isCurrent(owner: entry.owner, scope: entry.state.scope) else { return }
        if let delivery = self.leases.observeVisibility(id: id, visible: visible), !self.deliver(delivery) {
            self.failPresentation(id: id, failure: .unavailable("Owner queue could not accept presentation callback"))
        }
    }

    @MainActor private func nativeDisappeared(id: UUID) {
        guard let native = self.presentations[id], let entry = self.leases.entry(id: id) else { return }
        if native.isShare && entry.state.phase != .dismissing { return } // system completion owns the result
        if entry.state.phase != .dismissing,
           let navigation = native.controller.navigationController as? NavigationController,
           navigation.viewControllers.contains(where: { $0 === native.controller }) { return }
        self.finishPresentation(id: id)
    }

    @MainActor private func applyLatest(id: UUID) {
        guard let entry = self.leases.entry(id: id), case let .presentation(model) = entry.content else { return }
        guard self.isCurrent(owner: entry.owner, scope: entry.state.scope) else {
            self.removeNative(id: id, animated: false)
            self.finishPresentation(id: id, notify: false)
            return
        }
        if let controller = self.presentations[id]?.controller as? PluginUIContentController { controller.apply(model: model, revision: entry.state.revision) }
        else if model.kind == .settings { PluginUISettingsRefresh.invalidate(pluginId: entry.state.pluginId) }
    }

    @MainActor private func applyUpdate(id: UUID, pluginId: String, owner: PluginHost.CallbackOwner, scope: PluginUIScope,
                                       patch: PluginUIJSON, origin: PluginUIRequestOrigin, execution: PluginNativeCallLease,
                                       effect: PluginUIRetainedEffect, settingsUpdateId: UUID? = nil) {
        var rejection: PluginUIFailure? = .invalidHandle("Settings update was revoked before native commit")
        defer {
            if let settingsUpdateId, let retirement = self.leases.finishSettingsUpdate(id: id, updateId: settingsUpdateId, failure: rejection) {
                self.retire(retirement)
            }
            effect.finish()
        }
        guard effect.permitsExecution, let previous = self.leases.entry(id: id), previous.owner == owner,
              previous.state.scope == scope, previous.state.phase != .dismissing,
              case let .presentation(model) = previous.content, let context = self.accountContext else { return }
        do {
            try PluginUIResources.validate(model.applying(patch), data: context.sharedContext.currentPresentationData.with { $0 })
            // Native model commit and render share this synchronous main turn.
            // Only this commit, not C queue acceptance, admits the visible update.
            _ = try self.leases.update(id: id, pluginId: pluginId, patch: patch, expectedScope: scope,
                settingsUpdateId: settingsUpdateId,
                admission: { try self.validateOrigin(origin, owner: owner, execution: execution) })
            self.applyLatest(id: id)
            rejection = nil
        } catch let failure as PluginUIFailure {
            rejection = failure
            if settingsUpdateId == nil, effect.permitsExecution { self.failPresentation(id: id, failure: failure) }
        } catch {
            let failure = PluginUIFailure.unavailable("Native UI update could not be applied")
            rejection = failure
            if settingsUpdateId == nil, effect.permitsExecution { self.failPresentation(id: id, failure: failure) }
        }
    }

    @MainActor func canAct(id: UUID, revision: Int64) -> Bool {
        guard let entry = self.leases.entry(id: id), entry.state.revision == revision,
              entry.settingsUpdate?.committed != true,
              entry.state.phase == .presented, entry.state.isPresented,
              self.presentations[id]?.controller.viewIfLoaded?.window != nil else { return false }
        return self.isCurrent(owner: entry.owner, scope: entry.state.scope)
    }

    @MainActor private func handleEvent(id: UUID, revision: Int64, name: String, payload: [String: PluginUIJSON], reason: String?) -> Bool {
        guard self.canAct(id: id, revision: revision), let entry = self.leases.entry(id: id) else { return false }
        var name = name
        var payload = payload
        if payload["rowId"] != nil && entry.callbacks[name] == nil {
            let fallback = payload["value"] != nil ? "change" : (payload["longPress"] == .bool(true) && entry.callbacks["longAction"] != nil ? "longAction" : "action")
            if name != fallback { payload["callbackId"] = .string(name) }
            name = fallback
        }
        let decision = self.leases.action(id: id, revision: revision, scope: entry.state.scope, name: name, payload: payload, dismissReason: reason)
        guard decision.accepted else { return false }
        if payload["source"] == .string("back"), let back = entry.callbacks["back"] {
            var event = entry.state.callbackMetadata
            event["id"] = .string(id.uuidString)
            event["event"] = .string("back")
            if reason != nil { event["_uiFinal"] = .bool(true) }
            if !self.deliver(Store.Delivery(owner: entry.owner, handle: back.handle, arguments: .array([.object(event)]), permissionIsCurrent: entry.permissionIsCurrent)) {
                self.failPresentation(id: id, failure: .unavailable("Owner queue could not accept back callback"))
                return false
            }
        }
        if let delivery = decision.delivery, !self.deliver(delivery) {
            self.failPresentation(id: id, failure: .unavailable("Owner queue could not accept UI action"))
            return false
        }
        if reason != nil { self.dismissPresentation(id: id, animated: true) }
        return true
    }

    @MainActor private func timeout(id: UUID) {
        guard let entry = self.leases.entry(id: id), self.canAct(id: id, revision: entry.state.revision), case let .presentation(model) = entry.content else { return }
        let _ = self.handleEvent(id: id, revision: entry.state.revision, name: model.style == "undo" ? "action" : "timeout", payload: ["reason": .string("timeout")], reason: "timeout")
    }

    @MainActor func openLink(id: UUID, revision: Int64, url: URL,
                            intercept: LinkInterceptor? = nil, open: LinkOpener? = nil) throws {
        guard self.canAct(id: id, revision: revision), let entry = self.leases.entry(id: id) else {
            throw PluginUIFailure.invalidHandle("Link belongs to an outdated UI scope")
        }
        try self.require(.intents, pluginId: entry.state.pluginId)
        let destination = try PluginUIModel.validateURL(url.absoluteString)
        try self.requireOwner(entry)
        guard let context = self.accountContext else { throw PluginUIFailure.unavailable("No active account for link opening") }
        let owner = entry.owner
        let scope = entry.state.scope
        let pluginId = entry.state.pluginId
        // This tap is a new effect; the UI-only parent keeps its narrower lease.
        let permissionCurrent = self.permissionAdmission(pluginId, [.ui, .intents])
        guard permissionCurrent() else { throw PluginUIFailure.permission("Link permission admission expired") }
        let effect = try PluginUIRetainedEffect(budget: self.effectBudget, pluginId: pluginId,
            bytes: destination.absoluteString.utf8.count, isCurrent: { [weak self] in
                self?.isCurrent(owner: owner, scope: scope) == true && permissionCurrent()
            })
        let performOpen: LinkOpener = open ?? { destination, completed in
            UIApplication.shared.open(destination, options: [:], completionHandler: { _ in completed() })
        }
        let original: @MainActor () -> Void = { [weak self] in
            guard let self, effect.permitsExecution, self.accountContext === context, self.canAct(id: id, revision: revision) else { effect.finish(); return }
            performOpen(destination, { effect.finish() })
        }
        let interceptOpen: LinkInterceptor = intercept ?? { destination, original in
            NativeServiceOpenHooks.shared.interceptURL(context: context, url: destination, original: original)
        }
        if !interceptOpen(destination, original) { original() }
    }

    @MainActor func completeShare(id: UUID, completed: Bool, activity: String?, failed: Bool) {
        guard let entry = self.leases.entry(id: id) else { return }
        guard entry.permissionIsCurrent(), self.isCurrent(owner: entry.owner, scope: entry.state.scope) else { self.finishPresentation(id: id, notify: false); return }
        let payload: [String: PluginUIJSON] = ["completed": .bool(completed), "activityType": activity.map(PluginUIJSON.string) ?? .null]
        if let result = try? self.leases.beginDismiss(id: id, pluginId: entry.state.pluginId, reason: failed ? "failed" : (completed ? "completed" : "cancel"), callbackName: completed ? "action" : "cancel", payload: payload), let delivery = result.delivery, !self.deliver(delivery) {
            self.failPresentation(id: id, failure: .unavailable("Owner queue could not accept share completion"))
            return
        }
        self.finishPresentation(id: id, failure: failed ? .unavailable("System share activity failed") : nil)
    }

    @MainActor private func dismissPresentation(id: UUID, animated: Bool) {
        guard let native = self.presentations[id] else { self.finishPresentation(id: id); return }
        if let controller = native.controller as? PluginUIContentController { controller.dismissOwned(animated: animated) }
        else if let controller = native.controller as? ViewController {
            controller.dismiss(animated: animated)
            if controller.viewIfLoaded?.window == nil { self.finishPresentation(id: id) }
        } else {
            native.controller.dismiss(animated: animated, completion: { [weak self] in self?.finishPresentation(id: id) })
        }
    }

    @MainActor private func removeNative(id: UUID, animated: Bool) {
        guard let native = self.presentations.removeValue(forKey: id) else { return }
        if let controller = native.controller as? PluginUIContentController { controller.dismissOwned(animated: animated) }
        else { native.controller.dismiss(animated: animated, completion: nil) }
    }

    @MainActor private func failPresentation(id: UUID, failure: PluginUIFailure) {
        self.removeNative(id: id, animated: false)
        self.finishPresentation(id: id, failure: failure)
    }

    @MainActor private func finishPresentation(id: UUID, reason: String? = nil, notify: Bool = true, failure: PluginUIFailure? = nil) {
        let current = self.leases.entry(id: id).map { self.isCurrent(owner: $0.owner, scope: $0.state.scope) } ?? false
        if let retirement = self.leases.finish(id: id, reason: reason, notify: notify && current, failure: failure) { self.retire(retirement) }
        self.presentations.removeValue(forKey: id)
    }

    @discardableResult func deliver(_ delivery: Store.Delivery) -> Bool {
        return self.deliveryCallback(delivery)
    }

    private func retire(_ retirement: Store.Retirement) {
        self.releaseQueue.retire(retirement)
    }

    @MainActor func currentPresenter(_ context: AccountContext) -> ViewController? {
        if let presenter = self.presenter { return presenter(context) }
        func eligible(_ controller: UIViewController) -> Bool {
            return !controller.isBeingDismissed && (controller as? PluginUIContentController)?.isClosing != true
        }
        var candidate = context.sharedContext.mainWindow?.topLevelOverlayControllers.reversed().compactMap { $0 as? UIViewController }.first(where: eligible)
        if candidate == nil { candidate = context.sharedContext.mainWindow?.viewController as? UIViewController }
        if candidate == nil { candidate = context.sharedContext.applicationBindings.getTopWindow()?.rootViewController }
        var visited = Set<ObjectIdentifier>()
        while let current = candidate, visited.insert(ObjectIdentifier(current)).inserted, visited.count <= 32 {
            if let presented = current.presentedViewController, eligible(presented) { candidate = presented; continue }
            if let navigation = current as? UINavigationController, let top = navigation.topViewController { candidate = top; continue }
            if let tabs = current as? TabBarController, let selected = tabs.currentController { candidate = selected; continue }
            if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController { candidate = selected; continue }
            if let controller = current as? ViewController {
                var overlay: ViewController?
                controller.forEachController { value in
                    if let value = value as? ViewController, value.viewIfLoaded?.window != nil, eligible(value) { overlay = value }
                    return true
                }
                if let overlay { candidate = overlay; continue }
            }
            return current as? ViewController
        }
        return nil
    }

    @MainActor private func navigationController(_ context: AccountContext, presenter: ViewController) -> NavigationController? {
        return presenter.navigationController as? NavigationController ?? context.sharedContext.mainWindow?.viewController as? NavigationController
    }

    @MainActor func screenId(_ controller: ViewController, scope: PluginUIScope) -> UUID {
        let contextKey = pluginUIScreenContextKey(controller)
        if let existing = self.screens.first(where: { $0.value.controller === controller && $0.value.scope == scope && $0.value.contextKey == contextKey }) { return existing.key }
        let id = UUID()
        self.screens[id] = WeakScreen(controller: controller, scope: scope, contextKey: contextKey)
        self.screenOrder.append(id)
        while self.screenOrder.count > 64 { self.screens.removeValue(forKey: self.screenOrder.removeFirst()) }
        return id
    }
}

private final class WeakScreen {
    weak var controller: ViewController?
    let scope: PluginUIScope
    let contextKey: String?
    init(controller: ViewController, scope: PluginUIScope, contextKey: String?) { self.controller = controller; self.scope = scope; self.contextKey = contextKey }
}

@MainActor func pluginUIScreenContextKey(_ controller: ViewController) -> String? {
    guard let chat = controller as? ChatController else { return nil }
    let peer = chat.chatLocation.peerId
    return "\(peer?.namespace._internalGetInt32Value() ?? -1):\(peer?.id._internalGetInt64Value() ?? 0):\(chat.chatLocation.threadId.map(String.init) ?? "none")"
}

private final class NativePresentation {
    let controller: UIViewController
    let isShare: Bool
    var observer: PluginUIAppearanceObserver?
    var shareDelegate: PluginUIShareDismissDelegate?
    var settingsObservation: PluginUISettingsObservation?
    init(controller: UIViewController, isShare: Bool) { self.controller = controller; self.isShare = isShare }
}

private final class PluginUIShareDismissDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
    private let dismissed: () -> Void
    init(dismissed: @escaping () -> Void) { self.dismissed = dismissed }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { self.dismissed() }
}

private final class PluginUIShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL?
    private let text: String?
    private let type: UTType?
    private let title: String?
    init(url: URL, type: UTType?, title: String?) { self.url = url; self.text = nil; self.type = type; self.title = title }
    init(text: String, title: String?, type: UTType? = nil) { self.url = nil; self.text = text; self.type = type ?? .plainText; self.title = title }
    private var item: Any { if let url = self.url { return url }; return self.text ?? "" }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { return self.item }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { return self.item }
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { return self.title ?? self.url?.lastPathComponent ?? "" }
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        if let type = self.type { return type.identifier }
        if let url = self.url { return url.isFileURL ? (UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier) : UTType.url.identifier }
        return UTType.plainText.identifier
    }
}
