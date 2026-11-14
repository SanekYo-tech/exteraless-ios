import Foundation

/// Backend operations are distinct: reading a method, calling a field, or writing
/// a read-only member must fail rather than accidentally perform its effect.
public enum BridgeOperation: String, Sendable {
    case construct
    case call
    case callInstance = "call_instance"
    case get
    case getInstance = "get_instance"
    case set
    case setInstance = "set_instance"
    case memberKind = "member_kind"
    case classExists = "class_exists"
}

/// Public so application-side services can return the same typed native errors.
public enum BridgeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case memberError(String)
    case unimplemented(String)
    case permission(String)
    case malformed(String)
    case unavailable(String)
    case invalidHandle(String)
    case storage(String)

    public var kind: String {
        switch self {
        case .memberError: return "JavaMemberError"
        case .unimplemented: return "Unimplemented"
        case .permission: return "SecurityError"
        case .malformed: return "MalformedRequest"
        case .unavailable: return "ServiceUnavailable"
        case .invalidHandle: return "InvalidHandle"
        case .storage: return "StorageError"
        }
    }

    public var description: String {
        switch self {
        case .memberError(let text), .unimplemented(let text), .permission(let text),
             .malformed(let text), .unavailable(let text), .invalidHandle(let text), .storage(let text):
            return text
        }
    }
}

public protocol PluginMessagesService: AnyObject, Sendable {
    func selectedAccount() throws -> Int32
    /// An opaque service token, not a Python handle. BridgeServices wraps it in an
    /// owner-scoped negative handle. Nonthrowing implementations remain conformant.
    func instanceHandle(fqcn: String, account: Int32) throws -> Int64
}

public protocol PluginSettingsService: AnyObject, Sendable {
    func themeColor(forKey key: String) throws -> Int32
    func themeKey(_ name: String) throws -> String
}

public protocol PluginUIService: AnyObject {
    func dp(_ value: Double) throws -> Double
    /// For native Swift work only. Python runnables use BridgeServices.onCallback.
    func runOnUIThread(delayMs: Int, work: @escaping @Sendable () -> Void)
    func constructUI(fqcn: String, arguments: [Any]) throws -> Int64
}

/// Synchronous C callback dispatcher. JSON carries only values and tagged handles;
/// pluginId is supplied by NativeBridgeBinding from C interpreter state. A field
/// called pluginId in the JSON request is deliberately never consulted.
///
/// Runtime contract (all `call`, positional arguments):
/// getSetting(key, defaultValue) -> JSON; setSetting(key, value) -> null;
/// removeSetting(key) -> Bool; getFilesDir()/getPluginsDir() -> absolute path;
/// log(message) -> null; getVersion() -> String.
/// getCacheDir(), addToClipboard(text), openURL(url) are native conveniences.
/// sendMessage(peerId, text, account) -> {status:"scheduled", requestId:String}.
/// Peer ids and the text-only subset are documented by PluginTextMessageRequest.
/// completeCallback(positiveHandle) -> Bool removes one pending callback reference
/// for the native plugin owner. Only the last reference returns true; unknown
/// handles (including reusable handles without a pending callback) return false.
/// This never releases a Python handle. The owner must complete and, on true,
/// xt_release_handle in one uninterrupted owner-GIL operation in its finally block.
public final class BridgeServices: @unchecked Sendable {
    public static let runtimeClassName = "exteraless.ios.Runtime"
    public static let accountClassNames: Set<String> = [
        "org.telegram.messenger.UserConfig", "org.telegram.messenger.MessagesController",
        "org.telegram.messenger.AccountInstance", "org.telegram.messenger.SendMessagesHelper"
    ]

    /// The coordinator queues this on the owning interpreter, honoring delayMs.
    /// The closure is invoked on the C callback worker, never on the main queue.
    /// It must enqueue and return immediately; it must not reenter Python inline.
    /// Every accepted call already holds a pending reference, even for zero delay.
    /// Completion must consume it through Runtime.completeCallback; unload clears
    /// discarded references through releaseInstances(pluginId:).
    public typealias Callback = @Sendable (_ pluginId: String, _ handle: Int64,
                                           _ method: String, _ argsJSON: String, _ delayMs: Int) -> Void

    private let lock = NSLock()
    private let messages: (any PluginMessagesService)?
    private let settings: (any PluginSettingsService)?
    private let ui: (any PluginUIService)?
    private let permissions: PermissionsModel?
    private let reflection: SecurityGates?
    private var callback: Callback?
    private var instances: [Int64: InstanceRecord] = [:]
    private var instanceIds: [InstanceRecord: Int64] = [:]
    private var nextInstanceId: Int64 = -1

