import Foundation

/// Менеджер суб-интерпретаторов: PEP 684 (per-interpreter GIL), по одному
/// интерпретатору на плагин.
///
/// Политика зависаний (требование этапа 4): воркер, не вернувшийся из вызова,
/// БРОСАЕТСЯ (abandon) — интерпретатор и его поток утекают до конца процесса
/// (плагин помечается notResponding и больше не вызывается). Утечка памяти
/// одного интерпретатора допустима: альтернативы хуже — нельзя ни убить
/// поток CPython безопасно, ни звать Py_EndInterpreter из чужого потока.
/// Причина держится в счётчике abandoned: PluginHost не финализирует процесс
/// CPython, если есть брошенные интерпретаторы.
///
/// ПРИНЦИП: актор держит только бухгалтерию; все C-вызывы CPython исполняются
/// на выделенном потоке-владельце интерпретатора (thread affinity tstate).

// MARK: - Политика PEP 684

/// Настройки суб-интерпретатора — Swift-отражение C-структуры
/// `PyInterpreterConfig` (публичный Include/cpython/pylifecycle.h, Python 3.12).
public struct PythonInterpreterConfiguration: Hashable, Sendable {
    /// C-поле `use_main_obmalloc` = 0: свой обмаллокатор на интерпретатор.
    public var useMainObmalloc: Bool = false
    /// C-поле `allow_fork` = 0: fork из плагина запрещён (iOS и так нет).
    public var allowFork: Bool = false
    /// C-поле `allow_exec` = 0: exec запрещён.
    public var allowExec: Bool = false
    /// C-поле `allow_threads` = 1: dev_server SDK поднимает потоки.
    /// TODO(мак): если 1 вызывает проблемы с per-interpreter GIL — выставить 0
    /// и завести dev-сервер в отдельном конфиге.
    public var allowThreads: Bool = true
    /// C-поле `allow_daemon_threads` = 0.
    public var allowDaemonThreads: Bool = false
    /// C-поле `check_multi_interp_extensions` = 1: расширения обязаны
    /// поддерживать мульти-интерпретаторы (мост этапа 2 обязан).
    public var checkMultiInterpExtensions: Bool = true
    /// C-поле `gil` = `PyInterpreterConfig_OWN_GIL` (изолированный GIL).
    public var ownsGIL: Bool = true

    /// Политика для плагинов exteraless (значения выше — по умолчанию).
    public init() {}

    /// Отображение в C-структуру (реализация движка):
    /// use_main_obmalloc/allow_fork/allow_exec/allow_daemon_threads = 0,
    /// allow_threads = 1, check_multi_interp_extensions = 1,
    /// gil = PyInterpreterConfig_OWN_GIL.
    /// TODO(мак): сверить имена констант в PyInterpreterConfig (3.12).
}

/// Лимиты пула интерпретаторов.
public struct PythonInterpreterLimits: Sendable {
    /// Максимум живых интерпретаторов, СЧИТАЯ брошенные (abandoned): они
    /// продолжают потреблять память. Достигнут лимит — новые плагины не
    /// грузятся до перезапуска приложения (UI показывает «перезагрузите»).
    public var maxInterpreters: Int
    /// Таймаут одного вызова скрипта, секунды (по умолчанию 5 — как
    /// FREEZE_TIMEOUT_SECONDS в PluginsWatchdog.java).
    public var callTimeout: TimeInterval
    public init(maxInterpreters: Int = 16, callTimeout: TimeInterval = 5.0) {
        self.maxInterpreters = maxInterpreters
        self.callTimeout = callTimeout
    }
}

// MARK: - Дескрипторы

/// Публичный дескриптор интерпретатора плагина.
public struct InterpreterHandle: Hashable, Codable, Sendable {
    public let id: Int64
    public let pluginId: String
    init(id: Int64, pluginId: String) {
        self.id = id
        self.pluginId = pluginId
    }
}

/// Контекст вызова, доступный внутри воркерного потока интерпретатора.
public struct InterpreterCallContext: Sendable {
    public let engine: any CPythonEngine
    public let reference: InterpRef
    public let pluginId: String
}

// MARK: - Одноразовый ответ

