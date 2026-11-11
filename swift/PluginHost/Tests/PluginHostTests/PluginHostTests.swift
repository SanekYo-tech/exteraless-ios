import Foundation
import XCTest
@testable import PluginHost

/// Тесты чистой Swift-логики: гейт подписчиков, коалесценг, приоритеты,
/// таймауты, модель/разрешения/стор, менеджер интерпретаторов (fake-движок),
/// сторож. CPython не нужен — принцип 5 архитектуры (экономия macOS-минут).

// MARK: - Вспомогательное

final class FakeEngine: CPythonEngine, @unchecked Sendable {
    let lock = NSLock()
    private var recorded: [String] = []
    var delay: TimeInterval = 0
    var failCreation = false
    var footprintKB = 0
    private var nextRef: Int64 = 0

    var apiVersion: String { "fake" }
    var isProcessInitialized: Bool { true }

    var scripts: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        if failCreation { throw PluginHostError.runtimeFailure("init failed") }
    }

    func finalizeProcess() throws {}

    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        if failCreation { throw PluginHostError.runtimeFailure("spawn failed") }
        lock.lock(); defer { lock.unlock() }
        nextRef += 1
        return InterpRef(raw: nextRef)
    }

    func destroyInterpreter(_ reference: InterpRef) throws {}

    func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); defer { lock.unlock() }
        recorded.append(source)
        return "DEFAULT"
    }

    func interpreterFootprintKB(_ reference: InterpRef) -> Int { footprintKB }
}

/// Потокобезопасный список для @Sendable-обработчиков.
final class Recorder<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Event] = []
    var values: [Event] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
    var count: Int { values.count }
    func append(_ item: Event) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }
}

