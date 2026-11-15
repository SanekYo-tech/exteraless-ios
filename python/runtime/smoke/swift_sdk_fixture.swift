import Foundation

/// Foundation-only DTO recorder used exclusively by swift_plugin_probe. Admission
/// is recorded, not presented/enqueued to Telegram. All Python calls still go
/// through the actual PluginHost owner mailbox and the linked C/CPython engine.
final class SDKDTOFixture: PluginBridgeExtension, @unchecked Sendable {
    private struct Entry: Sendable {
        let owner: PluginHost.CallbackOwner
        let handles: [String: Int64]
        let model: PluginJSONValue
    }
    private weak var host: PluginHost?
    private let callbacks: PluginCallbackDispatcher
    private let lock = NSLock()
    private var presentations: [String: Entry] = [:]
    private var tasks: [String: Entry] = [:]
    private var requests: [String: Entry] = [:]
    private var counts: [String: Int] = [:]
    private var epochs = Set<String>()
    private var refreshes = 0

    let exportedMethods: [String: Set<String>] = ["exteraless.ios.Runtime": [
        "uiPresent", "uiState", "uiUpdate", "uiDismiss", "uiRefreshSettings",
        "postToOwner", "cancelOwnerTask", "tlRequest", "tlCancel", "logEvent",
        "sdkFixtureEcho", "sdkFixtureOwner"
    ]]

    init(host: PluginHost) {
        self.host = host
        self.callbacks = PluginCallbackDispatcher(host: host)
    }

    func dispatch(requestJSON: String, pluginId: String) throws -> String? {
        let request = try JSONDecoder().decode([String: PluginJSONValue].self, from: Data(requestJSON.utf8))
        guard request["fqcn"] == .string("exteraless.ios.Runtime"),
              case let .string(member)? = request["member"], exportedMethods["exteraless.ios.Runtime"]?.contains(member) == true else { return nil }
        guard request["op"] == .string("call"), case let .array(args)? = request["args"],
              let host, let owner = host.callbackOwner(id: pluginId), request["ownerToken"] == .string(owner.wireToken) else {
            throw BridgeFailure.permission("SDK DTO fixture requires the current immutable C owner epoch")
        }
        lock.lock(); counts[member, default: 0] += 1; epochs.insert(owner.wireToken); lock.unlock()
        func count(_ expected: Int) throws {
            guard args.count == expected else { throw BridgeFailure.malformed("\(member): expected \(expected) arguments") }
        }
        var result: PluginJSONValue = .null
        switch member {
        case "sdkFixtureEcho":
            try count(1); result = args[0]
        case "sdkFixtureOwner":
            try count(0); result = .string(owner.wireToken)
        case "uiRefreshSettings":
            try count(0); lock.lock(); refreshes += 1; lock.unlock()
        case "uiPresent":
            try count(3)
            guard args[0] == .string("alert"), case let .object(model) = args[1],
                  model["title"] != nil, case let .object(rawHandles) = args[2] else {
                throw BridgeFailure.unimplemented("SDK fixture records only the declared alert DTO")
            }
            var handles: [String: Int64] = [:]
            for (name, value) in rawHandles { handles[name] = try handle(value) }
            guard Set(handles.keys) == Set(["positive", "negative", "neutral", "item", "dismiss", "cancel", "back", "change", "closed"]),
                  Set(handles.values).count == 9 else { throw BridgeFailure.malformed("SDK fixture requires distinct stable callbacks and terminal bookkeeping") }
            _ = try validateWidgetModel(args[1])
            let id = UUID().uuidString
            lock.lock(); presentations[id] = Entry(owner: owner, handles: handles, model: args[1]); lock.unlock()
            result = .object(["id": .string(id)])
        case "uiState":
            try count(1)
            let id = try string(args[0])
            lock.lock(); let entry = presentations[id]; lock.unlock()
            guard entry?.owner == owner else { throw BridgeFailure.invalidHandle("unknown SDK fixture presentation") }
            // This is a DTO recorder, not a fake UIKit appearance observation.
            result = .object(["visible": .bool(false), "isPresented": .bool(false), "fixture": .bool(true)])
        case "uiUpdate":
            try count(2)
            _ = try validateWidgetModel(args[1])
            let id = try string(args[0])
            lock.lock(); let previous = presentations[id]
            if let previous, previous.owner == owner {
                presentations[id] = Entry(owner: owner, handles: previous.handles, model: args[1])
            }
            lock.unlock()
            guard previous?.owner == owner else { throw BridgeFailure.invalidHandle("unknown SDK fixture presentation") }
        case "uiDismiss":
            try count(1)
            let id = try string(args[0])
            lock.lock(); let entry = presentations.removeValue(forKey: id); lock.unlock()
            if let entry { callbacks.release(entry.owner, Array(entry.handles.values)) }
        case "postToOwner":
            try count(3)
            guard args[1] == .integer(0), args[2] == .string("PLUGINS_QUEUE") else {
                throw BridgeFailure.unimplemented("SDK fixture task requires zero-delay PLUGINS_QUEUE")
            }
            let id = UUID().uuidString
            let entry = Entry(owner: owner, handles: ["run": try handle(args[0])], model: .null)
            lock.lock(); tasks[id] = entry; lock.unlock()
            result = .object(["id": .string(id)])
        case "cancelOwnerTask", "tlCancel":
            try count(1)
            let id = try string(args[0])
            lock.lock()
            let entry = member == "tlCancel" ? requests.removeValue(forKey: id) : tasks.removeValue(forKey: id)
            lock.unlock()
            if let entry { callbacks.release(entry.owner, Array(entry.handles.values)) }
            result = member == "tlCancel" ? .object(["cancelled": .bool(entry != nil)]) : .bool(entry != nil)
        case "tlRequest":
            try count(2)
            guard case let .object(model) = args[0], model["schemaVersion"] == .integer(1),
                  model["account"] == .integer(2), case let .object(tl)? = model["request"],
                  tl == ["_": .string("users.getUsers"), "id": .array([.object(["_": .string("inputUserSelf")])])] else {
                throw BridgeFailure.unimplemented("SDK fixture records only users.getUsers(InputUserSelf) DTO")
            }
            let id = UUID().uuidString
            let entry = Entry(owner: owner, handles: ["run": try handle(args[1])], model: args[0])
            lock.lock(); requests[id] = entry; lock.unlock()
            result = .object(["requestId": .string(id)])
        case "logEvent":
            try count(1)
            guard case let .object(model) = args[0], model["level"] != nil, model["message"] != nil else {
                throw BridgeFailure.malformed("invalid SDK fixture log DTO")
            }
        default: return nil
        }
        return try PluginBridgeJSON.success(result)
    }