/// Потокобезопасный одноразовый резюм: результат может прийти раньше await
/// (воркер успел) — тогда awaitValue возвращает сразу.
///
/// `CheckedContinuation` допускает resume с любого потока. NSLock защищает
/// однократную запись результата и передачу продолжения вызывающему.
/// Ошибки на входе ограничены `any Error & Sendable`.
final class OneShotResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var result: Result<T, any Error>?
    nonisolated(unsafe) private var continuation: CheckedContinuation<T, any Error>?
    private var isAwaited = false

    func succeed(_ value: T) { complete(.success(value)) }
    func fail(_ error: any Error & Sendable) { complete(.failure(error)) }

    private func complete(_ outcome: Result<T, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = outcome
        if let continuation {
            self.continuation = nil
            continuation.resume(with: outcome)
        }
    }

    func awaitValue() async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
            lock.lock()
            defer { lock.unlock() }
            if let result {
                cont.resume(with: result)
            } else if isAwaited {
                cont.resume(throwing: PluginHostError.internalInconsistency(
                    "OneShotResult: двойной await"))
            } else {
                isAwaited = true
                continuation = cont
            }
        }
    }
}

/// Ошибка из `@Sendable`-catch. `sending` забирает не-Sendable `any Error`
/// в эту функцию (SE-0430): `PluginHostError` возвращаем как есть, остальное
/// сводим к тексту. Вызывающий больше не использует `error`.
func bridgePluginError(_ error: sending any Error) -> PluginHostError {
    if let pluginError = error as? PluginHostError { return pluginError }
    return .runtimeFailure(String(describing: error))
}

// MARK: - Почтовый ящик воркера

/// Выделенный поток-владелец интерпретатора + FIFO задач. Поток никогда не
/// завершается принудительно: poisonOnly флаг лишь прекращает приём новых
/// задач; зависший в C-вызове воркер остаётся висеть (политика abandon).
final class InterpreterMailbox: @unchecked Sendable {
    struct Job {
        let id: Int64
        let closure: @Sendable (InterpreterCallContext) -> Void
    }

    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var poisoned = false
    private var nextJobId: Int64 = 0
    private var thread: Thread?

    var isPoisoned: Bool {
        condition.lock(); defer { condition.unlock() }
        return poisoned
    }

    /// Запустить воркер: `spawn` создаёт интерпретатор (Py_NewInterpreterFromConfig
    /// на ЭТОМ потоке) и возвращает контекст либо кидает.
    func start(name: String, spawn: @escaping @Sendable () throws -> InterpreterCallContext,
               onSpawnFailure: @escaping @Sendable (PluginHostError) -> Void) {
        precondition(thread == nil, "mailbox уже запущен")
        let thread = Thread { [weak self] in
            guard let self else { return }
            let context: InterpreterCallContext
            do {
                context = try spawn()
            } catch {
                // sending-параметр bridgePluginError забирает не-Sendable Error.
                onSpawnFailure(bridgePluginError(error))
                self.poisonSelf()
                return
            }
            self.serve(context: context)
        }
        thread.name = name
        thread.stackSize = 1 << 20 // 1 МиБ — хватает диспетчеру (Python сам растёт)
        thread.start()
        self.thread = thread
    }

