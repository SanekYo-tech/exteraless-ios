#if PLUGIN_UI_FIXTURE
import Foundation

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw FixtureFailure(description: message) }
}

private func expectFailure(_ kind: String, _ body: () throws -> Void) throws {
    do { try body() }
    catch let error as PluginUIFailure {
        try expect(error.kind == kind, "Expected \(kind), got \(error.kind): \(error.message)")
        return
    }
    throw FixtureFailure(description: "Expected \(kind), operation succeeded")
}

private func callback(_ id: Int64) throws -> PluginUICallback {
    return try PluginUICallback(.object(["__handle__": .integer(id)]))
}

private func model(_ json: String = "{}", kind: PluginUIPresentationKind = .alert) throws -> PluginUIModel {
    return try PluginUIModel(kind: kind, value: PluginUIJSON.decode(json))
}

private typealias Store = PluginUILeaseStore<String>

private func readyStore(limits: Store.Limits = Store.Limits()) -> Store {
    let store = Store(limits: limits)
    _ = store.replaceScope(accountRecordId: 42)
    return store
}

private func eventName(_ delivery: Store.Delivery?) -> String? {
    return delivery?.arguments.array?.first?.object?["event"]?.string
}

private final class Decisions: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = 0
    func add(_ value: Bool) { self.lock.lock(); if value { self.accepted += 1 }; self.lock.unlock() }
    var count: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.accepted }
}

private final class BoundedMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private var owner = "p:1"
    private var accepted: [String] = []
    func isCurrent(_ value: String) -> Bool { self.lock.lock(); defer { self.lock.unlock() }; return value == self.owner }
    func admit(_ value: String) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.occupied else { return false }
        self.occupied = true
        self.accepted.append(value)
        return true
    }
    func complete() { self.lock.lock(); self.occupied = false; self.lock.unlock() }
    func replaceOwner() { self.lock.lock(); self.owner = "p:2"; self.lock.unlock() }
    var trace: [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.accepted }
}

@main private enum PluginUIFixture {
    static func main() async throws {
        let scenarios: [(String, () async throws -> Void)] = [
            ("strict C handle DTO", self.handles),
            ("unhandled large request isolation", self.unhandled),
            ("actual visibility", self.visibility),
            ("dismiss before presentation", self.dismissBeforeAppearance),
            ("rendered revision rejects old buttons", self.staleRevision),
            ("action versus dismiss race", self.racingActions),
            ("owner/cross-plugin isolation", self.ownership),
            ("account A-B-A scope", self.accountSwitch),
            ("callback lease isolation", self.uniqueHandles),
            ("terminal order and exactly-once release", self.terminalOrder),
            ("undo commit versus undo", self.undo),
            ("presentation failure cleanup", self.presentationFailure),
            ("bounded live/history state", self.limits),
            ("read-only MVEL subset", self.conditions),
            ("large peer integer comparison", self.integerConditions),
            ("portable widget/schema validation", self.widgets),
            ("native source cannot be retargeted", self.sourceRetarget),
            ("removed registrations cannot dispatch", self.menuRemoval),
            ("queued callbacks recheck account scope", self.queuedCallbackScope),
            ("global menus survive account changes safely", self.menuAccountSwitch),
            ("share-file roots and symlink escapes", self.shareFiles),
            ("settings refresh and callback schema", self.settingsRefresh),
            ("atomic menu replacement at quota", self.menuReplacement),
            ("input value budget and replacement pruning", self.inputBudget),
            ("C-origin owner token validation", self.ownerToken),
            ("stale C owner cannot replace a current menu", self.originAdmission),
            ("portable padding and layout bounds", self.layoutModel),
            ("named image/font errors and UI effects", self.styleModel),
            ("manager pin order and persistent controls", self.managerPreferences),
            ("developer protocol authentication and upload bounds", self.developerProtocol),
            ("terminal callback and release backpressure", self.cleanupBackpressure),
            ("final callbacks survive history pressure within their scope", self.finalCallbackHistory),
            ("retired cleanup never enters a replacement owner", self.cleanupOwnerReplacement),
            ("automatic native early-start recovery and notices", self.runtimeRecovery),
            ("healthy and attributed starts reset recovery", self.healthyRecovery),
            ("one-shot maintenance cleanup survives caller cancellation", self.maintenanceCompletion)
        ]
        for (name, scenario) in scenarios {
            do { try await scenario() }
            catch { throw FixtureFailure(description: "\(name): \(error)") }
        }
        print("PluginUI Foundation fixture: \(scenarios.count) scenarios passed; no UIKit/account/network effects")
    }

    private static func handles() throws {
        for raw in ["{\"__handle__\":0}", "{\"__handle__\":-7}", "{\"__handle__\":true}", "{\"__handle__\":1.25}", "{\"pointer\":123}", "123"] {
            try expectFailure("InvalidHandle") { _ = try PluginUICallback(PluginUIJSON.decode(raw)) }
        }
        try expectFailure("InvalidHandle") {
            _ = try PluginUICallback(PluginUIJSON.decode("{\"__handle__\":3,\"__fqcn__\":\"a\",\"__fqcn\":\"b\"}"))
        }
        try expect(try callback(9007199254740993).handle == 9007199254740993, "Handle was rounded through Double")
        let value = try PluginUIJSON.decode("{\"n\":9223372036854775807,\"boolean\":false}")
        try expect(value.object?["n"] == .integer(Int64.max), "Int64 JSON was rounded")
        try expect(try PluginUIJSON.decode(value.encoded()) == value, "JSON round trip changed typed values")
    }

