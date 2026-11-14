import Foundation

/// Управление жизненным циклом CPython уровня процесса.
///
/// Всё общение с CPython идёт через протокол `CPythonEngine` — семантические
/// операции с контрактом C-API 3.12 для будущего нативного C-shim. Пакет
/// не линкуется с CPython напрямую; движок для BeeWare Python.framework
/// ещё предстоит реализовать и подключить в сборке приложения.

// MARK: - Конфигурация

/// Пути и параметры встройки BeeWare CPython 3.12.
public struct PythonRuntimeConfiguration: Hashable, Sendable {
    /// Имя программы (argv[0] интерпретатора; видно в диагностиках CPython).
    public var programName: String
    /// Python home (PyConfig.home), обычно App.app/python-stdlib.
    /// Историческое имя поля: это не каталог бинарника Python.framework.
    public var frameworkHome: String?
    /// Каталоги stdlib в бандле (PyConfig.module_search_paths).
    public var stdlibDirectories: [String]
    /// Корни импорта: python (родитель virtualjava), python/sdk, корень плагинов
    /// (добавляются в sys.path каждого суб-интерпретатора).
    public var compatibilityDirectories: [String]
    /// Каталог установленных плагинов (filesDir/plugins, файл .watchdog сторожа).
    public var pluginRootDirectory: String
    /// Разрешить запись .pyc в кэш (экономия старта; по умолчанию выключено —
    /// каталог бандла read-only, кэш только для плагинов).
    public var writeBytecode: Bool
    /// Не ставить сигнальные хендлеры CPython (PyConfig.install_signal_handlers = 0).
    public var installSignalHandlers: Bool
    /// Путь к манифесту для BridgeBackend(manifest_path=...). nil использует
    /// default C-моста (окружение/путь модуля); standard(bundle:) задаёт явно.
    public var manifestPath: String?
    /// Префикс зарегистрированных нативных сервисов (<service>.call и т.д.).
    /// Неизвестный сервис отказывает при обращении; mock не устанавливается.
    public var service: String

    public init(programName: String = "exteraless",
                frameworkHome: String? = nil,
                stdlibDirectories: [String] = [],
                compatibilityDirectories: [String] = [],
                pluginRootDirectory: String = "",
                writeBytecode: Bool = false,
                installSignalHandlers: Bool = false,
                manifestPath: String? = nil,
                service: String = "java") {
        self.programName = programName
        self.frameworkHome = frameworkHome
        self.stdlibDirectories = stdlibDirectories
        self.compatibilityDirectories = compatibilityDirectories
        self.pluginRootDirectory = pluginRootDirectory
        self.writeBytecode = writeBytecode
        self.installSignalHandlers = installSignalHandlers
        self.manifestPath = manifestPath
        self.service = service
    }

    /// Фиксированный layout приложения: App.app/Frameworks/Python.framework
    /// содержит рантайм; python-stdlib — Python home, python — пакеты и манифест.
    /// lib-dynload содержит .fwork-маркеры расширений; их Mach-O лежат в отдельно
    /// подписываемых Frameworks. Пути задаются независимо от наличия ресурсов:
    /// проверка упаковки/загрузка — ответственность сборки и нативного движка.
    public static func standard(bundle: Bundle = .main) -> PythonRuntimeConfiguration {
        let resourcePath = bundle.resourceURL?.path ?? bundle.bundlePath
        let pythonHome = resourcePath + "/python-stdlib"
        let stdlib = pythonHome + "/lib/python3.12"
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("exteraless").path ?? (resourcePath + "/exteraless")
        return PythonRuntimeConfiguration(
            programName: "exteraless",
            frameworkHome: pythonHome,
            stdlibDirectories: [stdlib, stdlib + "/lib-dynload"],
            compatibilityDirectories: [
                resourcePath + "/python",
                resourcePath + "/python/sdk",
                support + "/plugins",
            ],
            pluginRootDirectory: support + "/plugins",
            writeBytecode: false,
            installSignalHandlers: false,
            manifestPath: resourcePath + "/python/compat-manifest.json",
            service: "java")
    }
}