    private func serve(context: InterpreterCallContext) {
        while true {
            condition.lock()
            while jobs.isEmpty && !poisoned { condition.wait() }
            if jobs.isEmpty && poisoned {
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job.closure(context)
        }
    }

    /// Поставить задачу. false — ящик отравлен (плагин брошен).
    func submit(_ closure: @escaping @Sendable (InterpreterCallContext) -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !poisoned else { return false }
        nextJobId += 1
        jobs.append(Job(id: nextJobId, closure: closure))
        condition.signal()
        return true
    }

    /// Прекратить приём и разбудить поток (выход при пустой очереди).
    func poison() {
        condition.lock()
        poisoned = true
        condition.signal()
        condition.unlock()
    }

    private func poisonSelf() {
        condition.lock()
        poisoned = true
        jobs.removeAll()
        condition.signal()
        condition.unlock()
    }
}

// MARK: - Менеджер

/// Актор-бухгалтер пула интерпретаторов.
public actor SubinterpreterManager {

    public struct Stats: Equatable, Sendable {
        public var created = 0
        public var destroyed = 0
        public var abandoned = 0
        public init() {}
    }

    private enum State {
        case ready
        case destroying
        case abandoned
    }

    private enum SpawnOutcome: Sendable {
        case ready(InterpRef)
        case bootstrapFailed(InterpRef, PluginHostError, cleanupFailed: Bool)
    }

    private struct Managed {
        let handle: InterpreterHandle
        let mailbox: InterpreterMailbox
        var state: State
        let reference: InterpRef
        var pendingReplies: [OneShotResult<String>] = []
    }

    private let engine: any CPythonEngine
    private var limits: PythonInterpreterLimits
    private var interpreters: [Int64: Managed] = [:]
    private var nextInterpreterId: Int64 = 1
    private var pendingCreations = 0
    private var stopping = false
    public private(set) var stats = Stats()

    public init(engine: any CPythonEngine, limits: PythonInterpreterLimits = PythonInterpreterLimits()) {
        self.engine = engine
        self.limits = limits
    }

    public var activeCount: Int { interpreters.count }
    public var abandonedCount: Int {
        interpreters.values.filter { if case .abandoned = $0.state { return true }; return false }.count
    }
    /// Есть ли брошенные интерпретаторы (решает, финализировать ли процесс).
    public var hasAbandoned: Bool { abandonedCount > 0 }
    /// Только после завершения всех созданий/выгрузок и при пустом пуле.
    public var canFinalizeProcess: Bool { pendingCreations == 0 && interpreters.isEmpty }

    /// Создать интерпретатор плагина и выполнить бутстрап (virtualjava + мост).
    public func createInterpreter(
        for pluginId: String,
        bootstrapScript: String,
        configuration: PythonInterpreterConfiguration = PythonInterpreterConfiguration()
    ) async throws -> InterpreterHandle {
        guard !stopping else { throw PluginHostError.notRunning }
        guard interpreters.count + pendingCreations < limits.maxInterpreters else {
            throw PluginHostError.interpreterLimitReached(limits.maxInterpreters)
        }
        pendingCreations += 1
        defer { pendingCreations -= 1 }
        let id = nextInterpreterId
        nextInterpreterId += 1
        let handle = InterpreterHandle(id: id, pluginId: pluginId)
        let mailbox = InterpreterMailbox()
        let spawnReply = OneShotResult<SpawnOutcome>()

        mailbox.start(
            name: "plugin-\(id)-\(pluginId)",
            spawn: { [engine] () throws -> InterpreterCallContext in
                // Создание и бутстрап — на потоке-владельце: tstate от
                // Py_NewInterpreterFromConfig привязан к этому потоку.
                let reference = try engine.createInterpreter(configuration)
                do {
                    _ = try engine.runScript(reference, bootstrapScript)
                } catch {
                    let bootstrapError = bridgePluginError(error)
                    var cleanupFailed = false
                    do {
                        try engine.destroyInterpreter(reference)
                    } catch {
                        cleanupFailed = true
                    }
                    // Сначала передаём бухгалтерии результат cleanup; последующий
                    // onSpawnFailure не заменит уже завершённый OneShotResult.
                    spawnReply.succeed(.bootstrapFailed(reference, bootstrapError,
                                                        cleanupFailed: cleanupFailed))
                    throw bootstrapError
                }
                spawnReply.succeed(.ready(reference))
                return InterpreterCallContext(engine: engine, reference: reference, pluginId: pluginId)
            },
            onSpawnFailure: { error in
                spawnReply.fail(error)
            })

        // Ждём завершения бутстрапа (включая время Py_NewInterpreterFromConfig).
        let outcome = try await spawnReply.awaitValue()
        stats.created += 1
        switch outcome {
        case let .ready(reference):
            interpreters[id] = Managed(
                handle: handle, mailbox: mailbox, state: .ready,
                reference: reference, pendingReplies: [])
            if stopping {
                // destroyAll не ждёт bootstrap. Поздний ref освобождается
                // через тот же mailbox на владельце; handle наружу не выходит.
                await destroy(handle)
                throw PluginHostError.notRunning
            }
            return handle
        case let .bootstrapFailed(reference, error, cleanupFailed):
            if cleanupFailed {
                interpreters[id] = Managed(
                    handle: handle, mailbox: mailbox, state: .abandoned,
                    reference: reference, pendingReplies: [])
                stats.abandoned += 1
            } else {
                stats.destroyed += 1
            }
            throw error
        }
    }

    /// Выполнить скрипт в интерпретаторе. Таймаут — на стороне очереди
    /// (PluginEventQueue.withDispatchTimeout); здесь только отказ для
    /// брошенных интерпретаторов.
    public func invoke(_ handle: InterpreterHandle, script: String) async throws -> String {
        guard !stopping else { throw PluginHostError.notRunning }
        guard var managed = interpreters[handle.id] else {
            throw PluginHostError.pluginNotFound(handle.pluginId)
        }
        guard case .ready = managed.state else {
            throw PluginHostError.pluginNotResponding(handle.pluginId)
        }
        let reply = OneShotResult<String>()
        let accepted = managed.mailbox.submit { context in
            do {
                reply.succeed(try context.engine.runScript(context.reference, script))
            } catch {
                reply.fail(bridgePluginError(error))
            }
        }
        if !accepted {
            throw PluginHostError.pluginNotResponding(handle.pluginId)
        }
        managed.pendingReplies.append(reply)
        interpreters[handle.id] = managed
        defer {
            if var current = interpreters[handle.id] {
                current.pendingReplies.removeAll { $0 === reply }
                interpreters[handle.id] = current
            }
        }
        return try await reply.awaitValue()
    }

    /// Бросить зависший интерпретатор: пометить, отравить ящик, разбудить
    /// ожидающих. Интерпретатор и поток УТЕКАЮТ до конца процесса (осознанно).
    public func abandon(_ handle: InterpreterHandle) {
        guard var managed = interpreters[handle.id] else { return }
        guard case .ready = managed.state else { return }
        managed.state = .abandoned
        for reply in managed.pendingReplies {
            reply.fail(PluginHostError.pluginNotResponding(handle.pluginId))
        }
        managed.pendingReplies.removeAll()
        interpreters[handle.id] = managed
        managed.mailbox.poison()
        stats.abandoned += 1
    }

    /// Мягко уничтожить интерпретатор (вызывается только для .ready):
    /// Py_EndInterpreter исполняется на потоке-владельце, затем поток выходит.
    public func destroy(_ handle: InterpreterHandle) async {
        guard var managed = interpreters[handle.id] else { return }
        guard case .ready = managed.state else { return }
        managed.state = .destroying
        interpreters[handle.id] = managed
        let done = OneShotResult<Bool>()
        let accepted = managed.mailbox.submit { context in
            do {
                try context.engine.destroyInterpreter(context.reference)
                done.succeed(true)
            } catch {
                done.fail(bridgePluginError(error))
            }
        }
        managed.mailbox.poison()
        if !accepted { done.fail(PluginHostError.pluginNotResponding(handle.pluginId)) }
        do {
            _ = try await done.awaitValue()
            interpreters[handle.id] = nil
            stats.destroyed += 1
        } catch {
            // Native state мог остаться живым. Он всё ещё занимает место в
            // пуле и запрещает финализацию процесса даже после выхода воркера.
            if var current = interpreters[handle.id] {
                current.state = .abandoned
                interpreters[handle.id] = current
                stats.abandoned += 1
            }
        }
    }

    /// Диагностическая оценка памяти движка, КБ; не per-plugin RSS (см. CPythonEngine).
    public func footprintKB(_ handle: InterpreterHandle) -> Int {
        guard let managed = interpreters[handle.id] else { return 0 }
        return engine.interpreterFootprintKB(managed.reference)
    }

    /// Снимок footprint всех живых интерпретаторов (для RSS-свипа сторожа).
    public func footprintSnapshot() -> [(String, Int)] {
        interpreters.values.map {
            ($0.handle.pluginId, engine.interpreterFootprintKB($0.reference))
        }
    }

    /// Состояние интерпретатора плагина.
    public func isNotResponding(_ pluginId: String) -> Bool {
        for managed in interpreters.values {
            if managed.handle.pluginId == pluginId, case .abandoned = managed.state {
                return true
            }
        }
        return false
    }

    /// Терминальный стоп: закрыть приём до снимка/await. Pending bootstrap
    /// не ждём — createInterpreter сам уберёт его поздний результат.
    public func destroyAll() async {
        stopping = true
        let all = interpreters.values.map(\.handle)
        for handle in all {
            await destroy(handle)
        }
    }
}
