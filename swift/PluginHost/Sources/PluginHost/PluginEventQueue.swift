import Foundation

/// ОДНА очередь доставки событий в плагины.
///
/// Свойства (требования этапа 4):
/// - батчинг/коалесценг: N апдейтов одного ключа (аккаунт + имя) = ОДИН вход
///   в интерпретатор (событие `.coalescedUpdates`);
/// - приоритеты: UI/settings > поток сообщений > запросы > апдейты;
/// - дроп устаревших: create_settings для того же плагина заменяет прежний
///   запрос, переполнение отрезает самые старые апдейты, переполнение глубины
///   роняет fire-and-forget события низкого приоритета;
/// - таймаут на вызов: зависший диспатч не останавливает очередь — воркер
///   остаётся висеть (политика abandon в SubinterpreterManager/Watchdog),
///   ожидающему вызывающему возвращается ошибка таймаута.
///
/// Диспатчер один: события обрабатываются последовательно; параллельность
/// внутри батча (несколько плагинов на своих интерпретаторах) — решение
/// обработчика (PluginHost запускает их в TaskGroup).
public actor PluginEventQueue {

    // MARK: - Типы

    /// Результат одного диспатча (для UI-отладки и тестов).
    public struct Stats: Equatable, Sendable {
        public var enqueued = 0
        public var dispatched = 0
        public var coalescedIntoBatches = 0
        public var droppedStale = 0
        public var droppedOverflow = 0
        public var timedOut = 0
        public init() {}
    }

    /// Лимиты очереди.
    public struct Limits: Sendable {
        /// Таймаут одного диспатча (батча), секунды. По умолчанию — 5 с,
        /// как FREEZE_TIMEOUT_SECONDS у PluginsWatchdog.java.
        public var dispatchTimeout: TimeInterval
        /// Максимум апдейтов в одном коалесценг-батче (старые выбрасываются).
        public var maxCoalescedPerKey: Int
        /// Общая глубина (fire-and-forget выбрасываются при переполнении).
        public var maxQueueDepth: Int
        public init(dispatchTimeout: TimeInterval = 5.0,
                    maxCoalescedPerKey: Int = 512,
                    maxQueueDepth: Int = 1024) {
            self.dispatchTimeout = dispatchTimeout
            self.maxCoalescedPerKey = maxCoalescedPerKey
            self.maxQueueDepth = maxQueueDepth
        }
    }

    typealias Handler = @Sendable (PluginEvent) async throws -> PluginEventResult
    typealias TimeoutObserver = @Sendable (PluginEvent) async -> Void

    private struct Envelope {
        let event: PluginEvent
        let reply: OneShotReply?
        let sequence: Int
    }

    private struct CoalescedBucket {
        var items: [PluginEvent] = []
        var sequence = 0
    }

    /// Одноразовый ответ ожидающему вызывающему (резюмится ровно один раз,
    /// из любого потока/задачи).
    final class OneShotReply: @unchecked Sendable {
        private let box = OneShotResult<PluginEventResult>()
        func succeed(_ value: PluginEventResult) { box.succeed(value) }
        func fail(_ error: Error) { box.fail(error) }
        func awaitValue() async throws -> PluginEventResult { try await box.awaitValue() }
    }

    // MARK: - Состояние

    private var handler: Handler?
    private var onTimeout: TimeoutObserver?
    private var limits = Limits()
    private(set) public var stats = Stats()
    private var stopped = false

    private var uiSettings: [Envelope] = []
    private var sendMessage: [Envelope] = []
    private var requests: [Envelope] = []
    private var coalesced: [CoalesceKey: CoalescedBucket] = []
    private var latestSettingsRequest: [String: Int] = [:]
    private var nextSequence = 0
    private var loopTask: Task<Void, Never>?

    // MARK: - Публичное API

    /// Запустить потребителя. Повторный вызов заменяет обработчик.
    public func start(handler: @escaping Handler,
                      onTimeout: @escaping TimeoutObserver = { _ in },
                      limits: Limits = Limits()) {
        self.handler = handler
        self.onTimeout = onTimeout
        self.limits = limits
        stopped = false
        ensureLoop()
    }

    /// Остановить: ожидающие получают ошибку, новые submit — отказ.
    public func stop() {
        stopped = true
        loopTask?.cancel()
        loopTask = nil
        failPending(PluginHostError.queueStopped)
        uiSettings = []
        sendMessage = []
        requests = []
        coalesced.removeAll()
        latestSettingsRequest.removeAll()
    }

    /// Постановка fire-and-forget события (не ждёт результата).
    public func submit(_ event: PluginEvent) {
        enqueue(event, reply: nil)
    }

    /// Постановка fire-and-forget из не-async контекста (точки входа telegram-ios).
    public nonisolated func submitAsync(_ event: PluginEvent) {
        Task { await self.submit(event) }
    }

    /// Постановка ждущего события; возвращает результат обработки.
    public func submitAwaiting(_ event: PluginEvent) async throws -> PluginEventResult {
        guard !stopped, handler != nil else { throw PluginHostError.queueStopped }
        let reply = OneShotReply()
        enqueue(event, reply: reply)
        return try await reply.awaitValue()
    }

    // MARK: - Постановка

    private func enqueue(_ event: PluginEvent, reply: OneShotReply?) {
        guard !stopped else {
            reply?.fail(PluginHostError.queueStopped)
            return
        }
        stats.enqueued += 1

        // Коалесценг create_settings: новый запрос того же плагина замещает
        // невзятый старый (дроп устаревших) — старому резюмится ошибка.
        if case .createSettings(let payload) = event, reply != nil {
            if let previous = latestSettingsRequest[payload.pluginId],
               let envelopeIndex = uiSettings.firstIndex(where: { $0.sequence == previous }) {
                let stale = uiSettings.remove(at: envelopeIndex)
                stale.reply?.fail(PluginHostError.superseded(payload.pluginId))
                stats.droppedStale += 1
            }
            latestSettingsRequest[payload.pluginId] = nextSequence
        }

        // Апдейты — в коалесценг-бакеты.
        if let key = event.coalesceKey {
            var bucket = coalesced[key] ?? CoalescedBucket()
            bucket.items.append(event)
            bucket.sequence = nextSequence
            if bucket.items.count > limits.maxCoalescedPerKey {
                bucket.items.removeFirst(bucket.items.count - limits.maxCoalescedPerKey)
                stats.droppedOverflow += 1
            }
            coalesced[key] = bucket
            ensureLoop()
            return
        }

        let envelope = Envelope(event: event, reply: reply, sequence: nextSequence)
        nextSequence += 1

        // Переполнение глубины: роняем fire-and-forget низкого приоритета.
        if depth + 1 > limits.maxQueueDepth, reply == nil,
           event.priority.rawValue >= PluginEventPriority.updates.rawValue {
            stats.droppedOverflow += 1
            return
        }

        switch event.priority {
        case .uiSettings: uiSettings.append(envelope)
        case .sendMessage: sendMessage.append(envelope)
        case .request, .lifecycle, .updates: requests.append(envelope)
        }
        ensureLoop()
    }

    private var depth: Int {
        uiSettings.count + sendMessage.count + requests.count
            + coalesced.values.reduce(0) { $0 + $1.items.count }
    }

    // MARK: - Потребитель

    private func ensureLoop() {
        guard loopTask == nil, handler != nil, !stopped else { return }
        loopTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        while !stopped {
            guard let envelope = popNext() else {
                loopTask = nil
                return
            }
            await dispatch(envelope)
        }
        loopTask = nil
        failPending(PluginHostError.queueStopped)
    }

    private func popNext() -> Envelope? {
        if let envelope = uiSettings.first {
            uiSettings.removeFirst()
            if case .createSettings(let payload) = envelope.event {
                latestSettingsRequest[payload.pluginId] = nil
            }
            return envelope
        }
        if let envelope = sendMessage.first {
            sendMessage.removeFirst()
            return envelope
        }
        if !coalesced.isEmpty {
            // Самый старый бакет становится ОДНИМ входом в интерпретатор.
            let oldest = coalesced.min { $0.value.sequence < $1.value.sequence }!
            let key = oldest.key
            let items = oldest.value.items
            coalesced[key] = nil
            stats.coalescedIntoBatches += items.count
            return Envelope(event: .coalescedUpdates(key, items), reply: nil, sequence: oldest.value.sequence)
        }
        if let envelope = requests.first {
            requests.removeFirst()
            return envelope
        }
        return nil
    }

    private func dispatch(_ envelope: Envelope) async {
        guard let handler else {
            envelope.reply?.fail(PluginHostError.queueStopped)
            return
        }
        stats.dispatched += 1
        do {
            let timeout = limits.dispatchTimeout
            let result = try await withDispatchTimeout(timeout) {
                try await handler(envelope.event)
            }
            envelope.reply?.succeed(result)
        } catch is DispatchTimeoutError {
            stats.timedOut += 1
            // Диспатч «завис»: обработчик не отменился — интерпретатор
            // бросается (abandon) обсервером, очередь продолжает жить.
            if let onTimeout { await onTimeout(envelope.event) }
            envelope.reply?.fail(PluginHostError.timeout(String(describing: envelope.event.kind)))
        } catch {
            envelope.reply?.fail(error)
        }
    }

    private func failPending(_ error: Error) {
        for envelope in uiSettings + sendMessage + requests {
            envelope.reply?.fail(error)
        }
    }
}

// MARK: - Таймаут

/// Гонка операции с дедлайном. Операция запускается НЕСТРУКТУРИРОВАННОЙ
/// задачей и НЕ отменяется по таймауту: зависший вызов CPython продолжает
/// висеть в своём воркере до abandon (SubinterpreterManager/Watchdog) —
/// structured-группа ждала бы её вечно, что противоречит политике.
/// Побочный эффект: при таймауте задача операции живёт, пока операция не
/// завершится (для брошенного интерпретатора — до конца процесса; осознано).
func withDispatchTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    if seconds <= 0 { return try await operation() }
    let outcome = OneShotResult<T>()
    let operationTask = Task {
        do {
            outcome.succeed(try await operation())
        } catch {
            outcome.fail(error)
        }
    }
    let timerTask = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        outcome.fail(DispatchTimeoutError())
    }
    defer {
        timerTask.cancel()
        _ = operationTask
    }
    return try await outcome.awaitValue()
}

struct DispatchTimeoutError: Error {}