/// Загрузочный скрипт каждого суб-интерпретатора: пути + virtualjava + мост.
public extension PythonRuntimeConfiguration {
    /// Скрипт бутстрапа. `_exteraless_bridge` регистрируется C-shim как built-in
    /// до инициализации CPython. xt_bind связывает классы текущего интерпретатора,
    /// BridgeBackend реализует протокол из python/virtualjava/backend.py.
    /// Ошибки импорта/инициализации передаются вызывающему коду.
    /// TODO(этап 5): загрузка плагина через extera_utils/plugin_loader.py SDK
    /// и регистрация хуков (после бутстрапа, отдельным скриптом диспатча).
    func bootstrapScript(interpreterPluginId: String) -> String {
        var seenPaths = Set<String>()
        let paths = (compatibilityDirectories + [pluginRootDirectory])
            .filter { !$0.isEmpty && seenPaths.insert($0).inserted }
            .map(Self.pythonStringLiteral)
            .joined(separator: ", ")
        let manifest = manifestPath.map(Self.pythonStringLiteral) ?? "None"
        return """
        import sys
        sys.path[:0] = [\(paths)]
        import _exteraless_bridge
        import virtualjava
        _exteraless_bridge.xt_bind(virtualjava.JavaInstance, virtualjava.JavaMemberError)
        virtualjava.install(_exteraless_bridge.BridgeBackend(
            service=\(Self.pythonStringLiteral(service)),
            manifest_path=\(manifest),
        ))
        # этап 5: загрузка плагина \(Self.pythonStringLiteral(interpreterPluginId)) через SDK-лоадер.
        """
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let encoder = JSONEncoder()
        // JSON экранирует кавычки, обратные слеши и управляющие символы.
        // Python не декодирует JSON-escape \/, поэтому обычные / сохраняем.
        encoder.outputFormatting = .withoutEscapingSlashes
        // String имеет только допустимый Unicode и не может отказать в encode.
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
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
    /// `PyConfig_SetString(&config, &config.home, ...)` при заданном frameworkHome.
    /// Для явного списка stdlibDirectories: `config.module_search_paths_set = 1`
    /// и `PyWideStringList_Append(&config.module_search_paths, ...)` для каждого
    /// пути (Include/cpython/initconfig.h); проверять возвращённый PyStatus.
    /// `config.install_signal_handlers` и `config.write_bytecode` из конфигурации,
    /// затем `status = Py_InitializeFromConfig(&config);`
    /// `PyConfig_Clear(&config)`; проверка `PyStatus_Exception(status)`.
    /// До Py_InitializeFromConfig shim регистрирует built-in модуль через
    /// `PyImport_AppendInittab("_exteraless_bridge", PyInit__exteraless_bridge)`
    /// с проверкой кода возврата.
    /// После успеха — `PyEval_SaveThread()` (отдать GIL инициализирующему потоку).
    func initializeProcess(configuration: PythonRuntimeConfiguration) throws

    /// Финализация процесса. Не вызывать при брошенных (abandoned) интерпретаторах:
    /// их потоки могут продолжать выполнение или ждать нативный код, поэтому
    /// `Py_FinalizeEx()` может зависнуть. Abandon не останавливает поток;
    /// освобождение ресурсов тогда остаётся teardown процесса ОС.
    /// C-API: `Py_FinalizeEx()`.
    func finalizeProcess() throws

    /// Создать суб-интерпретатор по политике PEP 684. Вызывать на потоке,
    /// который станет владельцем интерпретатора (воркер SubinterpreterManager),
    /// т.к. C-API возвращает tstate, привязанный к текущему потоку.
    ///
    /// C-API: заполнить `PyInterpreterConfig` полями из
    /// PythonInterpreterConfiguration, затем
    /// `Py_NewInterpreterFromConfig(&tstate, &config)` из публичного
    /// Include/cpython/pylifecycle.h (через Python.h, не Limited API);
    /// ошибка — `PyStatus_Exception(status)`.
    /// PEP 684 входит в CPython 3.12: отдельный build-флаг isolated-subinterpreters
    /// не требуется; собственный GIL выбирается в PyInterpreterConfig.
    /// TODO(мак): проверить требование удержания GIL основного интерпретатора
    /// при вызове (обсуждение python/cpython#111518).
    func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef

    /// Согласованно завершить интерпретатор на потоке-владельце с его текущим
    /// tstate и удержанным GIL. C-API: `Py_EndInterpreter(tstate)`.
    /// Это не способ прервать зависший вызов: политика abandon прекращает
    /// дальнейший диспатч, но не гарантирует остановку потока/освобождение памяти.
    func destroyInterpreter(_ reference: InterpRef) throws

    /// Выполнить исходник в интерпретаторе, вернуть repr результата последнего
    /// выражения (v1: мост JSON-строками).
    /// C-API: на потоке-владельце — `PyRun_SimpleString` не возвращает значения,
    /// поэтому: `PyRun_String` с `Py_eval_input`/`Py_file_input`,
    /// `PyObject_Repr` + `PyUnicode_AsUTF8`; ошибки — `PyErr_Occurred()`,
    /// `PyErr_Fetch`, `PyErr_NormalizeException`, текст в ошибку Swift.
    func runScript(_ reference: InterpRef, _ source: String) throws -> String

    /// Диагностическая оценка памяти, КБ; семантику счётчика определяет движок.
    /// CPython 3.12 не предоставляет per-interpreter RSS: куча процесса общая.
    /// RSS процесса и его дельту нельзя приписать одному плагину или считать
    /// верхней границей его памяти. Этот показатель не обеспечивает RSS-лимит
    /// на плагин; возможное использование сторожем — только эвристика.
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
    /// Py_FinalizeEx: незавершённые вызовы делают финализацию небезопасной.
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
