import Foundation
import XCTest
@testable import PluginHost

/// Контракт путей и исходника bootstrap; выполнение нативного CPython здесь
/// не подменяется FakeEngine и не проверяется этими тестами.
final class PythonRuntimeConfigurationTests: XCTestCase {
    func testStandardUsesFixedBundleLayoutWithoutProbingForAssets() throws {
        let (bundle, appURL) = try makeAppBundle()
        let root = appURL.path
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/python-stdlib"))

        let configuration = PythonRuntimeConfiguration.standard(bundle: bundle)
        XCTAssertEqual(configuration.frameworkHome, root + "/python-stdlib")
        XCTAssertEqual(configuration.stdlibDirectories, [
            root + "/python-stdlib/lib/python3.12",
            root + "/python-stdlib/lib/python3.12/lib-dynload",
        ])
        XCTAssertEqual(configuration.compatibilityDirectories, [
            root + "/python",
            root + "/python/sdk",
            configuration.pluginRootDirectory,
        ])
        XCTAssertFalse(configuration.pluginRootDirectory.isEmpty)
        XCTAssertEqual(configuration.manifestPath, root + "/python/compat-manifest.json")
        XCTAssertEqual(configuration.service, "java")
        XCTAssertFalse(configuration.writeBytecode)
        XCTAssertFalse(configuration.installSignalHandlers)

        let paths = try bootstrapPaths(configuration.bootstrapScript(interpreterPluginId: "test"))
        XCTAssertEqual(paths, configuration.compatibilityDirectories)
        XCTAssertEqual(paths.filter { $0 == configuration.pluginRootDirectory }.count, 1)

        // Даже существующий устаревший layout не должен менять PyConfig.home
        // или вытеснять явно выбранную stdlib из python-stdlib.
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Python.framework/Resources/lib/python3.12"),
            withIntermediateDirectories: true)
        XCTAssertEqual(PythonRuntimeConfiguration.standard(bundle: bundle), configuration)
    }

    func testDefaultsUseJavaAndPythonNoneWithoutAddingCurrentDirectory() throws {
        let configuration = PythonRuntimeConfiguration()
        XCTAssertEqual(configuration.service, "java")
        XCTAssertNil(configuration.manifestPath)

        let script = configuration.bootstrapScript(interpreterPluginId: "test")
        XCTAssertEqual(try bootstrapPaths(script), [])
        XCTAssertEqual(try stringArgument("service", in: script), "java")
        XCTAssertEqual(try literal(in: script, prefix: "    manifest_path=", suffix: ","), "None")
    }

    func testBootstrapBindsRealBridgeAPIAndPassesConfiguration() throws {
        let configuration = PythonRuntimeConfiguration(
            compatibilityDirectories: ["/App.app/python", "/App.app/python/sdk"],
            pluginRootDirectory: "/support/plugins",
            manifestPath: "/App.app/python/compat-manifest.json",
            service: "unregistered-service")
        let script = configuration.bootstrapScript(interpreterPluginId: "test")
        let lines = script.components(separatedBy: "\n")
        let bridgeImport = try XCTUnwrap(lines.firstIndex(of: "import _exteraless_bridge"))
        let virtualJavaImport = try XCTUnwrap(lines.firstIndex(of: "import virtualjava"))
        let bind = try XCTUnwrap(lines.firstIndex(of:
            "_exteraless_bridge.xt_bind(virtualjava.JavaInstance, virtualjava.JavaMemberError)"))
        let install = try XCTUnwrap(lines.firstIndex(of:
            "virtualjava.install(_exteraless_bridge.BridgeBackend("))
        XCTAssertLessThan(bridgeImport, bind)
        XCTAssertLessThan(virtualJavaImport, bind)
        XCTAssertLessThan(bind, install)
        XCTAssertEqual(try stringArgument("service", in: script), "unregistered-service")
        XCTAssertEqual(try stringArgument("manifest_path", in: script), configuration.manifestPath)
        XCTAssertFalse(script.contains("_exteraless_bridge.backend("))
        XCTAssertFalse(script.contains("xt_install_mock_service"))
        XCTAssertFalse(script.contains("MockBackend"))
        XCTAssertFalse(script.contains("except"), "Ошибки bootstrap должны доходить до движка")
    }

    func testBootstrapKeepsPathOrderAndAddsPluginRootOnlyOnce() throws {
        let configuration = PythonRuntimeConfiguration(
            compatibilityDirectories: ["/python", "", "/python/sdk", "/plugins", "/python"],
            pluginRootDirectory: "/plugins")
        XCTAssertEqual(try bootstrapPaths(configuration.bootstrapScript(interpreterPluginId: "test")),
                       ["/python", "/python/sdk", "/plugins"])

        let separateRoot = PythonRuntimeConfiguration(
            compatibilityDirectories: ["/python", "/python/sdk"],
            pluginRootDirectory: "/plugins")
        XCTAssertEqual(try bootstrapPaths(separateRoot.bootstrapScript(interpreterPluginId: "test")),
                       ["/python", "/python/sdk", "/plugins"])
    }

    func testBootstrapQuotesPathsServiceManifestAndPluginID() throws {
        let special = "/quote\"single'back\\slash\nline\rreturn\ttab\u{0}\u{8}\u{c}/雪/😀"
        let manifest = special + "/compat-manifest.json"
        let service = "service" + special
        let pluginID = "plugin'\nraise RuntimeError('injected')\r#" + special
        let configuration = PythonRuntimeConfiguration(
            compatibilityDirectories: [special + "/python", special + "/sdk"],
            pluginRootDirectory: special + "/plugins",
            manifestPath: manifest,
            service: service)
        let script = configuration.bootstrapScript(interpreterPluginId: pluginID)

        XCTAssertEqual(try bootstrapPaths(script), [
            special + "/python", special + "/sdk", special + "/plugins",
        ])
        XCTAssertEqual(try stringArgument("service", in: script), service)
        XCTAssertEqual(try stringArgument("manifest_path", in: script), manifest)
        let pluginLiteral = try literal(
            in: script, prefix: "# этап 5: загрузка плагина ", suffix: " через SDK-лоадер.")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(pluginLiteral.utf8)), pluginID)

        // Валидного JSON недостаточно: Python оставляет \/ как обратный слеш + /,
        // а UTF-16 surrogate escapes не собирает в один Unicode scalar.
        XCTAssertFalse(script.contains("\\/"))
        XCTAssertTrue(script.contains("雪/😀"))
        for control in ["\r", "\t", "\u{0}", "\u{8}", "\u{c}"] {
            XCTAssertFalse(script.contains(control))
        }
        let plain = PythonRuntimeConfiguration().bootstrapScript(interpreterPluginId: "plain")
        XCTAssertEqual(script.components(separatedBy: "\n").count,
                       plain.components(separatedBy: "\n").count,
                       "Параметры не должны добавлять строки Python-кода")
    }

    private func bootstrapPaths(_ script: String) throws -> [String] {
        let value = try literal(in: script, prefix: "sys.path[:0] = ")
        return try JSONDecoder().decode([String].self, from: Data(value.utf8))
    }

    private func stringArgument(_ name: String, in script: String) throws -> String {
        let value = try literal(in: script, prefix: "    \(name)=", suffix: ",")
        return try JSONDecoder().decode(String.self, from: Data(value.utf8))
    }

    private func literal(in script: String, prefix: String, suffix: String = "") throws -> String {
        let matches = script.components(separatedBy: "\n").filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(suffix)
        }
        XCTAssertEqual(matches.count, 1, "Ожидали одну строку с префиксом \(prefix)")
        let line = try XCTUnwrap(matches.first)
        return String(line.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private func makeAppBundle() throws -> (Bundle, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        let appURL = directory.appendingPathComponent("Bootstrap.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.exteraless.bootstrap",
            "CFBundleName": "Bootstrap",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Info.plist"))
        return (try XCTUnwrap(Bundle(url: appURL)), appURL)
    }
}