    // Counts refer to scheduled invocations, not distinct handles. All admission,
    // completion and unload changes share `lock` with the callback and instances.
    private static let maximumPendingCallbacksPerPlugin = 256
    private static let maximumPendingCallbacks = 1024
    private struct PendingCallbacks {
        var references: [Int64: Int] = [:]
        var count = 0
    }
    private var pendingCallbacks: [String: PendingCallbacks] = [:]
    private var pendingCallbackCount = 0

    private enum InstanceValue: Hashable {
        case applicationContext
        case file(URL)
        case locale
        case account(PluginServiceAccount)
        case legacy(Int64)
    }

    private struct InstanceRecord: Hashable {
        let fqcn: String
        let pluginId: String
        let value: InstanceValue
    }

    private var platform: (any PluginPlatformService)? { ui as? any PluginPlatformService }

    public init(messages: (any PluginMessagesService)? = nil,
                settings: (any PluginSettingsService)? = nil,
                ui: (any PluginUIService)? = nil,
                permissions: PermissionsModel? = nil,
                reflection: SecurityGates? = nil) {
        self.messages = messages
        self.settings = settings
        self.ui = ui
        self.permissions = permissions
        self.reflection = reflection
    }

    public var onCallback: Callback? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return callback
        }
        set {
            lock.lock()
            callback = newValue
            lock.unlock()
        }
    }

    /// Returns {ok:true,value:...} or {ok:false,error:{kind,message}}.
    public func dispatchJSON(_ json: String, pluginId: String?) -> String {
        do {
            guard let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BridgeFailure.malformed("Expected a JSON request object")
            }
            let request = try Request(object)
            let value = try dispatch(request, pluginId: pluginId)
            return encode(["ok": true, "value": value])
        } catch let failure as BridgeFailure {
            return encode(["ok": false, "error": ["kind": failure.kind, "message": failure.description]])
        } catch {
            return encode(["ok": false, "error": ["kind": "MalformedRequest", "message": error.localizedDescription]])
        }
    }

    // MARK: Request validation and operation dispatch

    private struct Request {
        let operation: BridgeOperation
        let fqcn: String
        let member: String
        let arguments: [Any]
        let instance: Int64?
        let value: Any?
        var name: String { "\(fqcn)#\(member)" }

        init(_ object: [String: Any]) throws {
            guard let op = object["op"] as? String, let operation = BridgeOperation(rawValue: op) else {
                throw BridgeFailure.malformed("Missing or unknown bridge operation")
            }
            guard let fqcn = object["fqcn"] as? String, !fqcn.isEmpty else {
                throw BridgeFailure.malformed("Missing fqcn")
            }
            let member = object["member"] as? String ?? ""
            if operation != .construct && operation != .classExists && member.isEmpty {
                throw BridgeFailure.malformed("Missing member for \(op)")
            }
            if let raw = object["args"], !(raw is [Any]) {
                throw BridgeFailure.malformed("args must be a JSON array")
            }
            if let raw = object["kwargs"] {
                guard let kwargs = raw as? [String: Any] else {
                    throw BridgeFailure.malformed("kwargs must be a JSON object")
                }
                guard kwargs.isEmpty else {
                    throw BridgeFailure.unimplemented("\(fqcn)#\(member): keyword arguments are unsupported")
                }
            }
            let arguments = object["args"] as? [Any] ?? []
            if operation != .call && operation != .callInstance && operation != .construct && !arguments.isEmpty {
                throw BridgeFailure.malformed("\(op) does not take positional arguments")
            }
            var instance: Int64?
            if let raw = object["instance"], !(raw is NSNull) {
                if let marker = raw as? [String: Any] {
                    guard let handle = marker["__handle__"] else {
                        throw BridgeFailure.malformed("instance must be a handle")
                    }
                    instance = try PluginServiceArgument.integer(handle, name: "instance")
                    let type = try BridgeServices.markerClass(marker)
                    guard type == fqcn else {
                        throw BridgeFailure.invalidHandle("Instance type does not match \(fqcn)")
                    }
                } else {
                    instance = try PluginServiceArgument.integer(raw, name: "instance")
                }
            }
            let isInstance = operation == .callInstance || operation == .getInstance || operation == .setInstance
            guard isInstance == (instance != nil) else {
                throw BridgeFailure.malformed(isInstance ? "\(op) requires instance" : "\(op) is a static operation")
            }
            if operation == .set || operation == .setInstance, object["value"] == nil {
                throw BridgeFailure.malformed("\(op) requires value (JSON null is allowed)")
            }
            self.operation = operation
            self.fqcn = fqcn
            self.member = member
            self.arguments = arguments
            self.instance = instance
            self.value = object["value"]
        }

        func arity(_ range: ClosedRange<Int>) throws {
            guard range.contains(arguments.count) else {
                throw BridgeFailure.malformed("\(name): expected \(range.lowerBound)...\(range.upperBound) arguments, received \(arguments.count)")
            }
        }
    }

    private func dispatch(_ request: Request, pluginId: String?) throws -> Any {
        // Runtime is a native capability, not a Java package. Only this exact
        // fqcn bypasses the Java-root policy; its operations still validate owner
        // identity and enforce the existing effect permissions below.
        if request.fqcn != Self.runtimeClassName, let reflection,
           case .denied(let reason) = reflection.checkClass(fqcn: request.fqcn, pluginId: pluginId) {
            throw BridgeFailure.permission(reason)
        }
        var record: InstanceRecord?
        if let handle = request.instance {
            record = try instance(handle, fqcn: request.fqcn, pluginId: pluginId)
        }
        try validateReferences(request.arguments, pluginId: pluginId)
        if let value = request.value { try validateReferences(value, pluginId: pluginId) }

        switch request.operation {
        case .classExists:
            return classExists(request.fqcn)
        case .memberKind:
            return memberKind(fqcn: request.fqcn, member: request.member)
        case .construct:
            throw BridgeFailure.unimplemented("Unsupported iOS constructor: \(request.fqcn); Android UI/TLRPC objects are not emulated")
        case .get:
            return try getStatic(request, pluginId: pluginId)
        case .call:
            return try callStatic(request, pluginId: pluginId)
        case .getInstance:
            guard let record else { throw BridgeFailure.invalidHandle("Missing instance") }
            if request.member == "currentAccount", case .account(let account) = record.value {
                return try activeAccount(account).index
            }
            throw unsupported(request)
        case .callInstance:
            guard let record else { throw BridgeFailure.invalidHandle("Missing instance") }
            return try callInstance(request, record: record)
        case .set, .setInstance:
            throw BridgeFailure.memberError("\(request.name) is not a writable iOS member")
        }
    }

    private func getStatic(_ request: Request, pluginId: String?) throws -> Any {
        switch (request.fqcn, request.member) {
        case ("org.telegram.messenger.UserConfig", "selectedAccount"):
            if let platform { return try platform.platformSnapshot.selectedAccount() }
            guard let messages else { throw missingService(request.name) }
            return try messages.selectedAccount()
        case ("org.telegram.messenger.ApplicationLoader", "applicationContext"):
            _ = try requirePlatform(request.name)
            return try register(fqcn: "android.content.Context", pluginId: pluginId, value: .applicationContext)
        case ("org.telegram.messenger.AndroidUtilities", "density"):
            let snapshot = try requirePlatform(request.name).platformSnapshot
            _ = try snapshot.points(0, pixelAligned: false)
            guard let scale = snapshot.displayScale else { throw missingService(request.name) }
            return scale
        default:
            if request.fqcn == "org.telegram.ui.ActionBar.Theme", request.member.hasPrefix("key_") {
                guard let settings else { throw missingService(request.name) }
                return try settings.themeKey(request.member)
            }
            throw unsupported(request)
        }
    }

    private func callStatic(_ request: Request, pluginId: String?) throws -> Any {
        if request.fqcn == Self.runtimeClassName {
            return try callRuntime(request, pluginId: requiredPluginId(pluginId))
        }
        if Self.accountClassNames.contains(request.fqcn), request.member == "getInstance" {
            try request.arity(1...1)
            let account = try accountIndex(request.arguments[0])
            if let platform {
                let snapshot = try platform.platformSnapshot.account(at: account)
                return try register(fqcn: request.fqcn, pluginId: pluginId, value: .account(snapshot))
            }
            guard let messages else { throw missingService(request.name) }
            let token = try messages.instanceHandle(fqcn: request.fqcn, account: account)
            return try register(fqcn: request.fqcn, pluginId: pluginId, value: .legacy(token))
        }
        switch request.fqcn {
        case "org.telegram.messenger.AndroidUtilities":
            switch request.member {
            case "dp", "dpf2":
                try request.arity(1...1)
                let value = try PluginServiceArgument.number(request.arguments[0], name: request.name)
                if let platform {
                    return try platform.platformSnapshot.points(value, pixelAligned: request.member == "dp")
                }
                guard request.member == "dp", let ui else { throw missingService(request.name) }
                return try ui.dp(value)
            case "runOnUIThread":
                return try scheduleCallback(request, pluginId: pluginId)
            case "addToClipboard":
                try request.arity(1...1)
                let owner = try requiredPluginId(pluginId)
                let text = try PluginServiceArgument.string(request.arguments[0], name: request.name)
                try requirePlatform(request.name).addToClipboard(text, pluginId: owner)
                return NSNull()
            default: throw unsupported(request)
            }
        case "org.telegram.ui.ActionBar.Theme" where request.member == "getColor":
            try request.arity(1...1)
            let key = try PluginServiceArgument.string(request.arguments[0], name: request.name)
            guard let settings else { throw missingService(request.name) }
            return NSNumber(value: UInt32(bitPattern: try settings.themeColor(forKey: key)))
        case "org.telegram.messenger.LocaleController":
            if request.member == "getInstance" {
                try request.arity(0...0)
                _ = try requirePlatform(request.name).platformSnapshot.localeStringIso639()
                return try register(fqcn: request.fqcn, pluginId: pluginId, value: .locale)
            }
            return try callLocale(request)
        case "org.telegram.messenger.ApplicationLoader" where ["getFilesDir", "getFilesDirFixed", "getCacheDir"].contains(request.member):
            try request.arity(0...0)
            return try directoryHandle(cache: request.member == "getCacheDir", pluginId: requiredPluginId(pluginId))
        case "org.telegram.messenger.browser.Browser" where request.member == "openUrl" || request.member == "openURL":
            try request.arity(1...2)
            if request.arguments.count == 2 {
                _ = try contextArgument(request.arguments[0], pluginId: pluginId)
            }
            return try openURL(request.arguments[request.arguments.count - 1], pluginId: requiredPluginId(pluginId))
        default:
            throw unsupported(request)
        }
    }

    private func callRuntime(_ request: Request, pluginId: String) throws -> Any {
        if request.member == "hasPermission" {
            try request.arity(1...1)
            let name = try PluginServiceArgument.string(request.arguments[0], name: "hasPermission.permission")
            guard let permission = PluginPermission(rawValue: name) else {
                throw BridgeFailure.malformed("Unknown plugin permission: \(name)")
            }
            return permissions?.has(pluginId, permission) ?? (permission == .ui)
        }
        if request.member == "isUnsafeMode" {
            try request.arity(0...0)
            return permissions?.unsafeMode ?? false
        }
        // Lifetime accounting belongs to the bridge, not the UI/platform adapter.
        // Native probes and callbacks can complete even without a UI service.
        if request.member == "completeCallback" {
            try request.arity(1...1)
            let handle = try PluginServiceArgument.integer(request.arguments[0], name: "completeCallback.handle")
            guard handle > 0 else {
                throw BridgeFailure.invalidHandle("completeCallback requires a Python-owned positive callback handle")
            }
            return completeCallback(handle: handle, pluginId: pluginId)
        }
        let service = try requirePlatform(request.name)
        switch request.member {
        case "getSetting":
            try request.arity(2...2)
            let key = try PluginServiceArgument.string(request.arguments[0], name: "getSetting.key")
            return try service.serviceStorage.getSetting(pluginId: pluginId, key: key,
                defaultValue: PluginJSONValue(jsonObject: request.arguments[1])).jsonObject
        case "setSetting":
            try request.arity(2...2)
            let key = try PluginServiceArgument.string(request.arguments[0], name: "setSetting.key")
            try service.serviceStorage.setSetting(pluginId: pluginId, key: key,
                value: PluginJSONValue(jsonObject: request.arguments[1]))
            return NSNull()
        case "removeSetting":
            try request.arity(1...1)
            let key = try PluginServiceArgument.string(request.arguments[0], name: "removeSetting.key")
            return try service.serviceStorage.removeSetting(pluginId: pluginId, key: key)
        case "getFilesDir", "getCacheDir", "getPluginsDir":
            try request.arity(0...0)
            try PluginServiceStorage.validatePluginId(pluginId)
            if request.member == "getPluginsDir" { return try service.serviceStorage.pluginsDirectory().path }
            if request.member == "getCacheDir" { return try service.serviceStorage.cacheDirectory(pluginId: pluginId).path }
            return try service.serviceStorage.filesDirectory(pluginId: pluginId).path
        case "log":
            try request.arity(1...1)
            service.serviceLogs.append(pluginId: pluginId,
                message: try PluginServiceArgument.string(request.arguments[0], name: "log.message"))
            return NSNull()
        case "getVersion":
            try request.arity(0...0)
            return service.runtimeVersion
        case "addToClipboard":
            try request.arity(1...1)
            try service.addToClipboard(PluginServiceArgument.string(request.arguments[0], name: request.name), pluginId: pluginId)
            return NSNull()
        case "openURL":
            try request.arity(1...1)
            return try openURL(request.arguments[0], pluginId: pluginId)
        case "sendMessage":
            try request.arity(3...3)
            let account = try service.platformSnapshot.account(at: accountIndex(request.arguments[2]))
            return try sendMessage(peer: request.arguments[0], text: request.arguments[1], account: account, pluginId: pluginId)
        default:
            throw unsupported(request)
        }
    }

    private func callInstance(_ request: Request, record: InstanceRecord) throws -> Any {
        switch record.value {
        case .applicationContext:
            if request.member == "getFilesDir" || request.member == "getCacheDir" {
                try request.arity(0...0)
                return try directoryHandle(cache: request.member == "getCacheDir", pluginId: record.pluginId)
            }
        case .file(let url):
            try request.arity(0...0)
            switch request.member {
            case "getPath", "getAbsolutePath", "toString": return url.path
            case "getName": return url.lastPathComponent
            case "exists": return FileManager.default.fileExists(atPath: url.path)
            case "isDirectory":
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            default: break
            }
        case .locale:
            return try callLocale(request)
        case .account(let stored):
            let account = try activeAccount(stored)
            if request.member == "getCurrentAccount" {
                try request.arity(0...0)
                return account.index
            }
            if record.fqcn == "org.telegram.messenger.UserConfig" {
                if request.member == "getClientUserId" {
                    try request.arity(0...0)
                    return NSNumber(value: account.userId)
                }
                if request.member == "isClientActivated" {
                    try request.arity(0...0)
                    return true // Only a still-active record can reach this branch.
                }
            }
            if record.fqcn == "org.telegram.messenger.AccountInstance" {
                let classes = ["getUserConfig": "UserConfig", "getMessagesController": "MessagesController",
                               "getSendMessagesHelper": "SendMessagesHelper"]
                if let name = classes[request.member] {
                    try request.arity(0...0)
                    return try register(fqcn: "org.telegram.messenger.\(name)", pluginId: record.pluginId, value: .account(account))
                }
            }
            if record.fqcn == "org.telegram.messenger.SendMessagesHelper", request.member == "sendMessage" {
                guard request.arguments.count == 2 else {
                    throw BridgeFailure.unimplemented("SendMessagesHelper.sendMessage supports only (peerId, text); SendMessageParams/TLRPC overloads are unsupported")
                }
                return try sendMessage(peer: request.arguments[0], text: request.arguments[1], account: account, pluginId: record.pluginId)
            }
        case .legacy:
            break
        }
        throw unsupported(request)
    }

    private func callLocale(_ request: Request) throws -> Any {
        let snapshot = try requirePlatform(request.name).platformSnapshot
        switch request.member {
        case "getLocaleStringIso639":
            try request.arity(0...0)
            return try snapshot.localeStringIso639()
        case "getString":
            try request.arity(1...2)
            let key = try PluginServiceArgument.string(request.arguments[0], name: "getString.key")
            if request.arguments.count == 2 {
                // Android's resource id is platform-specific; the explicit key is
                // authoritative on iOS, and an unknown key has a named fallback.
                _ = try PluginServiceArgument.integer(request.arguments[1], name: "getString.resourceId")
            }
            return try snapshot.localizedString(key)
        default: throw unsupported(request)
        }
    }

    // MARK: Effects

    private func scheduleCallback(_ request: Request, pluginId: String?) throws -> Any {
        try request.arity(1...2)
        let owner = try requiredPluginId(pluginId)
        guard let marker = request.arguments[0] as? [String: Any], let raw = marker["__handle__"] else {
            throw BridgeFailure.malformed("runOnUIThread requires a tagged Python runnable")
        }
        let handle = try PluginServiceArgument.integer(raw, name: "runOnUIThread.runnable")
        guard handle > 0 else {
            throw BridgeFailure.invalidHandle("runOnUIThread requires a Python-owned positive callback handle")
        }
        let delay: Int64
        if request.arguments.count == 2 {
            delay = try PluginServiceArgument.integer(request.arguments[1], name: "runOnUIThread.delayMs")
        } else {
            delay = 0
        }
        guard delay >= 0, delay <= Int64(Int32.max) else {
            throw BridgeFailure.malformed("runOnUIThread.delayMs must be a nonnegative Int32")
        }
        let callback = try reserveCallback(handle: handle, pluginId: owner)
        // Invoke only after releasing lock: native completion may arrive as soon
        // as the scheduler is called, and must observe its reserved reference.
        callback(owner, handle, "run", "[]", Int(delay))
        return NSNull()
    }

    private func reserveCallback(handle: Int64, pluginId: String) throws -> Callback {
        lock.lock()
        defer { lock.unlock() }
        guard let callback else {
            throw BridgeFailure.unavailable("runOnUIThread: owning-interpreter callback scheduler is not installed")
        }
        let ownerCount = pendingCallbacks[pluginId]?.count ?? 0
        guard ownerCount < Self.maximumPendingCallbacksPerPlugin else {
            throw BridgeFailure.unavailable("runOnUIThread: per-plugin pending callback limit (\(Self.maximumPendingCallbacksPerPlugin)) reached")
        }
        guard pendingCallbackCount < Self.maximumPendingCallbacks else {
            throw BridgeFailure.unavailable("runOnUIThread: global pending callback limit (\(Self.maximumPendingCallbacks)) reached")
        }
        // No counter or dictionary entry is created on a rejected admission.
        pendingCallbacks[pluginId, default: PendingCallbacks()].references[handle, default: 0] += 1
        pendingCallbacks[pluginId, default: PendingCallbacks()].count = ownerCount + 1
        pendingCallbackCount += 1
        return callback
    }

    private func completeCallback(handle: Int64, pluginId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let referenceCount = pendingCallbacks[pluginId]?.references[handle] else { return false }
        let isLastReference = referenceCount == 1
        if isLastReference {
            pendingCallbacks[pluginId]?.references.removeValue(forKey: handle)
        } else {
            pendingCallbacks[pluginId]?.references[handle] = referenceCount - 1
        }
        pendingCallbacks[pluginId]?.count -= 1
        pendingCallbackCount -= 1
        if pendingCallbacks[pluginId]?.count == 0 {
            pendingCallbacks.removeValue(forKey: pluginId)
        }
        return isLastReference
    }

    private func openURL(_ raw: Any, pluginId: String) throws -> Any {
        let text = try PluginServiceArgument.string(raw, name: "Browser.openUrl.url")
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["https", "http", "tg", "mailto", "tel"].contains(scheme),
              (scheme != "https" && scheme != "http") || (url.host?.isEmpty == false) else {
            throw BridgeFailure.malformed("Browser.openUrl requires an absolute http(s), tg, mailto or tel URL")
        }
        try requirePermission(.intents, pluginId: pluginId,
                              fqcn: "org.telegram.messenger.browser.Browser", member: "openUrl")
        try requirePlatform("Browser.openUrl").openURL(url, pluginId: pluginId)
        return NSNull()
    }

    private func sendMessage(peer: Any, text: Any, account: PluginServiceAccount, pluginId: String) throws -> Any {
        let peerKind: PluginTextMessageRequest.PeerKind
        let id: Int64
        if let object = peer as? [String: Any] {
            guard Set(object.keys) == Set(["type", "id"]), let type = object["type"] as? String,
                  let kind = PluginTextMessageRequest.PeerKind(rawValue: type), let raw = object["id"] else {
                throw BridgeFailure.unimplemented("sendMessage.peerId supports only {type:user|group|channel,id:Int64}; TLRPC peers are unsupported")
            }
            peerKind = kind
            id = try PluginServiceArgument.integer(raw, name: "sendMessage.peerId.id")
        } else {
            peerKind = .user
            id = try PluginServiceArgument.integer(peer, name: "sendMessage.peerId")
        }
        guard id > 0, id <= 0x00ff_ffff_ffff_ffff else {
            throw BridgeFailure.malformed("sendMessage peer id must be positive and fit 56 bits; use a typed peer for groups/channels")
        }
        let message = try PluginServiceArgument.string(text, name: "sendMessage.text")
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf16.count <= 4096 else {
            throw BridgeFailure.malformed("sendMessage supports nonempty plain text of at most 4096 UTF-16 units")
        }
        try requirePermission(.messagesSend, pluginId: pluginId,
                              fqcn: "org.telegram.messenger.SendMessagesHelper", member: "sendMessage")
        let request = PluginTextMessageRequest(pluginId: pluginId, account: account, peerKind: peerKind, peerId: id, text: message)
        let requestId = try requirePlatform("Runtime.sendMessage").sendMessage(request)
        return ["status": "scheduled", "requestId": requestId]
    }

    // MARK: Strict reflection surface

    private func classExists(_ fqcn: String) -> Bool {
        if fqcn == Self.runtimeClassName { return true } // completeCallback is intrinsic.
        if fqcn == "org.telegram.ui.ActionBar.Theme" { return settings != nil }
        if fqcn == "org.telegram.messenger.AndroidUtilities" { return ui != nil || onCallback != nil }
        if Self.accountClassNames.contains(fqcn) { return messages != nil || platform != nil }
        return platform != nil && ["org.telegram.messenger.ApplicationLoader",
            "android.content.Context", "java.io.File", "org.telegram.messenger.LocaleController",
            "org.telegram.messenger.browser.Browser"].contains(fqcn)
    }

    private func memberKind(fqcn: String, member: String) -> String {
        guard classExists(fqcn) else { return "unknown" }
        if fqcn == "org.telegram.ui.ActionBar.Theme" {
            if member == "getColor" { return "method" }
            if member.hasPrefix("key_"), (try? settings?.themeKey(member)) != nil { return "field" }
        }
        if fqcn == "org.telegram.messenger.UserConfig", member == "selectedAccount" { return "field" }
        if Self.accountClassNames.contains(fqcn) {
            if member == "currentAccount" { return "field" }
            if ["getInstance", "getCurrentAccount"].contains(member) { return "method" }
            if fqcn.hasSuffix(".UserConfig"), ["getClientUserId", "isClientActivated"].contains(member) { return "method" }
            if fqcn.hasSuffix(".AccountInstance"), ["getUserConfig", "getMessagesController", "getSendMessagesHelper"].contains(member) { return "method" }
            if fqcn.hasSuffix(".SendMessagesHelper"), member == "sendMessage" { return "method" }
        }
        let methods: [String: Set<String>] = [
            Self.runtimeClassName: ["getSetting", "setSetting", "removeSetting", "getFilesDir", "getPluginsDir", "getCacheDir", "log", "getVersion", "sendMessage", "addToClipboard", "openURL", "completeCallback", "hasPermission", "isUnsafeMode"],
            "org.telegram.messenger.AndroidUtilities": ["dp", "dpf2", "runOnUIThread", "addToClipboard"],
            "org.telegram.messenger.LocaleController": ["getInstance", "getString", "getLocaleStringIso639"],
            "org.telegram.messenger.ApplicationLoader": ["getFilesDir", "getFilesDirFixed", "getCacheDir"],
            "android.content.Context": ["getFilesDir", "getCacheDir"],
            "java.io.File": ["getPath", "getAbsolutePath", "getName", "toString", "exists", "isDirectory"],
            "org.telegram.messenger.browser.Browser": ["openUrl", "openURL"]
        ]
        if fqcn == "org.telegram.messenger.ApplicationLoader", member == "applicationContext" { return "field" }
        if fqcn == "org.telegram.messenger.AndroidUtilities", member == "density" { return "field" }
        return methods[fqcn]?.contains(member) == true ? "method" : "unknown"
    }

    // MARK: Host-owned negative handles

    private func register(fqcn: String, pluginId: String?, value: InstanceValue) throws -> [String: Any] {
        let owner = try requiredPluginId(pluginId)
        let record = InstanceRecord(fqcn: fqcn, pluginId: owner, value: value)
        lock.lock()
        defer { lock.unlock() }
        let handle: Int64
        if let existing = instanceIds[record] {
            handle = existing
        } else {
            guard nextInstanceId > Int64.min else { throw BridgeFailure.unavailable("Native handle space exhausted") }
            handle = nextInstanceId
            nextInstanceId -= 1
            instances[handle] = record
            instanceIds[record] = handle
        }
        // __fqcn__ is the existing C transport spelling. The native envelope also
        // accepts __fqcn; both names identify the same type, never two capabilities.
        return ["__handle__": NSNumber(value: handle), "__fqcn__": fqcn, "__fqcn": fqcn]
    }

    private func instance(_ handle: Int64, fqcn: String, pluginId: String?) throws -> InstanceRecord {
        let owner = try requiredPluginId(pluginId)
        lock.lock()
        defer { lock.unlock() }
        guard handle < 0, let record = instances[handle] else {
            throw BridgeFailure.invalidHandle("Unknown or released native handle \(handle)")
        }
        guard record.pluginId == owner else {
            throw BridgeFailure.permission("Native handle \(handle) belongs to another plugin")
        }
        guard record.fqcn == fqcn else {
            throw BridgeFailure.invalidHandle("Native handle \(handle) is \(record.fqcn), not \(fqcn)")
        }
        return record
    }

    private static func markerClass(_ marker: [String: Any]) throws -> String? {
        for key in ["__fqcn__", "__fqcn"] {
            if let value = marker[key], !(value is NSNull), !(value is String) {
                throw BridgeFailure.malformed("\(key) must be a string or null")
            }
        }
        let canonical = marker["__fqcn__"] as? String
        let alias = marker["__fqcn"] as? String
        if let canonical, let alias, canonical != alias {
            throw BridgeFailure.invalidHandle("Conflicting handle type tags")
        }
        return canonical ?? alias
    }

    private func validateReferences(_ value: Any, pluginId: String?, depth: Int = 0) throws {
        guard depth <= 64 else { throw BridgeFailure.malformed("JSON nesting exceeds 64 levels") }
        if let array = value as? [Any] {
            for item in array { try validateReferences(item, pluginId: pluginId, depth: depth + 1) }
        } else if let object = value as? [String: Any] {
            if let raw = object["__handle__"] {
                let handle = try PluginServiceArgument.integer(raw, name: "__handle__")
                let fqcn = try Self.markerClass(object)
                guard handle != 0 else { throw BridgeFailure.invalidHandle("Zero is not a bridge handle") }
                if handle < 0 {
                    guard let fqcn, !fqcn.isEmpty else { throw BridgeFailure.invalidHandle("Native handle requires a type tag") }
                    _ = try instance(handle, fqcn: fqcn, pluginId: pluginId)
                }
            } else {
                for item in object.values { try validateReferences(item, pluginId: pluginId, depth: depth + 1) }
            }
        }
    }

    /// Called by the coordinator at unload/disable. Ids are never reused, so a
    /// stale Python proxy cannot acquire a new object's identity after release.
    /// Also discards this owner's pending references and restores the global
    /// callback budget. The host retires the owner queue before its next lifetime.
    public func releaseInstances(pluginId: String) {
        lock.lock()
        defer { lock.unlock() }
        if let callbacks = pendingCallbacks.removeValue(forKey: pluginId) {
            pendingCallbackCount -= callbacks.count
        }
        let released = instances.filter { $0.value.pluginId == pluginId }
        for (handle, record) in released {
            instances.removeValue(forKey: handle)
            instanceIds.removeValue(forKey: record)
        }
    }

    public func releaseInstance(handle: Int64, fqcn: String, pluginId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle < 0, let record = instances[handle] else {
            throw BridgeFailure.invalidHandle("Unknown or released native handle \(handle)")
        }
        guard record.pluginId == pluginId else {
            throw BridgeFailure.permission("Native handle \(handle) belongs to another plugin")
        }
        guard record.fqcn == fqcn else {
            throw BridgeFailure.invalidHandle("Native handle \(handle) is \(record.fqcn), not \(fqcn)")
        }
        instances.removeValue(forKey: handle)
        instanceIds.removeValue(forKey: record)
    }

    public var liveInstanceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return instances.count
    }

    // MARK: Helpers

    private func requiredPluginId(_ pluginId: String?) throws -> String {
        guard let pluginId, !pluginId.isEmpty else {
            throw BridgeFailure.permission("Native interpreter plugin identity is required")
        }
        return pluginId
    }

    private func requirePlatform(_ name: String) throws -> any PluginPlatformService {
        guard let platform else { throw missingService(name) }
        return platform
    }

    private func missingService(_ name: String) -> BridgeFailure {
        .unavailable("\(name): native service is not installed")
    }

    private func unsupported(_ request: Request) -> BridgeFailure {
        .memberError("Unsupported iOS member: \(request.name) (\(request.operation.rawValue))")
    }

    private func accountIndex(_ raw: Any) throws -> Int32 {
        let value = try PluginServiceArgument.integer(raw, name: "account")
        guard let index = Int32(exactly: value) else {
            throw BridgeFailure.malformed("account does not fit Int32")
        }
        return index
    }

    private func activeAccount(_ stored: PluginServiceAccount) throws -> PluginServiceAccount {
        let current = try requirePlatform("Account instance").platformSnapshot.account(at: stored.index)
        guard current.recordId == stored.recordId else {
            throw BridgeFailure.invalidHandle("Account instance belongs to a replaced account record")
        }
        return current
    }

    private func directoryHandle(cache: Bool, pluginId: String) throws -> [String: Any] {
        let storage = try requirePlatform("ApplicationLoader directory").serviceStorage
        let url: URL
        if cache {
            url = try storage.cacheDirectory(pluginId: pluginId)
        } else {
            url = try storage.filesDirectory(pluginId: pluginId)
        }
        return try register(fqcn: "java.io.File", pluginId: pluginId, value: .file(url))
    }

    private func contextArgument(_ raw: Any, pluginId: String?) throws -> InstanceRecord {
        guard let marker = raw as? [String: Any], let value = marker["__handle__"],
              try Self.markerClass(marker) == "android.content.Context" else {
            throw BridgeFailure.malformed("Browser.openUrl expects ApplicationLoader.applicationContext")
        }
        let handle = try PluginServiceArgument.integer(value, name: "context")
        return try instance(handle, fqcn: "android.content.Context", pluginId: pluginId)
    }

    private func requirePermission(_ permission: PluginPermission, pluginId: String, fqcn: String, member: String) throws {
        if let permissions, !permissions.check(pluginId, permission, what: "\(fqcn)#\(member)") {
            throw BridgeFailure.permission("\(fqcn)#\(member) requires \(permission.rawValue)")
        }
        if let reflection, !reflection.checkPermission(pluginId: pluginId, fqcn: fqcn, member: member) {
            throw BridgeFailure.permission("\(fqcn)#\(member) requires \(permission.rawValue)")
        }
    }

    private func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let result = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"kind\":\"MalformedRequest\",\"message\":\"Non-JSON native response\"}}"
        }
        return result
    }
}
