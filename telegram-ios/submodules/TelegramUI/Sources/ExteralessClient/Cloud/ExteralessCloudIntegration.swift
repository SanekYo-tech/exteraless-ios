import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramCore
import UIKit

private final class ExteralessCloudNotificationToken: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor public final class ExteralessCloudIntegration {
    private let settings: ClientSettings
    private let clientAPI: ClientAPIConfigurationStore
    private let credentials: any CloudCredentialStorage
    private weak var context: AccountContext?
    private var bindings: ExteralessToolsBackupBindings?
    private var archiveHost: ExteralessCloudArchiveHost?
    private var session: CloudSyncSession?
    private var automatic: CloudAutoSync?
    private var foregroundObserver: ExteralessCloudNotificationToken?
    private var backgroundObserver: ExteralessCloudNotificationToken?
    private var error: CloudError?
    private final class Screen {
        weak var controller: ExteralessCloudListController?
        init(_ controller: ExteralessCloudListController) { self.controller = controller }
    }
    private var screens: [Screen] = []

    public init(settings: ClientSettings = .shared, clientAPI: ClientAPIConfigurationStore? = nil,
                credentials: any CloudCredentialStorage = CloudCredentials.systemStorage()) {
        self.settings = settings
        self.clientAPI = clientAPI ?? ClientAPIConfigurationStore(settings: settings)
        self.credentials = credentials
        foregroundObserver = ExteralessCloudNotificationToken(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.automatic?.setForeground(true) }
        })
        backgroundObserver = ExteralessCloudNotificationToken(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.automatic?.setForeground(false)
                self?.session?.cancel()
            }
        })
    }

    /// Pass the SAME already-bound Tools settings/maintenance host. No plugin
    /// get_settings call, Python startup or document discovery occurs here.
    public func configure(backupBindings: ExteralessToolsBackupBindings?) {
        bindings = backupBindings
        archiveHost = backupBindings.map { ExteralessCloudArchiveHost(settings: settings, credentials: credentials, bindings: $0) }
        if let archiveHost {
            session?.restore = { plan, keys, admission in try await archiveHost.restore(plan, includeApiKeys: keys, admission: admission) }
            session?.restoreAndroid = { plan, keys, admission in try await archiveHost.restore(plan, includeApiKeys: keys, admission: admission) }
        } else {
            session?.restore = nil
            session?.restoreAndroid = nil
        }
        refreshScreens()
    }

    public func update(context: AccountContext) {
        if self.context !== context { clearContext() }
        self.context = context
        if session == nil {
            do {
                let transport = ExteralessCloudTransport(account: context.account)
                let root = URL(fileURLWithPath: context.sharedContext.basePath, isDirectory: true)
                    .appendingPathComponent("exteraless", isDirectory: true).appendingPathComponent("cloud", isDirectory: true)
                let storage = try CloudFileStateStorage(directory: root)
                let remote = CloudRemoteStore(owner: transport.scope.owner, transport: transport, compression: ExteralessCloudTransport.compression)
                let session = try CloudSyncSession(scope: transport.scope, settings: settings, remote: remote, stateStorage: storage,
                    credentials: credentials, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
                self.session = session
                automatic = CloudAutoSync(settings: settings, session: session)
                session.didChange = { [weak self] in
                    self?.automatic?.sessionDidChange()
                    self?.refreshScreens()
                }
                configure(backupBindings: bindings)
                automatic?.setForeground(UIApplication.shared.applicationState == .active)
                error = nil
            } catch { self.error = (error as? CloudError) ?? .localStorage }
        }
        registerActions()
    }

    public func clearContext() {
        context = nil
        automatic?.clear()
        automatic = nil
        session?.clear()
        session = nil
        for screen in screens { screen.controller?.clearCloudContext() }
        screens.removeAll()
        ExteralessSettingsUI.unregisterActions(ids: ["cloud.settings", "clientAPI.edit"])
    }

    private func registerActions() {
        ExteralessSettingsUI.registerActions([
            .init(id: "cloud.settings", title: "Cloud settings and restore", section: "Cloud settings", action: { [weak self] context, presenter in
                guard let self, self.context === context else { return }
                guard let session = self.session else {
                    let alert = UIAlertController(title: "Cloud settings", message: (self.error ?? .localStorage).errorDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                    presenter.present(alert, animated: true)
                    return
                }
                let controller = ExteralessCloudController(context: context, settings: self.settings, session: session)
                self.track(controller)
                presenter.push(controller)
            }),
            .init(id: "clientAPI.edit", title: "Client API · effective after restart", section: "Client API", action: { [weak self] context, presenter in
                guard let self, self.context === context else { return }
                let controller = ExteralessClientAPIController(context: context, configuration: self.clientAPI)
                self.track(controller)
                presenter.push(controller)
            })
        ])
    }

    private func track(_ controller: ExteralessCloudListController) {
        screens.removeAll { $0.controller == nil }
        screens.append(Screen(controller))
    }

    private func refreshScreens() {
        screens.removeAll { $0.controller == nil }
        for screen in screens { screen.controller?.render() }
    }
}
