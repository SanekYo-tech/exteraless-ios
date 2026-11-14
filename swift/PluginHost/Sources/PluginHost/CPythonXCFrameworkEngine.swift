#if canImport(CExteralessPythonBridge)
import Foundation
import CExteralessPythonBridge

/// Адаптер стабильного C ABI из EXLPythonEngine.h (CPython 3.12).
///
/// Initialize/finalize исполняются на одном process-wide native Thread.
/// Create/run/destroy остаются на вызывающем потоке-владельце интерпретатора.
/// C-shim сам управляет GIL/tstate; на входе и выходе Python state не attached.
/// `@unchecked Sendable`: адаптер не хранит изменяемого состояния; почтовый
/// ящик control-потока и native bookkeeping защищены собственными блокировками.
public final class CPythonXCFrameworkEngine: CPythonEngine, @unchecked Sendable {
    public init() {}

    public var apiVersion: String {
        guard let version = EXLPythonVersion() else { return "unknown" }
        return String(cString: version)
    }

    public var isProcessInitialized: Bool { EXLPythonIsInitialized() != 0 }

    public func initializeProcess(configuration: PythonRuntimeConfiguration) throws {
        try CPythonControlThread.shared.perform {
            try Self.initializeNative(configuration)
        }
    }

    public func finalizeProcess() throws {
        try CPythonControlThread.shared.perform {
            var error = EXLPythonBuffer(bytes: nil, count: 0)
            defer { EXLPythonBufferFree(&error) }
            let status = EXLPythonFinalize(&error)
            try Self.checkStatus(status, error: error, operation: "EXLPythonFinalize")
        }
    }

    public func createInterpreter(_ configuration: PythonInterpreterConfiguration) throws -> InterpRef {
        var native = EXLPythonInterpreterConfiguration(
            use_main_obmalloc: configuration.useMainObmalloc ? 1 : 0,
            allow_fork: configuration.allowFork ? 1 : 0,
            allow_exec: configuration.allowExec ? 1 : 0,
            allow_threads: configuration.allowThreads ? 1 : 0,
            allow_daemon_threads: configuration.allowDaemonThreads ? 1 : 0,
            check_multi_interp_extensions: configuration.checkMultiInterpExtensions ? 1 : 0,
            own_gil: configuration.ownsGIL ? 1 : 0)
        var reference: Int64 = 0
        var error = EXLPythonBuffer(bytes: nil, count: 0)
        defer { EXLPythonBufferFree(&error) }
        let status = EXLPythonCreateInterpreter(&native, &reference, &error)
        try Self.checkStatus(status, error: error, operation: "EXLPythonCreateInterpreter")
        return InterpRef(raw: reference)
    }

    public func destroyInterpreter(_ reference: InterpRef) throws {
        var error = EXLPythonBuffer(bytes: nil, count: 0)
        defer { EXLPythonBufferFree(&error) }
        let status = EXLPythonDestroyInterpreter(reference.raw, &error)
        try Self.checkStatus(status, error: error, operation: "EXLPythonDestroyInterpreter")
    }

    public func runScript(_ reference: InterpRef, _ source: String) throws -> String {
        var result = EXLPythonBuffer(bytes: nil, count: 0)
        var error = EXLPythonBuffer(bytes: nil, count: 0)
        defer {
            EXLPythonBufferFree(&result)
            EXLPythonBufferFree(&error)
        }
        let status = source.utf8CString.withUnsafeBufferPointer { bytes in
            EXLPythonRunScript(reference.raw, bytes.baseAddress, bytes.count - 1, &result, &error)
        }
        try Self.checkStatus(status, error: error, operation: "EXLPythonRunScript")
        return Self.decode(result)
    }

    /// 0 означает «неизвестно»: CPython не предоставляет per-interpreter RSS.
    /// Память всего процесса здесь не выдаётся за footprint одного плагина.
    public func interpreterFootprintKB(_ reference: InterpRef) -> Int { 0 }