    func completeUI(checks: Int64) async throws {
        let entries = takePresentations()
        guard entries.count == 1, let (id, entry) = entries.first else {
            throw BridgeFailure.malformed("SDK fixture expected one UI lease")
        }
        let inputId = try validateWidgetModel(entry.model)
        guard case let .object(model) = entry.model,
              model["title"] == .string("SDK live DTO fixture"), model["message"] == .string("Live native DTO"),
              model["messageClickable"] == .bool(true), model["blurredBackground"] == .bool(true), model["blurBehind"] == .bool(false),
              model["items"] == .array([.object(["text": .string("Fresh"), "icon": .string("sf:checkmark")])]),
              case let .array(buttons)? = model["buttons"], case let .object(button)? = buttons.first,
              button["text"] == .string("Record updated") else { throw BridgeFailure.malformed("SDK live Builder model did not reach native") }
        for name in ["item", "positive", "dismiss", "closed"] {
            guard let handle = entry.handles[name] else { continue }
            var payload: [String: PluginJSONValue] = ["id": .string(id), "event": .string(name),
                "which": .integer(name == "item" ? 0 : -1), "reason": .string("fixture-terminal")]
            if name == "item" || name == "positive" {
                payload["values"] = .object([inputId: .string(name == "item" ? "fixture item 雪\u{0}π" : "fixture click 雪\u{0}π")])
            }
            let event: PluginJSONValue = .array([.object(payload)])
            guard callbacks.callback(entry.owner, handle, "__call__", try json(event)) else {
                callbacks.release(entry.owner, Array(entry.handles.values))
                throw BridgeFailure.unavailable("SDK fixture terminal callback admission failed")
            }
        }
        guard callbacks.release(entry.owner, Array(entry.handles.values)) else {
            throw BridgeFailure.unavailable("SDK fixture UI release admission failed")
        }
        try await barrier(owner: entry.owner, checks: checks)
    }

    func completeTask(checks: Int64) async throws -> PluginJSONValue {
        let entries = takeTasks()
        guard entries.count == 1, let entry = entries.values.first, let handle = entry.handles["run"] else {
            throw BridgeFailure.malformed("SDK fixture expected one owner task")
        }
        let result: String
        do {
            result = try await callbacks.result(entry.owner, handle, "run", "[]")
        } catch {
            callbacks.release(entry.owner, [handle])
            throw error
        }
        guard callbacks.release(entry.owner, [handle]) else { throw BridgeFailure.unavailable("SDK fixture task release admission failed") }
        try await barrier(owner: entry.owner, checks: checks)
        return try JSONDecoder().decode(PluginJSONValue.self, from: Data(result.utf8))
    }

