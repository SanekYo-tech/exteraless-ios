import AccountContext
import Display
import ExteralessCore
import Foundation
import GalleryUI
import UIKit

public struct ExteralessToolsShortcutBindings {
    public let ghostMode: @MainActor () -> Bool
    public let safeMode: @MainActor () -> Bool
    /// Return the confirmed post-operation state, not the requested state.
    public let toggleGhostMode: @MainActor () async throws -> Bool
    public let toggleSafeMode: @MainActor () async throws -> Bool

    public init(ghostMode: @escaping @MainActor () -> Bool, safeMode: @escaping @MainActor () -> Bool,
                toggleGhostMode: @escaping @MainActor () async throws -> Bool,
                toggleSafeMode: @escaping @MainActor () async throws -> Bool) {
        self.ghostMode = ghostMode
        self.safeMode = safeMode
        self.toggleGhostMode = toggleGhostMode
        self.toggleSafeMode = toggleSafeMode
    }
}

@MainActor public final class ExteralessToolsIntegration {
    public static let ghostShortcutType = "app.exteraless.action.TOGGLE_GHOST_MODE"
    public static let safeShortcutType = "app.exteraless.action.TOGGLE_SAFE_MODE"
    private let backupService: ExteralessToolsBackupService
    private var shortcutBindings: ExteralessToolsShortcutBindings?
    private let updateClient: ToolsReleaseClient
    private let diagnostics = ExteralessToolsDiagnostics()
    private var hasContext = false
    private var generation = UUID()
    private var automaticCheck: Task<Void, Never>?
    private var automaticGeneration = UUID()
    private var shortcutTask: Task<Void, Never>?
    private var shortcutCompletion: ((Bool) -> Void)?
    private var observation: ClientSettingsObservation?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var originalShortcutItems: [UIApplicationShortcutItem]?
    private weak var gallerySubtitleContext: AccountContext?
    private var gallerySubtitleRegistration: UUID?
    private var gallerySubtitleStore: (directory: URL, value: ToolsSubtitleStore)?
    public private(set) var lastUpdateError: String?
    private var lastRelease: ToolsGitHubRelease?

    private final class WeakScreen {
        weak var value: ExteralessToolsListController?
        init(_ value: ExteralessToolsListController) { self.value = value }
    }
    private var screens: [WeakScreen] = []

    public init(backupBindings: ExteralessToolsBackupBindings? = nil,
                shortcutBindings: ExteralessToolsShortcutBindings? = nil,
                updateClient: ToolsReleaseClient = ToolsReleaseClient()) {
        self.backupService = ExteralessToolsBackupService(bindings: backupBindings)
        self.shortcutBindings = shortcutBindings
        self.updateClient = updateClient
        observation = ClientSettings.shared.observe { [weak self] keys in
            guard keys.isEmpty || keys.contains("tools.autoUpdateChannel") || keys.contains("tools.quickToggles") || keys.contains("tools.crashReports") else { return }
            Task { @MainActor [weak self] in
                self?.updateShortcuts()
                self?.updateDiagnostics()
                if keys.contains("tools.autoUpdateChannel") {
                    self?.automaticGeneration = UUID()
                    self?.automaticCheck?.cancel()
                    self?.automaticCheck = nil
                }
                self?.checkAutomatically(force: keys.contains("tools.autoUpdateChannel"))
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAutomatically() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.diagnostics.stopProfile() }
        }
    }

