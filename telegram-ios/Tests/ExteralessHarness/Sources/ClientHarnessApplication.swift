import AccountContext
import AsyncDisplayKit
import ClientHarnessAccount
import ClientHarnessAppContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUI
import UIKit
import UIKitRuntimeUtils

@MainActor
@objc(ClientUIHarnessAppDelegate)
public final class ClientUIHarnessAppDelegate: NSObject, UIApplicationDelegate {
    public func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let result = UISceneConfiguration(name: "ClientUIHarness", sessionRole: session.role)
        result.delegateClass = ClientUIHarnessSceneDelegate.self
        return result
    }
}

/// Observes the same scene-owned keyboard as ApplicationStatusBarHost. This
/// supplies Display's real keyboard/window machinery; no inset is invented.
private final class ClientHarnessStatusBarHost: StatusBarHost {
    private weak var scene: UIWindowScene?
    init(scene: UIWindowScene) { self.scene = scene }
    var statusBarFrame: CGRect { self.scene?.statusBarManager?.statusBarFrame ?? .zero }
    var isApplicationInForeground: Bool {
        self.scene?.activationState == .foregroundActive || self.scene?.activationState == .foregroundInactive
    }
    var keyboardWindow: UIWindow? { UIApplication.shared.internalGetKeyboard(for: self.scene) }
    var keyboardView: UIView? {
        guard let window = self.keyboardWindow else { return nil }
        for container in window.subviews {
            let name = NSStringFromClass(type(of: container))
            guard name.hasPrefix("UI") && (name.hasSuffix("InputSetContainerView") || name.hasSuffix("TrackingWindowView")) else { continue }
            for view in container.subviews {
                let name = NSStringFromClass(type(of: view))
                if name.hasPrefix("UI") && (name.hasSuffix("InputSetHostView") || name.hasSuffix("KeyboardItemContainerView")) { return view }
            }
        }
        return nil
    }
}

@MainActor
@objc(ClientUIHarnessSceneDelegate)
public final class ClientUIHarnessSceneDelegate: NSObject, UIWindowSceneDelegate {
    public var window: UIWindow?
    private var displayWindow: Window1?
    private var session: ClientHarnessSession?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard argument("-client-ui-harness") == "1", let runId = argument("-client-run-id"), let scenario = argument("-client-scenario") else {
            fatalError("client-ui-harness: explicit fixture launch arguments are required")
        }
        do {
            let report = try ClientHarnessReport(runId: runId, scenario: scenario)
            let (window, hostView) = nativeWindowHostView(windowScene: scene)
            let display = Window1(hostView: hostView, statusBarHost: ClientHarnessStatusBarHost(scene: scene))
            self.window = window
            self.displayWindow = display
            let run = ClientHarnessSession(window: window, display: display, report: report)
            self.session = run
            window.makeKeyAndVisible()
            run.bootstrap()
        } catch {
            NSLog("CLIENT_UI_HARNESS_BOOT_FAILED %@", String(describing: error))
        }
    }

    public func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts { self.session?.open(context.url) }
    }
}

@MainActor
final class ClientHarnessHomeController: ViewController {
    private let data: PresentationData
    private let settings: () -> Void
    private let plugins: () -> Void
    private var pillHeader: (any ExteralessPillHeader)?
    private let fixtureLabel = UILabel()

    init(data: PresentationData, settings: @escaping () -> Void, plugins: @escaping () -> Void) {
        self.data = data
        self.settings = settings
        self.plugins = plugins
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: data))
        self.title = "UI acceptance fixture"
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.data.theme.list.blocksBackgroundColor
        let title = self.fixtureLabel
        title.text = "Isolated account · fixture services\nProduction controllers / real UIKit"
        title.numberOfLines = 0
        title.textAlignment = .center
        title.textColor = self.data.theme.list.itemPrimaryTextColor
        title.font = .preferredFont(forTextStyle: .body)
        let settings = UIButton(type: .system)
        settings.setTitle("Open client settings", for: .normal)
        settings.addTarget(self, action: #selector(self.openSettings), for: .touchUpInside)
        let plugins = UIButton(type: .system)
        plugins.setTitle("Open plugin manager", for: .normal)
        plugins.addTarget(self, action: #selector(self.openPlugins), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, settings, plugins])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.displayNode.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: self.displayNode.view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: self.displayNode.view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: self.displayNode.view.trailingAnchor, constant: -24),
            settings.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            plugins.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        self.displayNodeDidLoad()
    }
    @objc private func openSettings() { self.settings() }
    @objc private func openPlugins() { self.plugins() }

    func applyFixtureTheme(_ data: PresentationData) {
        if self.isNodeLoaded { self.displayNode.backgroundColor = data.theme.list.blocksBackgroundColor }
        self.fixtureLabel.textColor = data.theme.list.itemPrimaryTextColor
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: data), transition: .immediate)
    }

    func attachPillHeader(_ header: any ExteralessPillHeader) {
        self.pillHeader = header
        self.view.addSubview(header.view)
        header.heightUpdated = { [weak self] in self?.view.setNeedsLayout() }
        header.setVisible(self.view.window != nil)
        self.view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let header = self.pillHeader {
            header.view.frame = CGRect(x: 12, y: self.view.safeAreaInsets.top + 54,
                width: max(0, self.view.bounds.width - 24), height: header.preferredHeight)
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.pillHeader?.setVisible(true)
    }
    override func viewWillDisappear(_ animated: Bool) {
        self.pillHeader?.setVisible(false)
        super.viewWillDisappear(animated)
    }
}