    func completeRequest(checks: Int64) async throws {
        let entries = takeRequests()
        guard entries.count == 1, let entry = entries.values.first, let handle = entry.handles["run"] else {
            throw BridgeFailure.malformed("SDK fixture expected one request DTO")
        }
        let response: PluginJSONValue = .array([.array([.object(["_": .string("userEmpty"), "id": .integer(101)])]), .null])
        do {
            let result = try await callbacks.result(entry.owner, handle, "run", try json(response))
            guard result == "null" else { throw BridgeFailure.malformed("SDK request callback exported an ignored result") }
        } catch {
            callbacks.release(entry.owner, [handle])
            throw error
        }
        guard callbacks.release(entry.owner, [handle]) else { throw BridgeFailure.unavailable("SDK fixture request release admission failed") }
        try await barrier(owner: entry.owner, checks: checks)
    }

    func releaseInstances(pluginId: String) {
        lock.lock()
        presentations = presentations.filter { $0.value.owner.pluginId != pluginId }
        tasks = tasks.filter { $0.value.owner.pluginId != pluginId }
        requests = requests.filter { $0.value.owner.pluginId != pluginId }
        lock.unlock()
        // PluginHost unload already sweeps C refs on the retired interpreter.
    }

    var observation: PluginJSONValue {
        lock.lock(); defer { lock.unlock() }
        return .object(["boundary": .string("Foundation DTO recorder; no UIKit/network/server acceptance"),
            "methodCounts": .object(counts.mapValues { .integer(Int64($0)) }),
            "epochs": .array(epochs.sorted().map(PluginJSONValue.string)), "refreshes": .integer(Int64(refreshes)),
            "liveUI": .integer(Int64(presentations.count)), "liveTasks": .integer(Int64(tasks.count)),
            "liveRequests": .integer(Int64(requests.count))])
    }

    private func barrier(owner: PluginHost.CallbackOwner, checks: Int64) async throws {
        let result = try await callbacks.result(owner, checks, "barrier", "[]")
        guard result == "null" else { throw BridgeFailure.malformed("SDK fixture FIFO fence returned a non-void result") }
    }
    private func validateWidgetModel(_ value: PluginJSONValue) throws -> String {
        guard case let .object(model) = value, model["style"] == .string("message"), model["cancelable"] == .bool(true),
              case let .object(view)? = model["view"], view["type"] == .string("column"),
              view["padding"] == .array([.integer(4), .integer(6), .integer(4), .integer(6)]),
              view["layout"] == .object(["height": .integer(96)]),
              case let .array(children)? = view["children"], children.count == 2,
              case let .object(input) = children[0], case let .string(inputId)? = input["id"],
              input["type"] == .string("input"), input["value"] == .string("draft"),
              input["font"] == .object(["name": .string("monospace"), "size": .integer(18)]),
              input["layout"] == .object(["width": .integer(-1), "height": .integer(40), "weight": .integer(1),
                  "margins": .array([.integer(1), .integer(2), .integer(3), .integer(4)])]),
              case let .object(image) = children[1], image["type"] == .string("image"),
              image["image"] == .string("sf:checkmark.circle"),
              image["layout"] == .object(["width": .integer(24), "height": .integer(24), "weight": .integer(0),
                  "margins": .array([.integer(0), .integer(0), .integer(0), .integer(0)])]) else {
            throw BridgeFailure.malformed("SDK fixture widget padding/layout/font/image DTO differs from the native contract")
        }
        return inputId
    }
    private func takePresentations() -> [String: Entry] { lock.lock(); defer { lock.unlock() }; defer { presentations.removeAll() }; return presentations }
    private func takeTasks() -> [String: Entry] { lock.lock(); defer { lock.unlock() }; defer { tasks.removeAll() }; return tasks }
    private func takeRequests() -> [String: Entry] { lock.lock(); defer { lock.unlock() }; defer { requests.removeAll() }; return requests }
    private func string(_ value: PluginJSONValue) throws -> String {
        guard case let .string(result) = value, !result.isEmpty else { throw BridgeFailure.malformed("expected nonempty fixture string") }
        return result
    }
    private func handle(_ value: PluginJSONValue) throws -> Int64 {
        guard case let .object(marker) = value, case let .integer(value)? = marker["__handle__"], value > 0 else {
            throw BridgeFailure.invalidHandle("SDK fixture callback must be a positive C handle")
        }
        return value
    }
    private func json(_ value: PluginJSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
