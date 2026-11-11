import Foundation

/// Управление жизненным циклом CPython уровня процесса.
///
/// Всё общение с CPython идёт через протокол `CPythonEngine` — семантические
/// операции, каждая с точным перечнем настоящего C-API 3.12, который должен
/// вызывать реализация. Пакет НЕ линкуется с CPython напрямую (иначе Linux-CI
/// и разработка без Python.xcframework невозможны). Реализация движка для
/// Bazel-сборки — `CPythonXCFrameworkEngine` (этап 5, macOS, ~150 строк,
/// см. README «Интеграция»): файл со `import Python` (modulemap на заголовки
/// Python.xcframework), реализующий этот протокол.

// MARK: - Конфигурация

/// Пути и параметры встройки CPython (этап 1: BeeWare+патч, Python.xcframework).
public struct PythonRuntimeConfiguration: Hashable, Sendable {
    /// Имя программы (argv[0] интерпретатора; видно в диагностиках CPython).
    public var programName: String
    /// Домашний каталог встроенного Python.framework (PyConfig.home).
    /// TODO(мак): сверить фактический layout этапа 1 —
    /// Python.xcframework/ios-arm64/Python.framework -> bundle.
    public var frameworkHome: String?
    /// Каталоги stdlib в бандле (PyConfig.module_search_paths).
    public var stdlibDirectories: [String]
    /// Каталоги совместимости: python/virtualjava, python/sdk, корень плагинов
    /// (добавляются в sys.path каждого суб-интерпретатора).
    public var compatibilityDirectories: [String]
    /// Каталог установленных плагинов (filesDir/plugins, файл .watchdog сторожа).
    public var pluginRootDirectory: String
    /// Разрешить запись .pyc в кэш (экономия старта; по умолчанию выключено —
    /// каталог бандла read-only, кэш только для плагинов).
    public var writeBytecode: Bool
    /// Не ставить сигнальные хендлеры CPython (PyConfig.install_signal_handlers = 0).
    public var installSignalHandlers: Bool

    public init(programName: String = "exteraless",
                frameworkHome: String? = nil,
                stdlibDirectories: [String] = [],
                compatibilityDirectories: [String] = [],
                pluginRootDirectory: String = "",
                writeBytecode: Bool = false,
                installSignalHandlers: Bool = false) {
        self.programName = programName
        self.frameworkHome = frameworkHome
        self.stdlibDirectories = stdlibDirectories
        self.compatibilityDirectories = compatibilityDirectories
        self.pluginRootDirectory = pluginRootDirectory
        self.writeBytecode = writeBytecode
        self.installSignalHandlers = installSignalHandlers
    }

    /// Типовая конфигурация для приложения: ресурсы лежат в главном бандле
    /// рядом с Python.framework (этапы 1–2 кладут туда stdlib/virtualjava/sdk).
    /// TODO(мак): сверить реальные пути бандла со скриптами сборки этапа 1.
    public static func standard(bundle: Bundle = .main) -> PythonRuntimeConfiguration {
        let resourcePath = bundle.resourceURL?.path ?? bundle.bundlePath
        let framework = resourcePath + "/Python.framework"
        var stdlib = [String]()
        let candidates = [
            framework + "/Resources/lib/python3.12",
            framework + "/Versions/A/Resources/lib/python3.12",
            resourcePath + "/python-stdlib/lib/python3.12",
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            stdlib.append(candidate)
            break
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("exteraless").path ?? (resourcePath + "/exteraless")
        return PythonRuntimeConfiguration(
            programName: "exteraless",
            frameworkHome: framework,
            stdlibDirectories: stdlib,
            compatibilityDirectories: [
                resourcePath + "/python/virtualjava",
                resourcePath + "/python/sdk",
                support + "/plugins",
            ],
            pluginRootDirectory: support + "/plugins",
            writeBytecode: false,
            installSignalHandlers: false)
    }
}

/// Загрузочный скрипт каждого суб-интерпретатора: пути + virtualjava + мост.
public extension PythonRuntimeConfiguration {
    /// Скрипт бутстрапа. `_exteraless_bridge` — C-extension этапа 2,
    /// реализующий Backend-протокол из python/virtualjava/backend.py.
    /// TODO(этап 2): имя фабрики бэкенда фиксирует C-слой моста.
    /// TODO(этап 5): загрузка плагина через extera_utils/plugin_loader.py SDK
    /// и регистрация хуков (после бутстрапа, отдельным скриптом диспатча).
    func bootstrapScript(interpreterPluginId: String) -> String {
        let paths = (compatibilityDirectories + [pluginRootDirectory])
            .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: ", ")
        return """
        import sys
        sys.path[:0] = [\(paths)]
        import _exteraless_bridge  # этап 2: Backend-протокол (python/virtualjava/backend.py)
        import virtualjava
        virtualjava.install(_exteraless_bridge.backend())
        # этап 5: загрузка плагина '\(interpreterPluginId)' через SDK-лоадер.
        """
    }
}

// MARK: - Движок (контракт с CPython)

/// Оpaque-ссылка на суб-интерпретатор. Значение определяет реализация движка
/// (например, PyInterpreterState* как Int64).
public struct InterpRef: Hashable, Sendable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
}

/// Семантический контракт с CPython 3.12. Каждая операция документирована
/// настоящими C-вызовами, которые обязана делать реализация.
public protocol CPythonEngine: Sendable {
    /// Строка версии для диагностики (например "3.12.x").
    var apiVersion: String { get }
    /// Инициализирован ли процесс Python (после успешного initializeProcess).
    var isProcessInitialized: Bool { get }