@MainActor
final class ClientHarnessSession {
    let window: UIWindow
    let display: Window1
    let report: ClientHarnessReport
    private var accountDisposable: Disposable?
    private(set) var context: ClientHarnessAccountContext!
    private(set) var settings: ClientSettings!
    private(set) var navigation: NavigationController!
    private(set) var driver: ClientHarnessUIKit!
    private(set) var runtime: ClientHarnessRuntime?
    private(set) var settingsSearchChecks: SettingsSearchUIViewRouteChecks?
    private var started = false
    let viewIdentities = ClientHarnessViewIdentities()

    init(window: UIWindow, display: Window1, report: ClientHarnessReport) {
        self.window = window
        self.display = display
        self.report = report
    }

    func bootstrap() {
        Task { @MainActor in
            do {
                let directory = self.report.directory
                let domain = ClientHarnessScenario.isDomain(self.report.scenario)
                let scenario = self.report.scenario
                try await Task.detached(priority: .userInitiated) {
                    try ClientHarnessBootstrap.prepare(directory: directory, domain: domain, scenario: scenario)
                }.value
                self.report.journal.record("bootstrap-policy-ready")
                self.report.facts["bootstrap"] = ["apiIdentity": "synthetic-private-fixture-store",
                    "retention": "registered-main-application-snapshot-before-writer", "systemKeychain": false]
                try self.report.flush()
                self.accountDisposable = (clientHarnessAccountWithReadiness() |> deliverOnMainQueue).start(next: { [weak self] fixture in
                    guard let self, self.context == nil else { return }
                    Task { @MainActor in
                        do { try await self.ready(fixture) }
                        catch { self.report.fail(error) }
                    }
                }, error: { [weak self] error in
                    self?.report.journal.record("account-readiness-failed", ["typedFailure": String(describing: error)])
                    self?.report.fail(error)
                })
            } catch {
                self.report.fail(error)
            }
        }
    }