    private static func initializeNative(_ configuration: PythonRuntimeConfiguration) throws {
        let strings = CPythonConfigurationStrings()
        let programName = try strings.copy(configuration.programName)
        let home = try strings.copy(configuration.frameworkHome)
        let executable = try strings.copy(configuration.executablePath)
        let paths = try configuration.stdlibDirectories.map { try strings.copy($0) }

        // C заимствует все указатели только до возврата EXLPythonInitialize.
        try withExtendedLifetime(strings) {
            try paths.withUnsafeBufferPointer { searchPaths in
                var native = EXLPythonProcessConfiguration(
                    program_name: programName,
                    home: home,
                    executable: executable,
                    module_search_paths: searchPaths.baseAddress,
                    module_search_path_count: searchPaths.count,
                    write_bytecode: configuration.writeBytecode ? 1 : 0,
                    install_signal_handlers: configuration.installSignalHandlers ? 1 : 0)
                var error = EXLPythonBuffer(bytes: nil, count: 0)
                defer { EXLPythonBufferFree(&error) }
                let status = EXLPythonInitialize(&native, &error)
                try checkStatus(status, error: error, operation: "EXLPythonInitialize")
            }
        }
    }

    private static func checkStatus(_ status: CInt, error: EXLPythonBuffer, operation: String) throws {
        guard status != 0 else { return }
        let message = decode(error)
        let detail = message.isEmpty ? "native engine returned status \(status)" : message
        throw PluginHostError.runtimeFailure("\(operation): \(detail)")
    }

    private static func decode(_ buffer: EXLPythonBuffer) -> String {
        guard let bytes = buffer.bytes, buffer.count > 0 else { return "" }
        // count исключает terminator, но сам результат может содержать NUL.
        let utf8 = UnsafeRawBufferPointer(start: bytes, count: buffer.count)
        return String(decoding: utf8, as: UTF8.self)
    }
}

/// Копии UTF-8 живут до завершения синхронного вызова C, включая массив путей.
/// Создаётся и используется только на control-потоке, указатели не пересылаются.
private final class CPythonConfigurationStrings {
    private var buffers: [UnsafeMutablePointer<CChar>] = []

    func copy(_ value: String?) throws -> UnsafePointer<CChar>? {
        guard let value else { return nil }
        guard !value.utf8.contains(0) else {
            throw PluginHostError.runtimeFailure(
                "EXLPythonInitialize: configuration strings must not contain NUL")
        }
        let buffer = value.utf8CString.withUnsafeBufferPointer { bytes in
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes.baseAddress!, count: bytes.count)
            return pointer
        }
        buffers.append(buffer)
        return UnsafePointer(buffer)
    }

    deinit {
        for buffer in buffers { buffer.deallocate() }
    }
}

/// Один Thread на время жизни процесса, общий для всех экземпляров адаптера.
/// Actor или serial DispatchQueue не сохраняет native thread affinity.
private final class CPythonControlThread: @unchecked Sendable {
    static let shared = CPythonControlThread()

    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var thread: Thread?

    private init() {
        let thread = Thread { [self] in serve() }
        thread.name = "exteraless-python-control"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    func perform(_ operation: @escaping @Sendable () throws -> Void) throws {
        // Не ждать собственный mailbox при native callback на этом же потоке.
        // Проверку допустимости повторного входа выполняет C-shim.
        if Thread.current === thread {
            try operation()
            return
        }
        let reply = Reply()
        condition.lock()
        jobs.append {
            do {
                try operation()
                reply.complete(.success(()))
            } catch {
                let failure = (error as? PluginHostError)
                    ?? PluginHostError.runtimeFailure(String(describing: error))
                reply.complete(.failure(failure))
            }
        }
        condition.signal()
        condition.unlock()
        try reply.wait()
    }

    private func serve() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    private final class Reply: @unchecked Sendable {
        private let condition = NSCondition()
        private var outcome: Result<Void, PluginHostError>?

        func complete(_ result: Result<Void, PluginHostError>) {
            condition.lock()
            outcome = result
            condition.signal()
            condition.unlock()
        }

        func wait() throws {
            condition.lock()
            while outcome == nil { condition.wait() }
            let result = outcome!
            condition.unlock()
            try result.get()
        }
    }
}
#endif
