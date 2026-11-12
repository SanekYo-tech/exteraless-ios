import Foundation
#if canImport(Darwin)
// TODO(mac): mach task_info / phys_footprint. Ветка ниже компилируется только
// с Apple SDK (`canImport(Darwin)`). Linux CI её не видит.
import Darwin
#endif

/// Сторож плагинов — семантика PluginsWatchdog.java (39 КБ эталона):
///
/// - ЗАВИСАНИЕ: заход в код плагина не вернулся за freezeTimeout — плагин
///   помечается notResponding, уведомляется UI, и БОЛЬШЕ НЕ ВЫЗЫВАЕТСЯ
///   (интерпретатор бросается, см. SubinterpreterManager.abandon);
/// - RSS-ЛИМИТ: приближённый per-plugin footprint (дельта RSS процесса с
///   момента создания интерпретатора — точного per-interpreter RSS в CPython
///   3.12 нет, TODO(мак/этап 5)); превышение = abandon + уведомление;
/// - АТРИБУЦИЯ ПАДЕНИЙ: маркер plugins/.watchdog — id плагина пишется перед
///   рискованной операцией (загрузка), только при изменении, без fsync
///   (страничный кэш переживает смерть процесса); очистка отложена на
///   idleClearDelay. На старте recoverAfterCrash() читает маркер: второй
///   страйк — плагин выключается персистентно;
/// - ОШИБКИ МОСТА: handlePluginError ставит loadError, плагин отключается
///   (вызывающий передаёт результат в PluginHost).
///
/// Отчуждение от эталона (осознанное): на iOS плагины не исполняются на
/// главном потоке — бюджета главного потока (250 мс/с) нет; вместо него
/// таймаут на диспатч в PluginEventQueue + этот сторож.

/// RSS процесса, КБ. Приближение (mach phys_footprint / Linux statm).
enum ProcessFootprint {
    static var residentKB: Int {
#if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        // TODO(мак): phys_footprint — честный footprint Jetpack-уровня.
        if result == KERN_SUCCESS { return Int(info.phys_footprint / 1024) }
        return 0
#else
        // Linux (swift test без Apple SDK): resident pages из /proc/self/statm.
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let residentPages = statm.split(separator: " ").dropFirst().first,
              let pages = Int(residentPages) else { return 0 }
        return pages * 4096 / 1024
#endif
    }
}

/// Лимиты сторожа.
public struct WatchdogLimits: Sendable {
    /// Ожидание возврата из плагина, с (FREEZE_TIMEOUT_SECONDS = 5).
    public var freezeTimeoutSeconds: Double
    /// Per-plugin RSS-лимит, КБ (v1: 192 МБ).
    public var rssLimitKB: Int
    /// Задержка очистки маркера после выхода из последнего плагина (2000 мс).
    public var idleClearDelayMs: Int
    /// Смертей процесса на плагине до отключения (CRASH_STRIKES_BEFORE_DISABLE = 2).
    public var strikesBeforeDisable: Int
    /// Период RSS-свипа, секунды.
    public var rssSweepIntervalSeconds: Double

    public init(freezeTimeoutSeconds: Double = 5.0,
                rssLimitKB: Int = 192 * 1024,
                idleClearDelayMs: Int = 2000,
                strikesBeforeDisable: Int = 2,
                rssSweepIntervalSeconds: Double = 30.0) {
        self.freezeTimeoutSeconds = freezeTimeoutSeconds
        self.rssLimitKB = rssLimitKB
        self.idleClearDelayMs = idleClearDelayMs
        self.strikesBeforeDisable = strikesBeforeDisable
        self.rssSweepIntervalSeconds = rssSweepIntervalSeconds
    }
}