    /// Инициализация процесса.
    ///
    /// C-API: `PyConfig config; PyConfig_InitPythonConfig(&config);`
    /// `PyConfig_SetString(&config, &config.program_name, ...)`,
    /// `PyConfig_SetString(&config, &config.home, ...)`,
    /// module_search_paths: `config.module_search_paths_set = 1` + элементы
    /// через `PyConfig_SetString(&config, &config.module_search_paths, ...)`
    /// (TODO(мак): проверить `PyConfig_SetStringList`/ручное заполнение поля
    /// `config.module_search_paths`, см. Include/cpython/initconfig.h),
    /// `config.install_signal_handlers = 0`, `config.write_bytecode`,
    /// затем `status = Py_InitializeFromConfig(&config);`
    /// `PyConfig_Clear(&config)`; проверка `PyStatus_Exception(status)`.
    /// После успеха — `PyEval_SaveThread()` (отдать GIL инициализирующему потоку).
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws

    /// Финализация процесса. НЕ вызывать, если есть брошенные (abandoned)
    /// интерпретаторы: их потоки держат GIL своих интерпретаторов навсегда,
    /// `Py_FinalizeEx()` зависнет. В этом случае процесс просто доживает до
    /// teardown ОС — решение принимает PluginHost.shutdown.
    /// C-API: `Py_FinalizeEx()`.
    func finalizeProcess() throws

    /// Создать суб-интерпретатор по политике PEP 684. Вызывать на потоке,
    /// который станет владельцем интерпретатора (воркер SubinterpreterManager),
    /// т.к. C-API возвращает tstate, привязанный к текущему потоку.
    ///
    /// C-API: заполнить `PyInterpreterConfig` полями из
    /// PythonInterpreterConfiguration, затем
    /// `Py_NewInterpreterFromConfig(&tstate, &config)`;
    /// ошибка — `PyStatus_Exception(status)`.
    /// TODO(мак): проверить требование удержания GIL основного интерпретатора
    /// при вызове (обсуждение python/cpython#111518).
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef

    /// Уничтожить интерпретатор. Строго на потоке-владельце, из tstate
    /// интерпретатора.
    /// C-API: `PyThreadState_Swap(tstate); Py_EndInterpreter(tstate);`.
    /// Гарантия: Py_EndInterpreter нельзя звать из чужого/зависшего потока —
    /// зависшие интерпретаторы НЕ уничтожаются (политика abandon).
    func destroyInterpreter(_ reference: InterpRef) throws

    /// Выполнить исходник в интерпретаторе, вернуть repr результата последнего
    /// выражения (v1: мост JSON-строками).
    /// C-API: на потоке-владельце — `PyRun_SimpleString` не возвращает значения,
    /// поэтому: `PyRun_String` с `Py_eval_input`/`Py_file_input`,
    /// `PyObject_Repr` + `PyUnicode_AsUTF8`; ошибки — `PyErr_Occurred()`,
    /// `PyErr_Fetch`, `PyErr_NormalizeException`, текст в ошибку Swift.
    func runScript(_ reference: InterpRef, _ source: String) throws -> String

    /// Приблизительный RSS интерпретатора, КБ. Точного per-interpreter RSS в
    /// CPython 3.12 нет (куча процесса общая); реализация возвращает дельту
    /// RSS процесса с момента создания интерпретатора — upper bound для
    /// сторожа. TODO(мак/этап 5): сверить доступные счётчики.
    func interpreterFootprintKB(_ reference: InterpRef) -> Int
}

/// Движок-заглушка: CPython не слинкован (SPM-сборка без Python.xcframework,
/// тесты Linux-CI). Все операции честно отказывают.
public struct UnboundCPythonEngine: CPythonEngine {
    public init() {}

    public var apiVersion: String { "unbound" }
    public var isProcessInitialized: Bool { false }

    public func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        throw PluginHostError.pythonNotLinked
    }

    public func finalizeProcess() throws {
        throw PluginHostError.pythonNotLinked
    }

    public func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        throw PluginHostError.pythonNotLinked
    }

    public func destroyInterpreter(_ reference: InterpRef) throws {
        throw PluginHostError.pythonNotLinked
    }

    public func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        throw PluginHostError.pythonNotLinked
    }

    public func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }
}

// MARK: - Рантайм

/// Актор, владеющий процессом CPython. Блокирующие C-вызывы здесь редки
/// (инициализация/финализация), исполнение скриптов происходит на воркерных
/// потоках суб-интерпретаторов (SubinterpreterManager), не в акторе.
public actor PythonRuntime {
    public enum State: Equatable, Sendable {
        case idle
        case running
        /// Остановлен. Если финализация была небезопасна (abandoned) —
        /// процесс CPython остаётся жить до teardown приложения.
        case stopped
    }

    private let engine: any CPythonEngine
    public private(set) var state: State = .idle

    public init(engine: any CPythonEngine) {
        self.engine = engine
    }

    /// Инициализировать процесс Python (идемпотентно).
    public func initialize(_ configuration: PythonRuntimeConfiguration) throws {
        guard state == .idle else { return }
        try engine.initializeProcess(configuration: configuration)
        state = .running
    }

    /// Остановить. `canFinalizeProcess == false` (есть abandoned) — не звать
    /// Py_FinalizeEx: зависшие интерпретаторы держат свои GIL вечно.
    public func shutdown(canFinalizeProcess: Bool) {
        guard state == .running else { return }
        if canFinalizeProcess {
            // Отказ финализации не откатывает состояние: процесс всё равно
            // терминален, ошибка уже залогирована реализацией движка.
            try? engine.finalizeProcess()
        }
        state = .stopped
    }
}