    deinit {
        observation?.cancel()
        automaticCheck?.cancel()
        shortcutTask?.cancel()
        if let registration = gallerySubtitleRegistration {
            Task { @MainActor in ExteralessGallerySubtitleBridge.unregister(registration) }
        }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    /// Late binding is useful when the composition root creates the tools facade
    /// before its PluginHost is ready. Call on main, before starting a restore.
    public func configure(backupBindings: ExteralessToolsBackupBindings?, shortcutBindings: ExteralessToolsShortcutBindings?) {
        self.backupService.bindings = backupBindings
        self.shortcutBindings = shortcutBindings
        if hasContext { registerActions(); updateShortcuts() }
    }

    public func update(context: AccountContext) {
        hasContext = true
        updateGallerySubtitles(context: context)
        updateDiagnostics()
        registerActions()
        updateShortcuts()
        checkAutomatically()
    }

    public func clearContext() {
        hasContext = false
        clearGallerySubtitles()
        generation = UUID()
        automaticCheck?.cancel()
        automaticCheck = nil
        shortcutTask?.cancel()
        shortcutTask = nil
        let completion = shortcutCompletion
        shortcutCompletion = nil
        completion?(false)
        diagnostics.stopCollection()
        for screen in screens { screen.value?.clearToolsContext() }
        screens.removeAll()
        ExteralessSettingsUI.unregisterActions(ids: ["tools.backup", "tools.updates", "tools.diagnostics", "tools.files", "tools.shortcuts", "tools.favoriteStickers", "tools.fileSaving"])
    }

    private func updateGallerySubtitles(context: AccountContext) {
        if gallerySubtitleContext === context, let registration = gallerySubtitleRegistration,
           ExteralessGallerySubtitleBridge.isRegistered(registration) { return }
        clearGallerySubtitles()
        let directory = URL(fileURLWithPath: context.sharedContext.basePath, isDirectory: true)
            .appendingPathComponent("exteraless/gallery-subtitles", isDirectory: true).standardizedFileURL
        let store: ToolsSubtitleStore
        if let cached = gallerySubtitleStore, cached.directory == directory {
            store = cached.value
        } else {
            store = ToolsSubtitleStore(directory: directory)
            gallerySubtitleStore = (directory, store)
        }
        gallerySubtitleContext = context
        gallerySubtitleRegistration = ExteralessGallerySubtitleBridge.register(
            accountId: context.account.id.int64, contextIdentity: ObjectIdentifier(context), make: { identity, container in
                let adapter = ExteralessGallerySubtitleAdapter(identity: identity, container: container, store: store)
                return ExteralessGallerySubtitleControls(
                    update: { adapter.update(sample: $0) }, visible: { adapter.setVisible($0) },
                    layout: { adapter.updateLayout(in: $0, bottomInset: $1, transition: $2) },
                    select: { adapter.select(from: $0) }, clear: { adapter.clear(from: $0) },
                    dispose: { adapter.dispose() })
            })
    }

    private func clearGallerySubtitles() {
        if let registration = gallerySubtitleRegistration {
            ExteralessGallerySubtitleBridge.unregister(registration)
        }
        gallerySubtitleRegistration = nil
        gallerySubtitleContext = nil
    }

    private func track(_ controller: ExteralessToolsListController) {
        screens.removeAll { $0.value == nil }
        screens.append(WeakScreen(controller))
    }

    private func updateDiagnostics() {
        if hasContext && ClientSettings.shared.bool("tools.crashReports") { diagnostics.startCollection() }
        else { diagnostics.stopCollection() }
    }

    private func registerActions() {
        var actions: [ExteralessSettingsAction] = [
            .init(id: "tools.fileSaving", title: "Files destination", section: "Downloads", action: { [weak self] context, presenter in
                guard let self, self.hasContext else { return }
                let controller = ExteralessFileSavingController(context: context)
                self.track(controller)
                presenter.push(controller)
            }),
            .init(id: "tools.favoriteStickers", title: "Favorite-sticker backup", section: "Tools", action: { [weak self] context, presenter in
                guard let self, self.hasContext else { return }
                let controller = ExteralessFavoriteStickersController(context: context)
                self.track(controller)
                presenter.push(controller)
            }),
            .init(id: "tools.backup", title: "Configuration backup", section: "Tools", action: { [weak self] context, presenter in
                guard let self, self.hasContext else { return }
                let controller = ExteralessBackupController(context: context, service: self.backupService)
                self.track(controller)
                presenter.push(controller)
            }),
            .init(id: "tools.updates", title: updateTitle, section: "Tools", action: { [weak self] context, presenter in
                guard let self, self.hasContext else { return }
                let controller = ExteralessUpdateController(context: context, client: self.updateClient,
                    cachedRelease: self.lastRelease, lastError: self.lastUpdateError, onChecked: { [weak self] release in
                        self?.lastRelease = release
                        self?.lastUpdateError = nil
                        self?.registerActions()
                    }, onSkip: { [weak self] tag in
                        UserDefaults.standard.set(tag, forKey: "ExteralessToolsSkippedUpdate")
                        self?.registerActions()
                    })
                self.track(controller)
                presenter.push(controller)
            }),
            .init(id: "tools.diagnostics", title: "Diagnostics", section: "Tools", action: { [weak self] context, presenter in
                guard let self, self.hasContext else { return }
                let controller = ExteralessDiagnosticsController(context: context, diagnostics: self.diagnostics)
                self.track(controller)
                presenter.push(controller)
            }),
            .init(id: "tools.files", title: "Files and device utilities", section: "Tools", action: { [weak self] context, presenter in
                guard let self, self.hasContext else { return }
                let controller = ExteralessFileUtilitiesController(context: context)
                self.track(controller)
                presenter.push(controller)
            })
        ]
        if let bindings = shortcutBindings {
            actions.append(.init(id: "tools.shortcuts", title: "Quick toggles", section: "Tools", action: { [weak self] context, presenter in
                guard let self, self.hasContext else { return }
                let controller = ExteralessToolsShortcutsController(context: context, bindings: bindings)
                self.track(controller)
                presenter.push(controller)
            }))
        } else { ExteralessSettingsUI.unregisterActions(ids: ["tools.shortcuts"]) }
        ExteralessSettingsUI.registerActions(actions)
    }

    /// Chat document/open-in handoff: the coordinator calls only for a downloaded
    /// file. The factory never starts PluginHost or executes the inspected payload.
    public func openBackup(url: URL, context: AccountContext, from presenter: ViewController) {
        guard hasContext else { return }
        let controller = ExteralessBackupController(context: context, service: backupService)
        track(controller)
        presenter.push(controller)
        controller.inspectFile(url)
    }

    private var updateTitle: String {
        guard let release = lastRelease, UserDefaults.standard.string(forKey: "ExteralessToolsSkippedUpdate") != release.tag,
              let remote = release.version,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let local = ToolsReleaseVersion(tag: version, buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
              remote.compared(to: local) == .newer else { return "Updates" }
        return "Update available · " + release.tag
    }

    private func checkAutomatically(force: Bool = false) {
        guard hasContext, automaticCheck == nil, UIApplication.shared.applicationState == .active else { return }
        let channel = ClientSettings.shared.integer("tools.autoUpdateChannel")
        let now = Date()
        let last = UserDefaults.standard.object(forKey: "ExteralessToolsLastUpdateAttempt") as? Date
        guard channel == 1 || channel == 2,
              force || ToolsUpdateSchedule.shouldCheck(channel: channel, lastAttempt: last, now: now) else { return }
        // Persist attempts too, preventing request storms on rate-limit/offline errors.
        UserDefaults.standard.set(now, forKey: "ExteralessToolsLastUpdateAttempt")
        let generation = generation
        let checkId = UUID()
        automaticGeneration = checkId
        let client = updateClient
        automaticCheck = Task { @MainActor [weak self] in
            do {
                let release = try await client.latest(includePrereleases: channel == 2)
                guard let self, self.hasContext, self.generation == generation, self.automaticGeneration == checkId, !Task.isCancelled else { return }
                self.lastRelease = release
                self.lastUpdateError = nil
                self.automaticCheck = nil
                self.registerActions()
            } catch {
                guard let self, self.generation == generation, self.automaticGeneration == checkId else { return }
                self.lastUpdateError = error is CancellationError ? nil : pluginErrorText(error)
                self.automaticCheck = nil
            }
        }
    }

    private func updateShortcuts() {
        guard hasContext, shortcutBindings != nil else { return }
        let enabled = ClientSettings.shared.bool("tools.quickToggles")
        let types = Set([Self.ghostShortcutType, Self.safeShortcutType])
        if enabled {
            let current = UIApplication.shared.shortcutItems ?? []
            if originalShortcutItems == nil { originalShortcutItems = current.filter { !types.contains($0.type) } }
            let stock = current.filter { !types.contains($0.type) }
            UIApplication.shared.shortcutItems = [
                UIApplicationShortcutItem(type: Self.ghostShortcutType, localizedTitle: "Toggle Ghost mode", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "eye.slash"), userInfo: nil),
                UIApplicationShortcutItem(type: Self.safeShortcutType, localizedTitle: "Toggle Plugin safe mode", localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "shield"), userInfo: nil)
            ] + Array(stock.prefix(2))
        } else if let originalShortcutItems {
            UIApplication.shared.shortcutItems = originalShortcutItems
            self.originalShortcutItems = nil
        }
    }