    private static func unhandled() throws {
        let data = String(repeating: "x", count: 600_000)
        let request = PluginUIJSON.object(["fqcn": .string(PluginUIRequest.runtime), "member": .string("tlRequest"), "args": .array([.string(data)])])
        try expect(try PluginUIRequest.claimed(request.encoded()) == nil, "UI provider claimed another provider's large request")
        let ui = PluginUIJSON.object(["fqcn": .string(PluginUIRequest.runtime), "member": .string("uiPresent"), "args": .array([.string(data)])])
        try expectFailure("MalformedRequest") { _ = try PluginUIRequest.claimed(ui.encoded()) }
    }

    private static func visibility() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["show": callback(1)])
        try expect(!entry.state.isPresented, "Acceptance fabricated presentation")
        let pending = store.beginPresentation(id: entry.state.id)
        try expect(pending?.state.phase == .presenting && pending?.state.isPresented == false, "Queued show fabricated visibility")
        try expect(eventName(store.observeVisibility(id: entry.state.id, visible: true)) == "show", "First actual appearance did not deliver show")
        try expect(store.observeVisibility(id: entry.state.id, visible: true) == nil, "Show callback delivered twice")
        _ = store.observeVisibility(id: entry.state.id, visible: false)
        try expect(try !store.state(id: entry.state.id, pluginId: "p").isPresented, "Native disappearance left visible=true")
    }

    private static func dismissBeforeAppearance() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["dismiss": callback(2), "closed": callback(3)])
        _ = try store.beginDismiss(id: entry.state.id, pluginId: "p", reason: "programmatic")
        try expect(store.beginPresentation(id: entry.state.id) == nil, "A queued show resurrected a cancelled lease")
        guard let retired = store.finish(id: entry.state.id) else { throw FixtureFailure(description: "No retirement") }
        try expect(retired.deliveries.map { eventName($0) } == ["closed"], "A never-presented controller emitted dismiss")
        try expect(retired.handles == [2, 3], "Cancelled acceptance leaked callbacks")
    }

    private static func staleRevision() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model("{\"title\":\"Old\"}")), callbacks: ["positive": callback(4)])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let updated = try store.update(id: entry.state.id, pluginId: "p", patch: .object(["title": .string("New")]))
        let old = store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "positive", payload: [:], dismissReason: "button")
        try expect(!old.accepted && old.delivery == nil, "Old rendered button entered a new model")
        let current = store.action(id: entry.state.id, revision: updated.state.revision, scope: entry.state.scope, name: "positive", payload: ["which": .integer(-1)], dismissReason: "button")
        try expect(current.accepted && eventName(current.delivery) == "positive", "Current native button did not dispatch")
        try expectFailure("InvalidHandle") { _ = try store.update(id: entry.state.id, pluginId: "p", patch: .object([:])) }
    }

    private static func racingActions() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(5)])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let decisions = Decisions()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index % 2 == 0 {
                decisions.add(store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "positive", payload: [:], dismissReason: "button").accepted)
            } else {
                _ = try? store.beginDismiss(id: entry.state.id, pluginId: "p", reason: "programmatic")
            }
        }
        try expect(decisions.count <= 1, "Repeated/racing taps dispatched more than once")
        try expect(store.entry(id: entry.state.id)?.state.phase == .dismissing, "Race did not settle in dismissal")
        try expect(store.finish(id: entry.state.id) != nil && store.finish(id: entry.state.id) == nil, "Race released handles more than once")
    }

    private static func ownership() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "alice", owner: "alice:1", content: .presentation(model()), callbacks: [:])
        try expectFailure("SecurityError") { _ = try store.state(id: entry.state.id, pluginId: "bob") }
        try expectFailure("SecurityError") { _ = try store.beginDismiss(id: entry.state.id, pluginId: "bob", reason: "foreign") }
        try expect(store.release(pluginId: "bob").isEmpty && store.liveCount == 1, "Foreign unload removed another plugin's UI")
        let unloaded = store.release(pluginId: "alice")
        try expect(unloaded.count == 1 && unloaded[0].deliveries.isEmpty, "Unload called Python")
    }

    private static func accountSwitch() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(6), "dismiss": callback(7), "closed": callback(8)])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let retired = store.replaceScope(accountRecordId: 43)
        try expect(retired.count == 1 && retired[0].deliveries.isEmpty && retired[0].handles == [6, 7, 8], "Account change must release via release_handles_json without entering user callbacks")
        _ = store.replaceScope(accountRecordId: 42)
        try expect(store.currentScope != entry.state.scope, "Returning to account A reused its old scope")
        try expect(!store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "positive", payload: [:]).accepted, "Account A's obsolete button dispatched")
    }

    private static func uniqueHandles() throws {
        let store = readyStore()
        let first = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(9), "dismiss": callback(9)])
        try expectFailure("InvalidHandle") { _ = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(9)]) }
        let independent = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(10)])
        let other = try store.accept(pluginId: "other", owner: "other:1", content: .presentation(model()), callbacks: ["positive": callback(9)])
        try expect(store.finish(id: first.state.id)?.handles == [9], "Shared slots within a lease released the same C handle twice")
        try expect(store.entry(id: independent.state.id) != nil && store.entry(id: other.state.id) != nil, "Closing one UI lease invalidated another")
    }

    private static func terminalOrder() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(11), "dismiss": callback(12), "closed": callback(13)])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let clicked = store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "positive", payload: ["which": .integer(-1)], dismissReason: "button")
        let end = store.finish(id: entry.state.id)
        try expect([eventName(clicked.delivery)] + (end?.deliveries.map { eventName($0) } ?? []) == ["positive", "dismiss", "closed"], "Terminal callback order is wrong")
        try expect(end?.handles == [11, 12, 13] && store.finish(id: entry.state.id) == nil, "Callback handles were not released exactly once")
        let state = try store.state(id: entry.state.id, pluginId: "p")
        try expect(state.phase == .closed && !state.isPresented && state.reason == "button", "Terminal state lost its actual reason")
    }

    private static func undo() throws {
        for undone in [false, true] {
            let store = readyStore()
            let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model("{\"text\":\"Undoable\",\"style\":\"undo\"}", kind: .bulletin)), callbacks: ["undo": callback(14), "action": callback(15), "dismiss": callback(16), "closed": callback(17)])
            _ = store.beginPresentation(id: entry.state.id)
            _ = store.observeVisibility(id: entry.state.id, visible: true)
            var first: [String?] = []
            if undone { first = [eventName(store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "undo", payload: [:], dismissReason: "undo").delivery)] }
            else { _ = try store.beginDismiss(id: entry.state.id, pluginId: "p", reason: "programmatic") }
            let end = store.finish(id: entry.state.id)
            try expect(first + (end?.deliveries.map { eventName($0) } ?? []) == (undone ? ["undo", "dismiss", "closed"] : ["action", "dismiss", "closed"]), "Undo committed after undo, or failed to commit on ordinary detach")
        }
    }

    private static func presentationFailure() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["error": callback(18), "dismiss": callback(19), "closed": callback(20)])
        _ = store.beginPresentation(id: entry.state.id)
        let end = store.finish(id: entry.state.id, reason: "failed", failure: .unavailable("No window"))
        try expect(end?.deliveries.map { eventName($0) } == ["error", "closed"], "Failed presentation emitted success/dismiss")
        try expect(try store.state(id: entry.state.id, pluginId: "p").phase == .failed, "Failure was reported as a shown controller")
    }

    private static func limits() throws {
        let store = readyStore(limits: Store.Limits(presentationsPerPlugin: 1, presentations: 2, menusPerPlugin: 1, menus: 2, terminalHistory: 2))
        let a = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["closed": callback(21)])
        try expectFailure("ServiceUnavailable") { _ = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["closed": callback(22)]) }
        if let retirement = store.finish(id: a.state.id) { store.completeRetirement(id: retirement.id, owner: retirement.owner) }
        for i in 22...23 {
            let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["closed": callback(Int64(i))])
            if let retirement = store.finish(id: entry.state.id) { store.completeRetirement(id: retirement.id, owner: retirement.owner) }
        }
        try expectFailure("InvalidHandle") { _ = try store.state(id: a.state.id, pluginId: "p") }
        try expect(store.liveCount == 0, "Bounded history retained live leases")
    }

    private static func conditions() throws {
        let condition = try PluginUIMenuCondition("message != null && !message.isOutOwner() && (user.bot == true || chat != null)")
        let context: [String: PluginUIJSON] = ["message": .object(["isOutOwner": .bool(false)]), "user": .object(["bot": .bool(true)]), "chat": .null]
        try expect(condition.matches(context), "Common Android menu condition failed")
        try expect(!condition.matches(["message": .null]), "Missing message passed a message-only condition")
        for code in ["new java.io.File('x')", "message.getClass()", "user.unknown", "account = 1", "while(true)", "message.getId(5)"] {
            try expectFailure("Unimplemented") { _ = try PluginUIMenuCondition(code) }
        }
    }

    private static func integerConditions() throws {
        let id: Int64 = 9007199254740993
        try expect(try PluginUIMenuCondition("dialog_id != 9007199254740992").matches(["dialog_id": .integer(id)]), "56-bit peer comparison was rounded through Double")
        try expect(try PluginUIMenuCondition("dialog_id > 9007199254740992").matches(["dialog_id": .integer(id)]), "56-bit peer ordering was rounded")
    }

    private static func widgets() throws {
        let value = try model("{\"view\":{\"type\":\"column\",\"id\":\"group\",\"children\":[{\"type\":\"input\",\"id\":\"draft\",\"value\":\"Привет 🌐\"},{\"type\":\"slider\",\"id\":\"rate\",\"min\":0,\"max\":1,\"step\":0.3,\"value\":0.99}]}}")
        try expect(value.widgets.first?.children.count == 2, "Portable view tree was not decoded")
        let range = try PluginUIRange(minimum: 0, maximum: 1, step: 0.3)
        try expect(abs(range.normalize(0.99) - 0.9) < 0.00001, "Slider differs from SDK half-up quantization")
        try expectFailure("Unimplemented") { _ = try model("{\"view\":{\"__handle__\":99}}") }
        try expectFailure("MalformedRequest") { _ = try model("{\"view\":{\"type\":\"slider\",\"min\":1,\"max\":1}}") }
        try expectFailure("MalformedRequest") { _ = try model("{\"items\":[{\"id\":\"a\",\"text\":\"A\"},{\"id\":\"a\",\"text\":\"B\"}]}") }
        try expectFailure("MalformedRequest") { _ = try model("{\"view\":{\"type\":\"selector\",\"items\":[\"A\"],\"value\":9}}") }
        try expectFailure("Unimplemented") { _ = try model("{\"topAnimation\":123}") }
        try expectFailure("MalformedRequest") { _ = try model("{\"view\":{\"type\":\"text\",\"callback_id\":123}}") }
        let terminalWidget = try model("{\"view\":{\"type\":\"text\",\"callback_id\":\"closed\"}}")
        try expectFailure("InvalidHandle") { try terminalWidget.validateCallbacks(["closed"]) }
    }

    private static func sourceRetarget() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let original = try model("{\"title\":\"Pinned\",\"sourceId\":\"\(first)\"}")
        try expectFailure("InvalidHandle") { _ = try original.applying(.object(["sourceId": .string(second)])) }
        let updated = try original.applying(.object(["progress": .integer(20)]))
        try expect(updated.title == "Pinned" && updated.sourceId == original.sourceId, "Partial update dropped captured source or content")
    }

    private static func menuRemoval() throws {
        let store = readyStore()
        let menu = try PluginUIMenuModel(PluginUIJSON.decode("{\"menu_type\":\"MESSAGE_CONTEXT_MENU\",\"text\":\"Run\",\"condition\":\"message != null\"}"))
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .menu(menu), callbacks: ["click": callback(24)])
        try expect(!entry.state.isPresented && entry.state.phase == .registered, "Menu registration fabricated presentation")
        _ = store.finish(id: entry.state.id, reason: "removed", notify: false)
        try expect(!store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "click", payload: [:]).accepted, "A removed menu row dispatched a callback")
    }

    private static func queuedCallbackScope() throws {
        let store = readyStore()
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(25), "closed": callback(26)])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let decision = store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "positive", payload: [:], dismissReason: "button")
        guard let metadata = decision.delivery?.arguments.array?.first?.object else { throw FixtureFailure(description: "Missing callback metadata") }
        let end = store.finish(id: entry.state.id)
        try expect(store.permitsCallback(pluginId: "p", metadata: metadata), "Normal dismissal incorrectly cancelled its accepted button action")
        _ = store.replaceScope(accountRecordId: 99)
        try expect(!store.permitsCallback(pluginId: "p", metadata: metadata), "Queued action entered Python on another account")
        guard let closed = end?.deliveries.last?.arguments.array?.first?.object else { throw FixtureFailure(description: "No closed bookkeeping") }
        try expect(store.permitsCallback(pluginId: "p", metadata: closed), "Account switch lost terminal lease bookkeeping")
    }

    private static func menuAccountSwitch() throws {
        let store = readyStore()
        let menu = try PluginUIMenuModel(PluginUIJSON.decode("{\"menu_type\":\"MAIN_MENU\",\"text\":\"Open\"}"))
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .menu(menu), callbacks: ["click": callback(27)])
        let retired = store.replaceScope(accountRecordId: nil)
        try expect(retired.isEmpty && store.menus().isEmpty, "Clearing account prematurely released global menu callbacks")
        _ = store.replaceScope(accountRecordId: 100)
        guard let rebound = store.menus().first else { throw FixtureFailure(description: "Global menu was lost after account switch") }
        try expect(rebound.state.id == entry.state.id && rebound.state.revision != entry.state.revision, "Menu rebind lost identity or reused its old snapshot")
        try expect(!store.action(id: entry.state.id, revision: entry.state.revision, scope: entry.state.scope, name: "click", payload: [:]).accepted, "Old account's rendered menu remained callable")
        try expect(store.action(id: rebound.state.id, revision: rebound.state.revision, scope: rebound.state.scope, name: "click", payload: [:]).accepted, "Menu on the new account is inert")
    }

    private static func shareFiles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-ui-policy-\(UUID().uuidString)", isDirectory: true)
        let owned = temporary.appendingPathComponent("owned", isDirectory: true)
        let sibling = temporary.appendingPathComponent("owned-other", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let ownFile = owned.appendingPathComponent("file.txt")
        let external = sibling.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: ownFile)
        try Data("fixture".utf8).write(to: external)
        try expect(try PluginUIShareFiles.resolve(path: ownFile.path, allowedRoots: [owned], allowExternal: false) == ownFile.resolvingSymlinksInPath(), "Own regular file was denied")
        try expectFailure("SecurityError") { _ = try PluginUIShareFiles.resolve(path: external.path, allowedRoots: [owned], allowExternal: false) }
        let escape = owned.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: external)
        try expectFailure("SecurityError") { _ = try PluginUIShareFiles.resolve(path: escape.path, allowedRoots: [owned], allowExternal: false) }
        try expect(try PluginUIShareFiles.resolve(path: external.path, allowedRoots: [owned], allowExternal: true) == external.resolvingSymlinksInPath(), "Granted external file was denied")
        try expectFailure("ServiceUnavailable") { _ = try PluginUIShareFiles.resolve(path: owned.path, allowedRoots: [owned], allowExternal: true) }
    }

    private static func settingsRefresh() throws {
        let store = readyStore()
        let initial = try model("{\"rows\":[{\"type\":\"text\",\"id\":\"a\",\"text\":\"Action\",\"callback_id\":\"click_a\"}]}", kind: .settings)
        try expectFailure("InvalidHandle") { _ = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(initial), callbacks: [:]) }
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(initial), callbacks: ["action": callback(28), "refresh": callback(29)])
        try expect(eventName(store.refresh(id: entry.state.id)) == "refresh", "Real settings refresh did not schedule its owner callback")
        let update = try PluginUIJSON.decode("{\"rows\":[{\"type\":\"text\",\"id\":\"b\",\"text\":\"New\",\"callback_id\":\"click_b\"}]}")
        _ = try store.update(id: entry.state.id, pluginId: "p", patch: update)
        _ = try store.beginDismiss(id: entry.state.id, pluginId: "p", reason: "programmatic")
        try expect(store.refresh(id: entry.state.id) == nil, "A closing settings page scheduled a new read")
    }

    private static func menuReplacement() throws {
        let store = readyStore(limits: Store.Limits(presentationsPerPlugin: 1, presentations: 1, menusPerPlugin: 1, menus: 1, terminalHistory: 4))
        let menu = try PluginUIMenuModel(PluginUIJSON.decode("{\"menu_type\":\"MAIN_MENU\",\"text\":\"One\",\"item_id\":\"stable\"}"))
        let first = try store.registerMenu(pluginId: "p", owner: "p:1", model: menu, callback: callback(30))
        let queued = store.action(id: first.entry.state.id, revision: 0, scope: first.entry.state.scope, name: "click", payload: [:])
        let second = try store.registerMenu(pluginId: "p", owner: "p:1", model: menu, callback: callback(31))
        try expect(store.liveCount == 1 && second.retired.count == 1 && second.retired[0].handles == [30], "Replacement leaked a callback or needed a spare quota slot")
        try expect(store.menuId(pluginId: "p", itemId: "stable") == second.entry.state.id && store.menuId(pluginId: "other", itemId: "stable") == nil, "Original item_id removal is not plugin-scoped")
        guard let metadata = queued.delivery?.arguments.array?.first?.object else { throw FixtureFailure(description: "No queued menu metadata") }
        try expect(!store.permitsCallback(pluginId: "p", metadata: metadata), "A replaced menu callback remained runnable")
    }

    private static func inputBudget() throws {
        let store = readyStore(limits: Store.Limits(valueBytes: 64))
        let initial = try model("{\"input\":{\"type\":\"input\",\"id\":\"x\",\"value\":\"\"}}")
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(initial), callbacks: [:])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let large = store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "change", payload: ["key": .string("x"), "value": .string(String(repeating: "a", count: 80))])
        try expect(!large.accepted && store.entry(id: entry.state.id)?.state.values["x"] == .string(""), "Input crossed aggregate callback budget")
        let change = store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "change", payload: ["key": .string("x"), "value": .string("accepted")])
        try expect(change.accepted, "In-budget input was rejected")
        _ = try store.update(id: entry.state.id, pluginId: "p", patch: PluginUIJSON.decode("{\"input\":{\"type\":\"input\",\"id\":\"y\",\"value\":\"new\"}}"))
        try expect(store.entry(id: entry.state.id)?.state.values == ["y": .string("new")], "Removed input keys accumulated across model updates")
        _ = store.finish(id: entry.state.id)
        try expect(try store.state(id: entry.state.id, pluginId: "p").values.isEmpty, "Terminal history retained input drafts")
    }

    private static func ownerToken() throws {
        let epoch = "ABCDEF01-2345-4678-9ABC-DEF012345678"
        let request = try PluginUIRequest.claimed("{\"op\":\"call\",\"fqcn\":\"exteraless.ios.Runtime\",\"member\":\"uiPresent\",\"ownerToken\":\"\(epoch)\",\"args\":[],\"value\":null}")
        guard let request else { throw FixtureFailure(description: "C owner envelope was not claimed") }
        let origin = try PluginUIRequestOrigin(request)
        try origin.validate(currentToken: epoch)
        try expectFailure("SecurityError") { try origin.validate(currentToken: UUID().uuidString) }
        try expectFailure("SecurityError") { try origin.validate(currentToken: epoch.lowercased()) }
        for value in [PluginUIJSON.null, .integer(1), .string(""), .string(String(repeating: "x", count: 257)), .string("old\0new")] {
            try expectFailure("SecurityError") { _ = try PluginUIRequestOrigin(["ownerToken": value]) }
        }
        try expectFailure("SecurityError") { _ = try PluginUIRequestOrigin([:]) }
    }

    private static func originAdmission() throws {
        let store = readyStore()
        let old = try PluginUIRequestOrigin(["ownerToken": .string("old-epoch")])
        try old.validate(currentToken: "old-epoch") // initial generic bridge validation
        let menu = try PluginUIMenuModel(PluginUIJSON.decode("{\"menu_type\":\"MAIN_MENU\",\"item_id\":\"stable\",\"text\":\"Current\"}"))
        let current = try store.registerMenu(pluginId: "p", owner: "p:new", model: menu, callback: callback(101))
        try expectFailure("SecurityError") {
            _ = try store.registerMenu(pluginId: "p", owner: "p:old", model: menu, callback: callback(102),
                admission: { try old.validate(currentToken: "new-epoch") })
        }
        try expect(store.entry(id: current.entry.state.id)?.owner == "p:new" && store.liveCount == 1, "Stale request replaced a new owner's menu")
        try expectFailure("SecurityError") {
            _ = try store.removeMenu(id: current.entry.state.id, pluginId: "p", owner: "p:old",
                admission: { try old.validate(currentToken: "new-epoch") })
        }
        try expect(store.entry(id: current.entry.state.id) != nil, "Stale request removed a new owner's callbacks")
    }

    private static func layoutModel() throws {
        let layout = try PluginUIWidgetLayout(PluginUIJSON.decode("{\"width\":-1,\"height\":-2,\"weight\":2,\"alignment\":\"center\",\"margins\":[4,8,12,16]}"))
        try expect(layout.width == .fill && layout.height == .wrap && layout.weight == 2, "Android portable size aliases were lost")
        try expect(layout.margins.top == 8 && layout.margins.right == 12, "Padding/margin order changed")
        let fitted = PluginUIInsets(top: 3, left: 100, bottom: 4, right: 100).fitting(width: 120)
        try expect(fitted.left + fitted.right == 119 && fitted.left == fitted.right && fitted.top == 3, "Narrow padding produced negative content or changed vertical insets")
        try expectFailure("MalformedRequest") { _ = try PluginUIWidgetLayout(PluginUIJSON.decode("{\"width\":-3}")) }
        try expectFailure("MalformedRequest") { _ = try PluginUIInsets.parse(.array([.integer(1)]), default: .zero, name: "padding") }
    }

    private static func styleModel() throws {
        let presentation = try model("{\"message\":\"https://example.invalid\",\"messageClickable\":true,\"blurredBackground\":true,\"blurBehind\":false,\"view\":{\"type\":\"image\",\"image\":\"sf:photo\",\"icon\":\"msg_info\",\"padding\":[0,2,4,6],\"layout\":{\"width\":40,\"height\":40},\"font\":{\"name\":\"system\",\"size\":18,\"weight\":\"bold\"}}}")
        try expect(presentation.messageClickable && presentation.blurredBackground && !presentation.blurBehind, "Native clickable/blur flags were lost")
        try expect(presentation.widgets.first?.image == "sf:photo" && presentation.widgets.first?.padding.bottom == 6, "Native image/padding fields were lost")
        try expectFailure("ResourceUnavailable") { _ = try PluginUIImages.reference("missing_android_image") }
        try expectFailure("ResourceUnavailable") { _ = try PluginUIImages.reference("bundle:../private") }
        try expectFailure("ResourceUnavailable") { _ = try PluginUIFontSpec(.string("")) }
        try expectFailure("MalformedRequest") { _ = try PluginUIFontSpec(PluginUIJSON.decode("{\"name\":\"system\",\"size\":0}")) }
        try expectFailure("ResourceUnavailable") { _ = try model("{\"view\":{\"type\":\"image\"}}") }
    }

    private static func managerPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-manager-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("manager.json")
        let store = try PluginManagerPreferences(url: file)
        try expect(!store.snapshot.engineEnabled && !store.snapshot.safeMode && !store.snapshot.compactView && !store.snapshot.developerMode && store.snapshot.pinned.isEmpty, "Original manager defaults changed")
        try expect(!store.snapshot.permitsPluginExecution, "Fresh installation started plugins without master enable")
        try store.apply(.engine(true))
        try expect(store.snapshot.permitsPluginExecution, "Master enable did not admit execution")
        try store.apply(.safeMode(true))
        try expect(!store.snapshot.permitsPluginExecution, "Safe mode admitted plugin execution")
        try store.apply(.pinned("zeta", true))
        try store.apply(.compact(true))
        try store.apply(.developer(true))
        try store.apply(.warningMuted("zeta", true))
        let restored = try PluginManagerPreferences(url: file).snapshot
        try expect(restored.compactView && restored.developerMode && restored.warningMuted.contains("zeta"), "Manager settings did not persist")
        try expect(restored.precedes(id: "zeta", title: "Zeta", id: "alpha", title: "Alpha"), "Pinned plugin did not sort first")
        try expect(!restored.precedes(id: "alpha", title: "Alpha", id: "zeta", title: "Zeta"), "Alphabetical sorting overrode pin")
        try store.apply(.remove("zeta"))
        try expect(store.snapshot.pinned.isEmpty && store.snapshot.warningMuted.isEmpty, "Uninstall retained per-plugin preferences")
        try expectFailure("MalformedRequest") { try store.apply(.pinned("../foreign", true)) }
        try expect(store.snapshot.pinned.isEmpty, "Rejected preference mutation was published")
        let confirmed = store.snapshot
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            try store.apply(.safeMode(false))
            throw FixtureFailure(description: "A failed preference write reported success")
        } catch is FixtureFailure { throw FixtureFailure(description: "A failed preference write reported success") }
        catch { try expect(store.snapshot == confirmed, "Failed persistence published a new runtime mode") }
        let legacy = directory.appendingPathComponent("legacy.json")
        try Data("{\"compactView\":true}".utf8).write(to: legacy)
        try expect(try PluginManagerPreferences(url: legacy).snapshot.engineEnabled, "Existing native manager file lost its prior automatic engine mode")
        let upgrade = directory.appendingPathComponent("upgrade.json")
        _ = try PluginManagerPreferences(url: upgrade, legacyEngineEnabled: true)
        try expect(try PluginManagerPreferences(url: upgrade).snapshot.engineEnabled, "Upgrade decision was recomputed instead of persisted")
    }

    private static func developerProtocol() throws {
        let token = "0123456789abcdef0123456789abcdef"
        var lines = Data((String(repeating: " \r\n", count: 1000) + "{\"@\":\"ping\"}\npartial").utf8)
        let framed = PluginDeveloperProtocol.takeLine(from: &lines)
        try expect(framed == Data("{\"@\":\"ping\"}".utf8) && lines == Data("partial".utf8), "Developer framing lost a partial line or recursed through blank input")
        let ping = try PluginDeveloperProtocol.request(Data("{\"@\":\"ping\",\"#\":7}".utf8), token: token)
        try expect(ping["#"] == .integer(7), "Developer request id was lost")
        try expectFailure("SecurityError") { _ = try PluginDeveloperProtocol.request(Data("{\"@\":\"get_plugins\",\"token\":\"bad\"}".utf8), token: token) }
        let source = Data("__id__ = 'fixture'".utf8)
        let request: [String: PluginUIJSON] = ["@": .string("write_plugin"), "#": .string("request"), "token": .string(token), "plugin_id": .string("fixture"), "content": .string(source.base64EncodedString())]
        let parsed = try PluginDeveloperProtocol.request(Data(PluginUIJSON.object(request).encoded().utf8), token: token)
        let upload = try PluginDeveloperProtocol.source(parsed)
        try expect(upload.data == source && upload.filename == "fixture.py", "Developer upload changed the source")
        var invalid = request
        invalid["filename"] = .string("../outside.py")
        try expectFailure("Unimplemented") { _ = try PluginDeveloperProtocol.source(invalid) }
        let response = PluginDeveloperProtocol.response(id: .string("request"), error: "not available")
        try expect(response.object?["#"] == .string("request") && response.object?["ok"] == .bool(false), "Developer failure was reported as success")
        try expect(PluginDeveloperProtocol.echoedId(Data("{\"@\":\"get_plugins\",\"#\":7,\"token\":\"bad\"}".utf8)) == .integer(7), "Authentication error lost original request id")
        invalid["plugin_id"] = .string("../fixture")
        try expectFailure("MalformedRequest") { _ = try PluginDeveloperProtocol.pluginId(invalid) }
        invalid = request
        invalid["content"] = .string(Data(repeating: 65, count: PluginDeveloperProtocol.maximumSourceBytes + 1).base64EncodedString())
        try expectFailure("MalformedRequest") { _ = try PluginDeveloperProtocol.source(invalid) }
        let session = PluginDeveloperSession()
        session.cancel()
        try expect(!session.isActive && PluginDeveloperSession().isActive, "Developer stop reactivated the old authenticated session")
    }

    private static func cleanupQueue(_ store: Store, _ mailbox: BoundedMailbox) -> PluginUIReleaseQueue<String> {
        return PluginUIReleaseQueue(isCurrent: { mailbox.isCurrent($0) }, callback: { delivery in
            mailbox.admit(eventName(delivery) ?? "unknown")
        }, release: { _, handles in mailbox.admit("release:\(handles.map(String.init).joined(separator: ","))") },
        completed: { store.completeRetirement(id: $0.id, owner: $0.owner) })
    }

    private static func cleanupBackpressure() throws {
        let store = readyStore(limits: Store.Limits(presentationsPerPlugin: 1, presentations: 1))
        let mailbox = BoundedMailbox()
        let queue = self.cleanupQueue(store, mailbox)
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["dismiss": callback(201), "closed": callback(202)])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        guard let retired = store.finish(id: entry.state.id) else { throw FixtureFailure(description: "No cleanup batch") }
        queue.retire(retired)
        try expect(mailbox.trace == ["dismiss"], "Full FIFO admitted closed or released a still-live callback")
        try expectFailure("ServiceUnavailable") { _ = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["closed": callback(203)]) }
        mailbox.complete()
        queue.retryPending()
        try expect(mailbox.trace == ["dismiss", "closed"], "Retry duplicated dismiss or released before closed")
        mailbox.complete()
        queue.retryPending()
        queue.retryPending()
        try expect(mailbox.trace == ["dismiss", "closed", "release:201,202"], "Release rejection leaked handles or duplicated callbacks")
        _ = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["closed": callback(203)])
    }

    private static func cleanupOwnerReplacement() throws {
        let store = readyStore(limits: Store.Limits(presentationsPerPlugin: 1, presentations: 1))
        let mailbox = BoundedMailbox()
        let queue = self.cleanupQueue(store, mailbox)
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["closed": callback(204)])
        guard let retired = store.finish(id: entry.state.id) else { throw FixtureFailure(description: "No cleanup batch") }
        queue.retire(retired)
        mailbox.replaceOwner()
        mailbox.complete()
        queue.retryPending()
        try expect(mailbox.trace == ["closed"], "Old native handles were released through a replacement owner")
        _ = try store.accept(pluginId: "p", owner: "p:2", content: .presentation(model()), callbacks: ["closed": callback(204)])
    }

    private static func finalCallbackHistory() throws {
        let store = readyStore(limits: Store.Limits(terminalHistory: 1))
        let entry = try store.accept(pluginId: "p", owner: "p:1", content: .presentation(model()), callbacks: ["positive": callback(205), "dismiss": callback(206)])
        _ = store.beginPresentation(id: entry.state.id)
        _ = store.observeVisibility(id: entry.state.id, visible: true)
        let clicked = store.action(id: entry.state.id, revision: 0, scope: entry.state.scope, name: "positive", payload: [:], dismissReason: "button")
        let retired = store.finish(id: entry.state.id)
        let another = try store.accept(pluginId: "other", owner: "other:1", content: .presentation(model()), callbacks: [:])
        _ = store.finish(id: another.state.id)
        guard let action = clicked.delivery?.arguments.array?.first?.object,
              let terminal = retired?.deliveries.first?.arguments.array?.first?.object else { throw FixtureFailure(description: "Missing final callbacks") }
        try expect(store.permitsCallback(pluginId: "p", metadata: action) && store.permitsCallback(pluginId: "p", metadata: terminal), "History pressure dropped an admitted final action/dismiss")
        try expect(!store.permitsCallback(pluginId: "other", metadata: action), "Final-decision marker bypassed plugin isolation")
        _ = store.replaceScope(accountRecordId: 99)
        try expect(!store.permitsCallback(pluginId: "p", metadata: action) && !store.permitsCallback(pluginId: "p", metadata: terminal), "Final-decision marker bypassed account isolation")
    }

    private static func runtimeRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-recovery-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let first = try PluginRuntimeRecovery(url: url)
        try expect(try !first.beginStart(safeMode: false, hasAttributedPluginMarker: false), "First native launch was a crash")
        for expected in 1...2 {
            let next = try PluginRuntimeRecovery(url: url)
            try expect(try !next.beginStart(safeMode: false, hasAttributedPluginMarker: false), "Automatic safe mode activated before three unclean starts")
            try expect(next.snapshot.earlyUncleanStarts == expected, "Persisted early-start count is wrong")
        }
        let third = try PluginRuntimeRecovery(url: url)
        try expect(try third.beginStart(safeMode: false, hasAttributedPluginMarker: false), "Third unclean start did not request native safe mode")
        try expect(third.snapshot.notice == nil, "Journal claimed safe mode before its policy was persisted")
        let retry = try PluginRuntimeRecovery(url: url)
        try expect(try retry.beginStart(safeMode: false, hasAttributedPluginMarker: false), "Interrupted safe-mode persistence lost the recovery request")
        let manager = try PluginManagerPreferences(url: directory.appendingPathComponent("manager.json"))
        try manager.apply(.engine(true))
        try manager.apply(.safeMode(true))
        try retry.confirmAutomaticSafeMode()
        try retry.recordDisabledPlugin("fixture")
        let restored = try PluginRuntimeRecovery(url: url)
        try expect(restored.snapshot.notice?.contains("Safe mode") == true && restored.snapshot.notice?.contains("fixture") == true, "Startup notices overwrote each other")
        try expect(!manager.snapshot.permitsPluginExecution, "Automatic safe-mode preference allowed execution")
        try restored.acknowledgeNotice()
        try expect(try PluginRuntimeRecovery(url: url).snapshot.notice == nil, "Startup notice was not consumed durably")
    }

    private static func healthyRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-healthy-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        _ = try PluginRuntimeRecovery(url: url).beginStart(safeMode: false, hasAttributedPluginMarker: false)
        let second = try PluginRuntimeRecovery(url: url)
        _ = try second.beginStart(safeMode: false, hasAttributedPluginMarker: false)
        try second.markHealthy()
        let healthy = try PluginRuntimeRecovery(url: url)
        _ = try healthy.beginStart(safeMode: false, hasAttributedPluginMarker: false)
        try expect(healthy.snapshot.earlyUncleanStarts == 0, "Healthy/backgrounded launch counted as a crash")
        let attributed = try PluginRuntimeRecovery(url: url)
        _ = try attributed.beginStart(safeMode: false, hasAttributedPluginMarker: true)
        try expect(attributed.snapshot.earlyUncleanStarts == 0, "Plugin-attributed crash also incremented global early-start counter")
        let marker = directory.appendingPathComponent(".watchdog")
        try Data("fixture\n".utf8).write(to: marker)
        try expect(PluginRuntimeRecovery.attributedPlugin(marker: marker, knownPlugins: ["fixture"]) == "fixture", "Real native marker was not recognized")
        try expect(PluginRuntimeRecovery.attributedPlugin(marker: marker, knownPlugins: ["other"]) == nil, "Unknown marker suppressed global startup recovery")
    }

    @MainActor private static func maintenanceCompletion() async throws {
        let completion = PluginRuntimeMaintenanceCompletion()
        var calls = 0
        let cancelledObserver = Task { @MainActor in
            try await completion.finish(recovered: false) { calls += 1 }
        }
        cancelledObserver.cancel()
        try await cancelledObserver.value
        try await completion.finish(recovered: false) { calls += 1 }
        try expect(calls == 1, "Caller cancellation lost cleanup or repeated finish ran twice")
        do {
            try await completion.finish(recovered: true) { calls += 1 }
            throw FixtureFailure(description: "Conflicting maintenance outcome succeeded")
        } catch let error as PluginUIFailure {
            try expect(error.kind == "ServiceUnavailable" && calls == 1, "Conflicting finish changed the original decision")
        }
    }
}
#endif