/// Сторож: пометки notResponding, RSS-лимиты, маркер падений, страйки.
public actor PluginWatchdog {

    /// Уведомление UI-слоя: плагин завис/отвыс.
    public typealias NotRespondingObserver = @Sendable (String, Bool) -> Void
    /// Снимок footprint живых плагинов (КБ) из менеджера интерпретаторов.
    /// async: снимок живёт в акторе `SubinterpreterManager`. Синхронное
    /// замыкание по-прежнему подходит — Swift поднимает его в async.
    public typealias FootprintProvider = @Sendable () async -> [(String, Int)]
    /// Реакция на таймаут: бросить интерпретатор (владелец — PluginHost).
    public typealias AbandonAction = @Sendable (String) async -> Void

    private struct State: Codable {
        var strikes: [String: Int] = [:]
        var muted: [String] = []
    }

    private var limits = WatchdogLimits()
    private let markerURL: URL
    private let persist: URL
    private let log: (@Sendable (String) -> Void)?
    private var notRespondingIds: Set<String> = []
    private var state = State()
    private var persistedMarker: String?
    private var sweepTask: Task<Void, Never>?
    private var markerClearTask: Task<Void, Never>?
    private var abandonedIds: Set<String> = []

    private var observer: NotRespondingObserver?
    private var abandonAction: AbandonAction?
    private var footprintProvider: FootprintProvider?

    init(markerURL: URL, persistURL: URL, log: (@Sendable (String) -> Void)? = nil) {
        self.markerURL = markerURL
        self.persist = persistURL
        self.log = log
    }

    public init(store: PluginStore,
                log: (@Sendable (String) -> Void)? = nil) {
        self.markerURL = store.watchdogMarkerURL
        self.persist = store.directory.appendingPathComponent("watchdog.json")
        self.log = log
    }

    // MARK: - Жизненный цикл

    /// Поднять сторож: колбэки, лимиты, свип-задача RSS.
    public func start(limits: WatchdogLimits = WatchdogLimits(),
                      observer: @escaping NotRespondingObserver = { _, _ in },
                      abandon: @escaping AbandonAction = { _ in },
                      footprint: @escaping FootprintProvider = { [] }) {
        self.limits = limits
        self.observer = observer
        self.abandonAction = abandon
        self.footprintProvider = footprint
        loadState()
        if sweepTask == nil {
            sweepTask = Task { [weak self, interval = limits.rssSweepIntervalSeconds] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    await self?.sweepFootprints()
                }
            }
        }
    }

    /// Остановить (стоп движка): снять пометки, очистить маркер, остановить свип.
    public func stop() {
        sweepTask?.cancel()
        sweepTask = nil
        markerClearTask?.cancel()
        markerClearTask = nil
        for id in notRespondingIds { observer?(id, false) }
        notRespondingIds.removeAll()
        clearMarkerNow()
        abandonedIds.removeAll()
        observer = nil
        abandonAction = nil
        footprintProvider = nil
    }

    // MARK: - Зависания

    /// Плагин не вернулся за freezeTimeout (таймаут из PluginEventQueue):
    /// пометить, бросить интерпретатор, уведомить UI. Повторные вызовы — no-op.
    public func pluginTimedOut(_ pluginId: String) async {
        guard !abandonedIds.contains(pluginId) else { return }
        abandonedIds.insert(pluginId)
        notRespondingIds.insert(pluginId)
        log?("PluginWatchdog: плагин \(pluginId) не отвечает — интерпретатор брошен (abandon)")
        await abandonAction?(pluginId)
        observer?(pluginId, true)
    }

    /// Висит ли плагин (для UI и гейтов очереди).
    public func isNotResponding(_ pluginId: String) -> Bool {
        notRespondingIds.contains(pluginId)
    }

    public var notRespondingList: [String] { Array(notRespondingIds) }

    /// Плагин отвис вручную (перезагрузка) — снять пометку.
    public func clearNotResponding(_ pluginId: String) {
        notRespondingIds.remove(pluginId)
        abandonedIds.remove(pluginId)
        observer?(pluginId, false)
    }

    // MARK: - Ошибки плагина

    /// Java-исключение из Python (handlePluginError): плагин отключается
    /// немедленно (loadError), сторож выходит из захода.
    @discardableResult
    public func handlePluginError(_ pluginId: String, message: String) -> String {
        log?("PluginWatchdog: плагин \(pluginId) кинул ошибку: \(message)")
        return message
    }

    // MARK: - RSS

    /// Периодический свип: спросить снимок footprint у хоста, превысивших —
    /// бросить (abandon) и пометить notResponding.
    private func sweepFootprints() async {
        guard let footprintProvider else { return }
        for (pluginId, kb) in await footprintProvider() {
            await checkFootprint(pluginId, kb: kb)
        }
    }

    /// Проверить footprint конкретного плагина (зовёт PluginHost периодически
    /// или после диспатчей). Превышение — abandon.
    public func checkFootprint(_ pluginId: String, kb: Int) async {
        guard kb > 0, kb > limits.rssLimitKB, !abandonedIds.contains(pluginId) else { return }
        log?("PluginWatchdog: плагин \(pluginId) превысил RSS-лимит (\(kb) КБ > \(limits.rssLimitKB) КБ)")
        await pluginTimedOut(pluginId)
    }

    // MARK: - Маркер падений (атрибуция)

    /// Записать id в маркер перед рискованной операцией (загрузка плагина):
    /// только при изменении, без fsync — страничный кэш переживает смерть
    /// процесса (noteMarker в PluginsWatchdog.java).
    public func noteRiskyOperation(_ pluginId: String) {
        markerClearTask?.cancel()
        markerClearTask = nil
        guard persistedMarker != pluginId else { return }
        try? pluginId.data(using: .utf8)?.write(to: markerURL, options: .atomic)
        persistedMarker = pluginId
    }

    /// Выход из последнего плагина: очистка маркера отложена на idleClearDelay.
    public func scheduleMarkerClear() {
        guard persistedMarker != nil else { return }
        guard markerClearTask == nil else { return }
        let delay = limits.idleClearDelayMs
        markerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            await self?.clearMarkerNow()
        }
    }

    private func clearMarkerNow() {
        markerClearTask?.cancel()
        markerClearTask = nil
        guard persistedMarker != nil else { return }
        try? FileManager.default.removeItem(at: markerURL)
        persistedMarker = nil
    }

    /// Чтение маркера на старте (recoverAfterCrash): death-страйк; при
    /// strikesBeforeDisable — вернуть id виновника для выключения, иначе nil.
    public func recoverAfterCrash() -> String? {
        guard let data = try? Data(contentsOf: markerURL),
              let crashed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !crashed.isEmpty else {
            clearMarkerNow()
            return nil
        }
        clearMarkerNow()
        let strikes = (state.strikes[crashed] ?? 0) + 1
        state.strikes[crashed] = strikes
        saveState()
        guard strikes >= limits.strikesBeforeDisable else {
            log?("PluginWatchdog: \(crashed) активен при смерти процесса (\(strikes)/\(limits.strikesBeforeDisable)), оставлен включённым")
            return nil
        }
        state.strikes[crashed] = nil
        saveState()
        log?("PluginWatchdog: \(crashed) активен при \(limits.strikesBeforeDisable) смертях процесса — выключить")
        return crashed
    }

    /// Сессия дожила до фона без падения: обнулить страйки (noteHealthy).
    public func noteHealthy(_ pluginId: String) {
        guard state.strikes[pluginId] != nil else { return }
        state.strikes[pluginId] = nil
        saveState()
    }

    /// Уход в фон: смерть процесса в фоне — не страйк (onAppBackgrounded).
    public func noteAppBackgrounded() {
        clearMarkerNow()
    }

    // MARK: - Персистентность

    private func loadState() {
        guard let data = try? Data(contentsOf: persist),
              let decoded = try? JSONDecoder().decode(State.self, from: data) else { return }
        state = decoded
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: persist, options: .atomic)
    }
}