    /// Invoke after the stock app-lock gate and after update(context:). Returns
    /// whether this integration owns the type; completion is called exactly once.
    @discardableResult public func handleShortcut(type: String, completion: @escaping (Bool) -> Void) -> Bool {
        let isGhost = type == Self.ghostShortcutType
        guard isGhost || type == Self.safeShortcutType else { return false }
        guard hasContext, let bindings = shortcutBindings, shortcutTask == nil else { completion(false); return true }
        let generation = generation
        shortcutCompletion = completion
        shortcutTask = Task { @MainActor [weak self] in
            let succeeded: Bool
            do {
                let enabled = try await (isGhost ? bindings.toggleGhostMode() : bindings.toggleSafeMode())
                succeeded = !Task.isCancelled
                if succeeded {
                    UIAccessibility.post(notification: .announcement, argument: "\(isGhost ? "Ghost mode" : "Plugin safe mode") \(enabled ? "enabled" : "disabled")")
                }
            } catch { succeeded = false }
            guard let self, self.generation == generation else { return }
            let completion = self.shortcutCompletion
            self.shortcutCompletion = nil
            self.shortcutTask = nil
            completion?(succeeded)
        }
        return true
    }
}

final class ExteralessToolsShortcutsController: ExteralessToolsListController {
    private let bindings: ExteralessToolsShortcutBindings

    init(context: AccountContext, bindings: ExteralessToolsShortcutBindings) {
        self.bindings = bindings
        super.init(context: context)
        title = "Quick toggles"
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func render() {
        setSections(operationSections() + [PluginListSection(rows: [
            exteralessToolsAction("ghost", bindings.ghostMode() ? "Disable Ghost mode" : "Enable Ghost mode", enabled: !isBusy && contextAvailable) { [weak self] in self?.toggle(ghost: true) },
            exteralessToolsAction("safe", bindings.safeMode() ? "Disable Plugin safe mode" : "Enable Plugin safe mode", enabled: !isBusy && contextAvailable) { [weak self] in self?.toggle(ghost: false) }
        ])])
    }

    private func toggle(ghost: Bool) {
        let bindings = bindings
        canCancelWork = false
        runToolsOperation(title: "Applying \(ghost ? "Ghost mode" : "Plugin safe mode")…", operation: {
            try await (ghost ? bindings.toggleGhostMode() : bindings.toggleSafeMode())
        }, completion: { [weak self] enabled in
            self?.toolsStatus = "\(ghost ? "Ghost mode" : "Plugin safe mode") \(enabled ? "enabled" : "disabled")"
            self?.canCancelWork = true
        })
    }
}