/// Гейт для детерминированных тестов очереди: держит диспатч открытым.
actor Gate {
    private var opened = false
    func open() { opened = true }
    func wait() async {
        while !opened {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

func tempDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pluginhost-tests-\(name)-\(UUID().uuidString)",
                                isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func waitUntil(_ predicate: @escaping @Sendable () async -> Bool,
               timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await predicate()
}

// MARK: - Гейт подписчиков

final class SubscriberGateTests: XCTestCase {
    func testCountersAndIdle() {
        let gate = SubscriberGate()
        XCTAssertTrue(gate.isIdle)
        XCTAssertFalse(gate.hasSubscribers(.updates))
        gate.add(.updates, 1)
        gate.add(.updates, 1)
        gate.add(.sendMessage, 1)
        XCTAssertEqual(gate.subscriberCount(.updates), 2)
        XCTAssertTrue(gate.hasSubscribers(.sendMessage))
        gate.add(.updates, -2)
        gate.add(.sendMessage, -1)
        XCTAssertTrue(gate.isIdle)
    }

    func testZeroOverheadWithoutSubscribers() async {
        let queue = PluginEventQueue()
        let bus = PluginEventBus(subscribers: SubscriberGate(), queue: queue)
        bus.emitAppEvent("app_start")
        bus.emitUpdate(name: "TL_updateNewMessage", account: 1, updateJSON: "{}")
        bus.emitPreRequest(RequestPayload(requestName: "x", account: 0, requestJSON: "{}"))
        let quiet = await waitUntil { await queue.stats.enqueued == 0 }
        XCTAssertTrue(quiet, "без подписчиков события не должны ставиться вовсе")
    }
}

// MARK: - Очередь: коалесценг, приоритеты, дроп, таймаут

final class PluginEventQueueTests: XCTestCase {

    func testUpdateCoalescingNEventsOneEntry() async {
        let queue = PluginEventQueue()
        for index in 0..<100 {
            await queue.submit(.update(UpdatePayload(
                updateName: "TL_updateNewMessage", account: 1,
                updateJSON: "{\"i\":\(index)}")))
        }
        let handled = Recorder<PluginEvent>()
        await queue.start(handler: { event in handled.append(event); return .none })
        let done = await waitUntil { await queue.stats.dispatched == 1 }
        XCTAssertTrue(done, "100 апдейтов должны стать одним диспатчем")
        XCTAssertEqual(handled.count, 1)
        guard case .coalescedUpdates(let key, let items)? = handled.values.first else {
            return XCTFail("ожидали coalescedUpdates, получили \(handled.values)")
        }
        XCTAssertEqual(key.container, "u:TL_updateNewMessage")
        XCTAssertEqual(items.count, 100)
        let enqueued = await queue.stats.enqueued
        XCTAssertEqual(enqueued, 100)
    }

    func testPriorityOrderSettingsBeforeUpdates() async throws {
        let queue = PluginEventQueue()
        let gate = Gate()
        let order = Recorder<String>()
        await queue.start(handler: { event in
            order.append(String(describing: event.kind))
            await gate.wait()
            return .none
        })
        // Настройки уходят первыми (приоритет выше апдейтов) и висят в гейте.
        let settingsTask = Task {
            try await queue.submitAwaiting(.createSettings(
                CreateSettingsPayload(pluginId: "p1", account: 1)))
        }
        let poppedSettings = await waitUntil {
            order.values.first == Optional("createSettings")
        }
        XCTAssertTrue(poppedSettings)
        XCTAssertEqual(order.values.first, Optional("createSettings"))
        // Пока loop занят настройками — приходит апдейт (ниже приоритетом).
        await queue.submit(.update(UpdatePayload(
            updateName: "TL_updateUserStatus", account: 1, updateJSON: "{}")))
        await gate.open()
        _ = try await settingsTask.value
        let settled = await waitUntil { await order.count == 2 }
        XCTAssertTrue(settled, "после открытия гейта должен уйти батч апдейтов")
        XCTAssertEqual(order.values.last, Optional("updates"))
    }

    func testStaleSettingsRequestIsReplaced() async throws {
        let gate = Gate()
        let queue = PluginEventQueue()
        await queue.start(handler: { _ in await gate.wait(); return .none })
        // Занимаем диспатч долгим запросом настроек ДРУГОГО плагина.
        let blocker = Task {
            try await queue.submitAwaiting(.createSettings(
                CreateSettingsPayload(pluginId: "p0", account: 1)))
        }
        let popped = await waitUntil { await queue.stats.dispatched == 1 }
        XCTAssertTrue(popped, "блокирующий запрос должен диспатчиться и висеть в гейте")
        // Пока loop занят — два запроса p1: второй замещает первого.
        // Второй submitAwaiting нельзя await'ить до открытия гейта: диспатчер
        // всё ещё в wait(), запрос не завершится (взаимная блокировка).
        let first = Task {
            try await queue.submitAwaiting(.createSettings(
                CreateSettingsPayload(pluginId: "p1", account: 1)))
        }
        let firstQueued = await waitUntil { await queue.stats.enqueued >= 2 }
        XCTAssertTrue(firstQueued, "первый запрос p1 должен встать в очередь")
        let second = Task {
            try await queue.submitAwaiting(.createSettings(
                CreateSettingsPayload(pluginId: "p1", account: 1)))
        }
        let dropped = await waitUntil { await queue.stats.droppedStale == 1 }
        XCTAssertTrue(dropped, "второй запрос p1 должен заместить первый")
        await gate.open()
        do {
            _ = try await first.value
            XCTFail("замещённый запрос должен был упасть")
        } catch let error as PluginHostError {
            guard case .superseded = error else { return XCTFail("ожидали superseded: \(error)") }
        }
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, .none)
        _ = try await blocker.value
    }

    func testDispatchTimeoutAbandonsButQueueContinues() async throws {
        let queue = PluginEventQueue()
        let timedOut = Recorder<String>()
        let handler: PluginEventQueue.Handler = { event in
            switch event {
            case .sendMessage:
                try await Task.sleep(nanoseconds: 600_000_000)
                return .none
            case .createSettings:
                return .settingsJSON("[]")
            default:
                return .none
            }
        }
        await queue.start(
            handler: handler,
            onTimeout: { event in timedOut.append(String(describing: event.kind)) },
            limits: .init(dispatchTimeout: 0.05))
        do {
            _ = try await queue.submitAwaiting(.sendMessage(SendMessagePayload(
                account: 1, paramsJSON: "{}")))
            XCTFail("ожидали таймаут")
        } catch let error as PluginHostError {
            guard case .timeout = error else { return XCTFail("ожидали timeout: \(error)") }
        }
        let observed = await waitUntil { timedOut.count == 1 }
        XCTAssertTrue(observed, "обсервер таймаута должен сработать")
        // Очередь жива: следующее событие обрабатывается, не дожидаясь зависшего.
        let result = try await queue.submitAwaiting(.createSettings(
            CreateSettingsPayload(pluginId: "p1", account: 1)))
        XCTAssertEqual(result, .settingsJSON("[]"))
    }
}

// MARK: - Модель плагина

final class PluginModelTests: XCTestCase {
    func testDefaultsMatchJavaModel() {
        let plugin = Plugin(id: "ab")
        XCTAssertEqual(plugin.version, "1.0")
        XCTAssertEqual(plugin.engine, "python")
        XCTAssertTrue(plugin.enabled)
        XCTAssertTrue(plugin.isEnabled)
        XCTAssertFalse(plugin.permissionsDeclared)
        XCTAssertTrue(plugin.handlesAppEvent)
        XCTAssertTrue(plugin.handlesUpdates)
        XCTAssertEqual(plugin.displayName, "ab")
    }

    func testIconPackAndIndex() {
        var plugin = Plugin(id: "ab")
        XCTAssertNil(plugin.iconPack)
        XCTAssertEqual(plugin.iconIndex, 0)
        plugin.icon = "exteraPlugins/12"
        XCTAssertEqual(plugin.iconPack, "exteraPlugins")
        XCTAssertEqual(plugin.iconIndex, 12)
        plugin.icon = "nopack"
        XCTAssertEqual(plugin.iconPack, "nopack")
        XCTAssertEqual(plugin.iconIndex, 0)
    }

    func testSubtitleAndLoadError() {
        var plugin = Plugin(id: "ab", name: "Cool", author: "dev", version: "2.1")
        XCTAssertEqual(plugin.subtitle, "v2.1 • dev")
        plugin.loadError = "boom"
        XCTAssertEqual(plugin.subtitle, "v2.1 • dev • error")
        XCTAssertFalse(plugin.isEnabled)
    }

    func testIsValidID() {
        XCTAssertTrue(Plugin.isValidID("ab"))
        XCTAssertTrue(Plugin.isValidID("a-b_C9"))
        XCTAssertFalse(Plugin.isValidID("a"))           // < 2 символов
        XCTAssertFalse(Plugin.isValidID("9ab"))         // цифра первой
        XCTAssertFalse(Plugin.isValidID("a b"))
        XCTAssertFalse(Plugin.isValidID(String(repeating: "a", count: 33)))
    }
}

// MARK: - Разрешения и стор

final class PermissionsTests: XCTestCase {
    func testSanitizeAndOrder() {
        XCTAssertEqual(PluginPermission.sanitize(rawKeys: ["network", "ui", "hooks", "bogus"]),
                       [.ui, .network, .hooks])
        XCTAssertTrue(PluginPermission.hooks.isDangerous)
        XCTAssertTrue(PluginPermission.native.isDangerous)
        XCTAssertFalse(PluginPermission.network.isDangerous)
    }

    func testEffectiveAndCompatMode() throws {
        let store = try PluginStore(directory: tempDirectory("perms"))
        let model = PermissionsModel()
        model.load(from: store)
        // Режим совместимости: записи нет — только ui.
        XCTAssertEqual(model.effective("legacy"), [.ui])
        XCTAssertFalse(model.check("legacy", .messagesRead))
        model.setGranted("p1", [.messagesRead, .messagesSend, .ui], to: store)
        XCTAssertEqual(model.effective("p1"), [.ui, .messagesRead, .messagesSend])
        XCTAssertFalse(model.check("p1", .hooks))
        model.unsafeMode = true
        XCTAssertTrue(model.check("p1", .hooks))
    }

    func testStoreRoundtrip() throws {
        let directory = tempDirectory("store")
        let store = try PluginStore(directory: directory)
        var plugin = Plugin(id: "ab", name: "Alpha", author: "dev")
        plugin.permissions = ["messages.read"]
        plugin.permissionsDeclared = true
        plugin.path = directory.appendingPathComponent("ab.plugin").path
        try store.savePlugins([plugin])
        let loaded = store.loadPlugins()
        XCTAssertEqual(loaded, [plugin])
        store.saveGrants(["ab": [.messagesRead, .network]])
        XCTAssertEqual(store.loadGrants()["ab"] ?? [], [.messagesRead, .network])
    }

    func testRequestedPermissions() {
        var plugin = Plugin(id: "ab")
        plugin.permissions = ["ui", "network", "bogus"]
        XCTAssertEqual(PermissionsModel.requested(plugin), [.network])
    }
}

// MARK: - Менеджер интерпретаторов

final class SubinterpreterManagerTests: XCTestCase {
    func testAbandonRefusesFurtherCallsAndFailsPending() async throws {
        let engine = FakeEngine()
        let manager = SubinterpreterManager(
            engine: engine, limits: PythonInterpreterLimits(callTimeout: 5))
        let handle = try await manager.createInterpreter(
            for: "hang", bootstrapScript: "import sys")
        XCTAssertTrue(engine.scripts.first?.hasPrefix("import sys") == true)

        // Делаем реальные вызовы «зависающими».
        engine.delay = 10
        let pending = Task { try await manager.invoke(handle, script: "slow()") }
        try await Task.sleep(nanoseconds: 150_000_000) // вызов ушёл в воркер
        await manager.abandon(handle)
        do {
            _ = try await pending.value
            XCTFail("зависший вызов должен упасть после abandon")
        } catch let error as PluginHostError {
            guard case .pluginNotResponding = error else {
                return XCTFail("ожидали pluginNotResponding: \(error)")
            }
        }
        do {
            _ = try await manager.invoke(handle, script: "again()")
            XCTFail("брошенный интерпретатор не должен принимать вызовы")
        } catch let error as PluginHostError {
            guard case .pluginNotResponding = error else {
                return XCTFail("ожидали pluginNotResponding: \(error)")
            }
        }
        let abandoned = await manager.hasAbandoned
        XCTAssertTrue(abandoned)
    }

    func testInterpreterLimit() async throws {
        let engine = FakeEngine()
        let manager = SubinterpreterManager(
            engine: engine, limits: PythonInterpreterLimits(maxInterpreters: 1))
        _ = try await manager.createInterpreter(for: "one", bootstrapScript: "x")
        do {
            _ = try await manager.createInterpreter(for: "two", bootstrapScript: "x")
            XCTFail("лимит интерпретаторов должен сработать")
        } catch let error as PluginHostError {
            guard case .interpreterLimitReached(let limit) = error else {
                return XCTFail("ожидали interpreterLimitReached: \(error)")
            }
            XCTAssertEqual(limit, 1)
        }
    }
}

// MARK: - Сторож

final class PluginWatchdogTests: XCTestCase {
    func testCrashStrikesDisablePlugin() async throws {
        let store = try PluginStore(directory: tempDirectory("watchdog"))
        // Первый процесс: маркер написан, смерть, страйк 1 — оставить включённым.
        let first = PluginWatchdog(store: store)
        await first.start()
        await first.noteRiskyOperation("crasher")
        let second = PluginWatchdog(store: store)
        await second.start()
        let firstRecovery = await second.recoverAfterCrash()
        XCTAssertNil(firstRecovery)
        // Второй процесс: снова маркер — страйк 2 → выключить.
        await second.noteRiskyOperation("crasher")
        let third = PluginWatchdog(store: store)
        await third.start()
        let disabled = await third.recoverAfterCrash()
        XCTAssertEqual(disabled, Optional("crasher"))
    }

    func testNotRespondingLifecycle() async {
        let store = try PluginStore(directory: tempDirectory("watchdog-nr"))
        let watchdog = PluginWatchdog(store: store)
        let events = Recorder<(String, Bool)>()
        await watchdog.start(observer: { id, flag in events.append((id, flag)) })
        await watchdog.pluginTimedOut("frozen")
        let marked = await waitUntil { await watchdog.isNotResponding("frozen") }
        XCTAssertTrue(marked)
        // Повтор — no-op (зависший больше не зовётся).
        await watchdog.pluginTimedOut("frozen")
        XCTAssertEqual(events.count, 1)
        await watchdog.clearNotResponding("frozen")
        let recovered = await waitUntil { await watchdog.isNotResponding("frozen") == false }
        XCTAssertTrue(recovered)
        XCTAssertEqual(events.values.last?.0, Optional("frozen"))
        XCTAssertEqual(events.values.last?.1, Optional(false))
    }
}

// MARK: - Хост (интеграционный, fake-движок)

final class PluginHostTests: XCTestCase {
    func testInstallLoadAndDispatch() async throws {
        let engine = FakeEngine()
        let directory = tempDirectory("host")
        let configuration = PluginHost.Configuration(
            runtime: PythonRuntimeConfiguration(
                programName: "test",
                compatibilityDirectories: ["/vj", "/sdk"],
                pluginRootDirectory: directory.path),
            storageDirectory: directory,
            queue: PluginEventQueue.Limits(dispatchTimeout: 2),
            interpreters: PythonInterpreterLimits(callTimeout: 1))
        let host = try PluginHost(engine: engine, configuration: configuration)
        try await host.start()

        let source = directory.appendingPathComponent("tester.py")
        try "print('plugin')".data(using: .utf8)?.write(to: source)
        let metadata = Plugin(id: "tester", name: "Tester", permissions: ["ui"],
                              permissionsDeclared: true)
        let installed = try await host.installPlugin(sourceURL: source, metadata: metadata)
        XCTAssertTrue(installed.loaded)
        XCTAssertTrue(engine.scripts.contains { $0.contains("import virtualjava") })
        XCTAssertTrue(host.events.subscribers.hasSubscribers(.appEvent))

        host.events.emitAppEvent("app_start")
        let dispatched = await waitUntil {
            engine.scripts.contains { $0.contains("__exteraless_dispatch__") }
        }
        XCTAssertTrue(dispatched, "событие должно дойти до интерпретатора")
        XCTAssertTrue(engine.scripts.contains {
            $0.contains("\"on_app_event\"") && $0.contains("\"app_start\"")
        })

        try await host.setPluginEnabled("tester", false)
        XCTAssertFalse(host.events.subscribers.hasSubscribers(.appEvent))
        try await host.stop()
        XCTAssertFalse(host.isRunning)
    }

    func testUnsafeModePermissionsFlow() {
        let model = PermissionsModel(unsafeMode: true)
        XCTAssertTrue(model.has("anything", .hooks))
    }
}