    private func ready(_ fixture: HarnessAccount) async throws {
        self.context = ClientHarnessAccountContext(fixture: fixture, window: self.display, dark: self.report.scenario == "core-dark",
            bubbleRendering: self.report.scenario == "feed-render", composerRendering: self.report.scenario == "composer-render")
        if ClientHarnessScenario.isFinalVisual(self.report.scenario) {
            self.report.facts["buildSelection"] = ["bundle": "org.exteraless.ClientUIHarness",
                "target": "//Telegram:ClientUIHarness", "host": "same-client-ui-app",
                "factory": self.report.scenario == "composer-render" ? "makeExteralessComposerPanel" : "AvatarNode public cache/complete-image APIs"]
            self.report.facts["readiness"] = ["authorizedAfterNativeBarrier": true,
                "failureRoute": "ExteralessAccountRecoveryCenter.pending/currentStatus", "retryCount": 0,
                "configurationVersion": ExteralessAccountRetentionEnvironment.shared.current.version]
        }
        let settingsURL = self.report.directory.appendingPathComponent("client-settings.json")
        self.settings = try ClientSettings(storageURL: settingsURL, secretStore: ClientHarnessNoSecrets())
        try self.settings.register([
            .init(key: "harness.enabled", title: "Fixture enabled", section: "Acceptance fixture", defaultValue: .bool(false)),
            .init(key: "harness.mode", title: "Fixture selector", section: "Acceptance fixture", defaultValue: .string("plain"),
                options: [.init(value: .string("plain"), title: "Plain"), .init(value: .string("ocean"), title: "Ocean")]),
            .init(key: "harness.text", title: "Fixture text", section: "Acceptance fixture", defaultValue: .string("")),
            .init(key: "harness.number", title: "Fixture number", section: "Acceptance fixture", defaultValue: .integer(0), minimum: 0, maximum: 10),
        ])
        let data = self.context.shared.currentPresentationData.with { $0 }
        self.window.overrideUserInterfaceStyle = data.theme.overallDarkAppearance ? .dark : .light
        self.navigation = NavigationController(mode: .single, theme: NavigationControllerTheme(presentationTheme: data.theme))
        self.driver = ClientHarnessUIKit(window: self.window, navigation: self.navigation, journal: self.report.journal)
        if ["core-light", "core-dark"].contains(self.report.scenario) {
            let checks = SettingsSearchUIViewRouteChecks(context: self.context, settings: self.settings, navigation: self.navigation)
            self.settingsSearchChecks = checks
            ExteralessSettingsEntry.setControllerFactory { context in exteralessSettingsController(context: context) }
            ExteralessSettingsSearchEntry.install(checks.session)
        }
        let home = ClientHarnessHomeController(data: data, settings: { [weak self] in
            guard let self else { return }
            do {
                guard let controller = try self.settingsSearchChecks?.root()
                    ?? exteralessSettingsController(context: self.context, settings: self.settings) else {
                    throw ClientHarnessFailure(description: "settings Root has no matching live scope")
                }
                self.navigation.pushViewController(controller)
            } catch { self.report.fail(error) }
        }, plugins: { [weak self] in
            guard let self else { return }
            guard let runtime = self.runtime else {
                fatalError("client-ui-harness: plugin route is not provided in a core-only scenario")
            }
            self.navigation.pushViewController(exteralessPluginManagerController(context: self.context, actions: runtime.actions()))
        })
        self.navigation.setViewControllers([home], animated: false)
        self.display.viewController = self.navigation
        if self.report.scenario == "sdk-ui" {
            let runtime = try ClientHarnessRuntime(root: self.report.directory.appendingPathComponent("native-runtime", isDirectory: true),
                context: self.context, scale: Double(self.window.screen.scale), journal: self.report.journal)
            self.runtime = runtime
            try await runtime.start()
        }
        try await self.driver.settle(0.5)
        try clientHarnessRequire(home.view.window === self.window, "Display root never appeared")
        self.report.facts["screenScale"] = self.window.screen.scale
        if ClientHarnessScenario.isReset(self.report.scenario) || ClientHarnessScenario.isTrustSupplement(self.report.scenario)
            || ClientHarnessScenario.isMapSupplement(self.report.scenario) {
            try self.loadDomainSourceEvidence()
        }
        self.report.phase = "ready"
        self.report.journal.record("ready")
        try self.report.flush()
    }

    func open(_ url: URL) {
        guard url.scheme == "exteraless-ui-harness", url.host == "run",
              url.path == "/" + self.report.runId, self.report.phase == "ready", !self.started else { return }
        self.started = true
        Task { @MainActor in
            do {
                self.report.phase = "running"
                self.report.journal.record("scenario-start")
                if ClientHarnessScenario.needsSourceEvidence(self.report.scenario) { try self.loadDomainSourceEvidence() }
                try self.report.flush()
                try await self.runScenario()
                self.report.phase = "completed"
                self.report.journal.record("scenario-complete")
                try self.report.flush()
                NSLog("CLIENT_UI_HARNESS_COMPLETE %@ %@", self.report.runId, self.report.scenario)
            } catch {
                if let runtime = self.runtime {
                    self.report.facts["runtime"] = runtime.snapshot
                }
                self.report.fail(error)
                if let runtime = self.runtime {
                    try? await runtime.stop()
                    self.report.facts["runtime"] = runtime.snapshot
                    try? self.report.flush()
                }
            }
        }
    }

    func setDark(_ dark: Bool) {
        self.context.shared.setDark(dark)
        self.window.overrideUserInterfaceStyle = dark ? .dark : .light
        let data = self.context.shared.currentPresentationData.with { $0 }
        self.navigation.updateTheme(NavigationControllerTheme(presentationTheme: data.theme))
        (self.navigation.viewControllers.first as? ClientHarnessHomeController)?.applyFixtureTheme(data)
    }

    func probe(_ name: String, extra: [String: Any] = [:]) throws {
        var probe = self.driver.snapshot()
        probe["name"] = name
        probe["elapsed"] = ProcessInfo.processInfo.systemUptime - self.report.journal.started
        probe["wallTime"] = Date().timeIntervalSince1970
        probe["dark"] = self.context.shared.currentPresentationData.with { $0 }.theme.overallDarkAppearance
        probe["semantic"] = extra
        self.report.probes.append(probe)
        self.report.journal.record("probe", ["name": name])
        try self.report.flush()
    }
}

private struct ClientHarnessNoSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { fatalError("client-ui-harness: secret reads are not provided") }
    func set(_ data: Data?, for key: String) throws { fatalError("client-ui-harness: secret writes are not provided") }
}
