import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Compile in the same module as Sources/PluginHost/*.swift, with the native
// CExteralessPythonBridge module and CPluginHostShims linked (not through SPM).
// Run as a child process with an external 30-second timeout.
#if !canImport(CExteralessPythonBridge)
#error("swift_engine_probe requires the native CExteralessPythonBridge module")
#endif

private struct ProbeFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

private struct ProbeReport: Encodable, Sendable {
    var ok = false
    let probe = "swift-engine"
    var phase = "initializing"
    var python: String?
    var ownGILInterpreters = 0
    var nativeWorkers = 0
    var builtinBridge = false
    var isolatedGlobals = false
    var isolatedHandles = false
    var utf8AndNulResults = false
    var statementSuiteNone = false
    var exceptionRecovery = false
    var bootstrapFailureCleaned = false
    var executableConfigured = false
    var finalized = false
    var error: String?

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

@main
struct SwiftEngineProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard (3...5).contains(arguments.count) else {
            log("usage: swift-engine-probe <report.json> <python-home> [stdlib] [dynload]")
            exit(2)
        }
        let reportURL = URL(fileURLWithPath: arguments[1])
        let executable = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
        let configuration = PythonRuntimeConfiguration(
            programName: "exteraless-swift-engine-probe",
            frameworkHome: arguments[2],
            stdlibDirectories: Array(arguments.dropFirst(3)),
            executablePath: executable)
        let engine = CPythonXCFrameworkEngine()
        let runtime = PythonRuntime(engine: engine)
        let manager = SubinterpreterManager(engine: engine)
        var report = ProbeReport()

        do {
            try report.write(to: reportURL)
            try require(!engine.isProcessInitialized, "CPython was already initialized before the probe")
            try await runtime.initialize(configuration)
            try require(engine.isProcessInitialized, "initialize returned without a running CPython process")
            report.python = engine.apiVersion
            try require(engine.apiVersion.hasPrefix("3.12."), "expected CPython 3.12, got \(engine.apiVersion)")

            report.phase = "creating-interpreters"
            try report.write(to: reportURL)
            var interpreterConfiguration = PythonInterpreterConfiguration()
            interpreterConfiguration.allowThreads = false
            do {
                _ = try await manager.createInterpreter(
                    for: "swift-probe-bad-bootstrap",
                    bootstrapScript: "raise ValueError('bootstrap cleanup probe')",
                    configuration: interpreterConfiguration)
                throw ProbeFailure(description: "invalid bootstrap unexpectedly succeeded")
            } catch PluginHostError.runtimeFailure(let message) {
                try require(message.contains("bootstrap cleanup probe"), "unexpected bootstrap failure: \(message)")
            }
            let afterFailure = await manager.activeCount
            let cleanAfterFailure = await manager.canFinalizeProcess
            try require(afterFailure == 0 && cleanAfterFailure, "failed bootstrap leaked an interpreter")
            report.bootstrapFailureCleaned = true
            let first = try await manager.createInterpreter(
                for: "swift-probe-first", bootstrapScript: bootstrap(value: "first"),
                configuration: interpreterConfiguration)
            let second = try await manager.createInterpreter(
                for: "swift-probe-second", bootstrapScript: bootstrap(value: "second"),
                configuration: interpreterConfiguration)
            try require(first.id != second.id, "manager returned the same interpreter handle twice")
            let activeCount = await manager.activeCount
            try require(activeCount == 2, "expected two live interpreters, got \(activeCount)")

            report.phase = "checking-interpreters"
            try report.write(to: reportURL)
            try await checkInterpreters(manager, first: first, second: second, executable: executable)
            report.ownGILInterpreters = 2
            report.nativeWorkers = 2
            report.builtinBridge = true
            report.isolatedGlobals = true
            report.isolatedHandles = true
            report.utf8AndNulResults = true
            report.statementSuiteNone = true
            report.exceptionRecovery = true
            report.executableConfigured = true

            report.phase = "destroying-interpreters"
            try report.write(to: reportURL)
            await manager.destroy(first)
            try await expect(manager, second, "value", "second")
            try await expect(manager, second, "bridge.xt_resolve_handle(handle) is payload", "True")
            try await expect(manager, second, "bridge.xt_release_handle(handle)", "True")
            try await expect(manager, second, "bridge.xt_handle_count()", "0")
            await manager.destroy(second)
            let remaining = await manager.activeCount
            let stats = await manager.stats
            try require(remaining == 0, "manager retained \(remaining) interpreters after destroy")
            try require(stats.created == 3 && stats.destroyed == 3 && stats.abandoned == 0,
                        "unexpected lifecycle counters: created=\(stats.created), destroyed=\(stats.destroyed), abandoned=\(stats.abandoned)")

            report.phase = "finalizing"
            try report.write(to: reportURL)
            let canFinalize = await manager.canFinalizeProcess
            try require(canFinalize, "manager still has pending or live interpreters")
            await runtime.shutdown(canFinalizeProcess: canFinalize)
            // shutdown suppresses finalization errors; check the actual native state.
            try require(!engine.isProcessInitialized, "CPython is still initialized after runtime.shutdown")
            let runtimeState = await runtime.state
            try require(runtimeState == .stopped, "PythonRuntime did not enter the stopped state")
            report.finalized = true
            report.phase = "complete"
            report.ok = true
            try report.write(to: reportURL)
            print("EXTERALESS_SWIFT_ENGINE_PROBE_OK")
        } catch {
            report.ok = false
            report.error = String(describing: error)
            try? report.write(to: reportURL)
            log("SWIFT_ENGINE_PROBE \(report.phase): \(String(describing: error))")
            await manager.destroyAll()
            let canFinalize = await manager.canFinalizeProcess
            await runtime.shutdown(canFinalizeProcess: canFinalize)
            report.finalized = report.python != nil && !engine.isProcessInitialized
            try? report.write(to: reportURL)
            exit(1)
        }
    }

    private static func bootstrap(value: String) -> String {
        // Fixed probe labels only; no SDK, plugin loader, or Swift service setup.
        """
        import _exteraless_bridge as bridge
        import _thread
        assert bridge.xt_handle_count() == 0, 'bridge handle table was not initially empty'
        value = '\(value)'
        payload = {'owner': value}
        handle = bridge.xt_register_handle(payload)
        """
    }

    private static func checkInterpreters(
        _ manager: SubinterpreterManager, first: InterpreterHandle,
        second: InterpreterHandle, executable: String
    ) async throws {
        let firstThread = try await manager.invoke(first, script: "_thread.get_ident()")
        let secondThread = try await manager.invoke(second, script: "_thread.get_ident()")
        guard let firstID = UInt64(firstThread), let secondID = UInt64(secondThread),
              firstID != 0, secondID != 0, firstID != secondID else {
            throw ProbeFailure(description: "expected distinct native workers, got \(firstThread) and \(secondThread)")
        }
        try await expect(manager, first, "__import__('sys').executable", executable)
        try await expect(manager, first, "value", "first")
        try await expect(manager, second, "value", "second")
        try await expect(manager, first, "value = 'changed'\nvalue", "None")
        try await expect(manager, first, "value", "changed")
        try await expect(manager, second, "value", "second")
        try await expect(manager, first, "bridge.xt_handle_count()", "1")
        try await expect(manager, second, "bridge.xt_handle_count()", "1")
        try await expect(manager, first, "bridge.xt_resolve_handle(handle) is payload", "True")
        try await expect(manager, second, "bridge.xt_resolve_handle(handle) is payload", "True")
        try await expect(manager, first, "bridge.xt_release_handle(handle)", "True")
        try await expect(manager, first, "bridge.xt_handle_count()", "0")
        try await expect(manager, second, "bridge.xt_handle_count()", "1")
        try await expect(manager, second, "bridge.xt_resolve_handle(handle) is payload", "True")

        try await expect(manager, first, "'Привет, 雪 😀'", "Привет, 雪 😀")
        try await expect(manager, second, "'Привет\\x00雪😀'", "Привет\u{0}雪😀")
        try await expect(manager, first, "''", "")
        try await expect(manager, second, "[1, 2, 3]", "[1, 2, 3]")
        try await expectFailure(manager, first, "raise ValueError('swift probe recovery')", containing: "ValueError")
        try await expect(manager, first, "6 * 7", "42")
        try await expectFailure(manager, second, "raise SystemExit(23)", containing: "SystemExit")
        try await expect(manager, second, "7 * 6", "42")
        try await expectFailure(manager, first, "1\u{0}+2", containing: "embedded NUL")
        try await expect(manager, first, "value", "changed")
    }

    private static func expect(
        _ manager: SubinterpreterManager, _ handle: InterpreterHandle,
        _ source: String, _ expected: String
    ) async throws {
        let actual = try await manager.invoke(handle, script: source)
        try require(actual.utf8.elementsEqual(expected.utf8),
                    "\(handle.pluginId): \(source.debugDescription) returned \(actual.debugDescription), expected \(expected.debugDescription)")
    }

    private static func expectFailure(
        _ manager: SubinterpreterManager, _ handle: InterpreterHandle,
        _ source: String, containing expected: String
    ) async throws {
        do {
            let result = try await manager.invoke(handle, script: source)
            throw ProbeFailure(description:
                "\(handle.pluginId): \(source.debugDescription) returned \(result.debugDescription) instead of \(expected)")
        } catch let error as PluginHostError {
            guard case .runtimeFailure(let message) = error else {
                throw ProbeFailure(description: "expected runtimeFailure containing \(expected), got \(error)")
            }
            try require(message.contains(expected), "expected \(expected) in native error, got \(message)")
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeFailure(description: message) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
