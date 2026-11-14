import AccountContext
import Display
import Foundation
import PluginHost
import SwiftSignalKit
import UIKit
import UniformTypeIdentifiers

/// UI-facing host contract. Reads are cheap synchronized snapshots. Async actions
/// return only after their real host operation, throwing its error on failure.
/// settings returns the SDK JSON array; updateSetting receives a JSON scalar.
/// Subpages arrive as sub_page arrays, and callback ids are opaque host tokens.
public struct PluginManagerActions {
    public let status: () -> String
    public let snapshot: () -> [Plugin]
    public let importPlugin: (URL) async throws -> Void
    public let setEnabled: (String, Bool) async throws -> Void
    public let remove: (String) async throws -> Void
    public let settings: (String) async throws -> String
    public let updateSetting: (String, String, String) async throws -> Void
    public let click: (String, String) async throws -> Void
    public let logs: () -> [String]
    public let permissions: ((String) -> [PluginPermission])?
    public let setPermissions: ((String, [PluginPermission]) async throws -> Void)?

    public init(status: @escaping () -> String, snapshot: @escaping () -> [Plugin], importPlugin: @escaping (URL) async throws -> Void, setEnabled: @escaping (String, Bool) async throws -> Void, remove: @escaping (String) async throws -> Void, settings: @escaping (String) async throws -> String, updateSetting: @escaping (String, String, String) async throws -> Void, click: @escaping (String, String) async throws -> Void, logs: @escaping () -> [String], permissions: ((String) -> [PluginPermission])? = nil, setPermissions: ((String, [PluginPermission]) async throws -> Void)? = nil) {
        self.status = status
        self.snapshot = snapshot
        self.importPlugin = importPlugin
        self.setEnabled = setEnabled
        self.remove = remove
        self.settings = settings
        self.updateSetting = updateSetting
        self.click = click
        self.logs = logs
        self.permissions = permissions
        self.setPermissions = setPermissions
    }
}

/// Application entry point registered through AccountContext.ExteralessPluginEntry.
@MainActor public func exteralessPluginManagerController(context: AccountContext) -> ViewController {
    precondition(Thread.isMainThread)
    let runtime = ExteralessPluginRuntime.shared
    runtime.update(context: context)
    return exteralessPluginManagerController(context: context, actions: PluginManagerActions(
        status: { runtime.status },
        snapshot: { runtime.snapshot() },
        importPlugin: { url in try await runtime.importPlugin(url: url) },
        setEnabled: { id, enabled in try await runtime.setEnabled(id: id, enabled: enabled) },
        remove: { id in try await runtime.remove(id: id) },
        settings: { id in try await runtime.settings(id: id) },
        updateSetting: { id, key, json in try await runtime.updateSetting(id: id, key: key, jsonValue: json) },
        click: { id, callbackId in try await runtime.click(id: id, callbackId: callbackId) },
        logs: { runtime.logs() },
        permissions: { runtime.grantedPermissions(id: $0) },
        setPermissions: { id, permissions in try await runtime.setPermissions(id: id, permissions: permissions) }
    ))
}

/// Also allows a controlled UI fixture to supply real completion/error states.
public func exteralessPluginManagerController(context: AccountContext, actions: PluginManagerActions) -> ViewController {
    return PluginManagerController(context: context, actions: actions, mode: .list)
}

private final class PluginManagerController: PluginListController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    enum Mode {
        case list
        case plugin(String)
        case logs
    }

    private let actions: PluginManagerActions
    private let mode: Mode
    private var plugins: [Plugin] = []
    private var runtimeStatus = ""
    private var logLines: [String] = []
    private var pollingTimer: SwiftSignalKit.Timer?
    private var isPickingDocument = false

    init(context: AccountContext, actions: PluginManagerActions, mode: Mode) {
        self.actions = actions
        self.mode = mode
        super.init(context: context)
        self.readSnapshot(force: true)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.pollingTimer?.invalidate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // No Python is called by this timer. It observes cached startup/watchdog
        // changes even when they originate outside this screen.
        self.pollingTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: 2.0, repeat: true, completion: { [weak self] in
            guard let self, !self.isBusy, !self.tableView.isTracking, !self.tableView.isDecelerating else { return }
            self.readSnapshot(force: false)
        }, queue: .mainQueue())
        self.pollingTimer = timer
        timer.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.pollingTimer?.invalidate()
        self.pollingTimer = nil
        super.viewWillDisappear(animated)
    }

    override func refresh() {
        self.readSnapshot(force: true)
        self.tableView.refreshControl?.endRefreshing()
    }

    private func readSnapshot(force: Bool) {
        let plugins = self.actions.snapshot().sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
        let status = self.actions.status()
        var logs: [String] = []
        if case .logs = self.mode {
            logs = self.actions.logs().suffix(100).map { line in
                let prefix = line.prefix(2000)
                return String(prefix) + (prefix.endIndex == line.endIndex ? "" : "\n…")
            }
        }
        if force || plugins != self.plugins || status != self.runtimeStatus || logs != self.logLines {
            self.plugins = plugins
            self.runtimeStatus = status
            self.logLines = logs
            self.render()
        }
    }

    override func render() {
        switch self.mode {
        case .list:
            self.renderList()
        case let .plugin(id):
            self.renderPlugin(id: id)
        case .logs:
            self.renderLogs()
        }
    }

    private func runtimeSection() -> PluginListSection {
        return PluginListSection(rows: [PluginListRow(id: "runtime", title: pluginText("Runtime.Title", "Runtime"), detail: self.runtimeStatus)])
    }

    private func renderList() {
        self.title = pluginText("Plugins.Title", "Plugins")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: pluginText("Import.Action", "Import"), style: .plain, target: self, action: #selector(self.importPressed))
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy && !self.isPickingDocument
        var sections = self.operationSections()
        sections.append(self.runtimeSection())
        var importRow = PluginListRow(id: "import", title: pluginText("Import.File", "Import plugin"), detail: pluginText("Import.Formats", "Choose a .plugin or .py file in Files."))
        importRow.style = .accent
        importRow.enabled = !self.isBusy && !self.isPickingDocument
        importRow.action = { [weak self] in self?.importPressed() }
        sections.append(PluginListSection(rows: [importRow]))
        var rows: [PluginListRow] = []
        for plugin in self.plugins {
            var row = PluginListRow(id: "plugin:\(plugin.id)", title: plugin.displayName.isEmpty ? plugin.id : plugin.displayName, detail: self.subtitle(plugin))
            row.accessory = .disclosure
            row.enabled = !self.isBusy
            row.toggle = (plugin.enabled, { [weak self] enabled in self?.setEnabled(id: plugin.id, enabled: enabled) })
            row.action = { [weak self] in
                guard let self else { return }
                self.push(PluginManagerController(context: self.context, actions: self.actions, mode: .plugin(plugin.id)))
            }
            row.remove = { [weak self] in self?.confirmRemove(plugin) }
            if plugin.loadError != nil || plugin.notResponding { row.style = .error }
            rows.append(row)
        }
        if rows.isEmpty {
            rows.append(PluginListRow(id: "empty", title: pluginText("Plugins.Empty", "No plugins"), detail: pluginText("Plugins.EmptyInfo", "Imported plugins and their runtime state will appear here.")))
        }
        sections.append(PluginListSection(title: pluginText("Plugins.Installed", "Installed plugins"), rows: rows))
        var logRow = PluginListRow(id: "logs", title: pluginText("Logs.Title", "Runtime log"), detail: pluginText("Logs.Summary", "Last 100 entries"))
        logRow.accessory = .disclosure
        logRow.action = { [weak self] in
            guard let self else { return }
            self.push(PluginManagerController(context: self.context, actions: self.actions, mode: .logs))
        }
        sections.append(PluginListSection(rows: [logRow]))
        self.setSections(sections)
    }

    private func renderPlugin(id: String) {
        self.navigationItem.rightBarButtonItem = nil
        var sections = self.operationSections()
        sections.append(self.runtimeSection())
        guard let plugin = self.plugins.first(where: { $0.id == id }) else {
            self.title = pluginText("Plugin.Title", "Plugin")
            sections.append(PluginListSection(rows: [PluginListRow(id: "missing", title: pluginText("Plugin.Missing", "Plugin not found"))]))
            self.setSections(sections)
            return
        }
        self.title = plugin.displayName
        var enabledRow = PluginListRow(id: "enabled", title: pluginText("Plugin.Enabled", "Enabled"), detail: self.stateDescription(plugin))
        enabledRow.enabled = !self.isBusy
        enabledRow.toggle = (plugin.enabled, { [weak self] enabled in self?.setEnabled(id: id, enabled: enabled) })
        sections.append(PluginListSection(rows: [enabledRow]))

        var information = [PluginListRow(id: "identity", title: plugin.displayName, detail: "\(plugin.id)\n\(plugin.subtitle)")]
        if let description = plugin.description, !description.isEmpty {
            information.append(PluginListRow(id: "description", title: pluginText("Plugin.Description", "Description"), detail: description))
        }
        if let version = plugin.sdkVersion {
            information.append(PluginListRow(id: "sdk-version", title: pluginText("Plugin.SDKVersion", "SDK version"), detail: version))
        }
        if let version = plugin.appVersion {
            information.append(PluginListRow(id: "app-version", title: pluginText("Plugin.AppVersion", "App version requirement"), detail: version))
        }
        if plugin.beta {
            information.append(PluginListRow(id: "beta", title: pluginText("Plugin.Beta", "Beta release")))
        }
        if !plugin.requirements.isEmpty {
            information.append(PluginListRow(id: "requirements", title: pluginText("Plugin.Requirements", "Python requirements"), detail: plugin.requirements.joined(separator: "\n")))
        }
        let permissions: String
        if plugin.permissionsDeclared {
            permissions = plugin.permissions.isEmpty ? pluginText("Plugin.NoPermissions", "None declared") : plugin.permissions.joined(separator: "\n")
        } else {
            permissions = pluginText("Plugin.PermissionsNotDeclared", "Not declared")
        }
        information.append(PluginListRow(id: "permissions", title: pluginText("Plugin.Permissions", "Declared permissions"), detail: permissions))
        sections.append(PluginListSection(rows: information))

        if let readPermissions = self.actions.permissions, let updatePermissions = self.actions.setPermissions {
            let granted = Set(readPermissions(id))
            var permissionRows: [PluginListRow] = []
            for permission in PluginPermission.requestable {
                var row = PluginListRow(id: "permission:\(permission.rawValue)", title: permission.describe,
                                        detail: permission.rawValue)
                row.enabled = !self.isBusy
                row.toggle = (granted.contains(permission), { [weak self] enabled in
                    guard let self else { return }
                    var next = Set(readPermissions(id))
                    if enabled { next.insert(permission) } else { next.remove(permission) }
                    let values = PluginPermission.allCases.filter { next.contains($0) }
                    self.perform(title: pluginText("Plugin.UpdatingPermissions", "Updating permissions…"), operation: {
                        try await updatePermissions(id, values)
                    }, completion: { [weak self] _ in self?.readSnapshot(force: true) },
                       failed: { [weak self] in self?.readSnapshot(force: true) })
                })
                permissionRows.append(row)
            }
            sections.append(PluginListSection(title: pluginText("Plugin.GrantedPermissions", "Granted permissions"), rows: permissionRows))
        }

        if let loadError = plugin.loadError {
            var row = PluginListRow(id: "load-error", title: pluginText("Plugin.LoadError", "Load error"), detail: loadError)
            row.style = .error
            row.action = { UIPasteboard.general.string = plugin.loadDebug ?? loadError }
            sections.append(PluginListSection(footer: pluginText("Error.CopyHint", "Tap to copy the error."), rows: [row]))
        }
        if let debug = plugin.loadDebug, debug != plugin.loadError, !debug.isEmpty {
            var row = PluginListRow(id: "debug", title: pluginText("Plugin.Diagnostics", "Diagnostics"), detail: String(debug.prefix(16000)))
            row.action = { UIPasteboard.general.string = debug }
            sections.append(PluginListSection(rows: [row]))
        }
        if plugin.hasSettings {
            var row = PluginListRow(id: "settings", title: pluginText("Plugin.Settings", "Plugin settings"))
            row.accessory = .disclosure
            row.enabled = !self.isBusy && plugin.loaded && plugin.isEnabled && !plugin.notResponding
            if !row.enabled && !self.isBusy {
                row.detail = pluginText("Plugin.SettingsUnavailable", "Settings require a running plugin.")
            }
            row.action = { [weak self] in
                guard let self else { return }
                self.push(PluginSettingsController(context: self.context, actions: self.actions, pluginId: id, title: plugin.displayName))
            }
            sections.append(PluginListSection(rows: [row]))
        } else if plugin.loaded {
            sections.append(PluginListSection(rows: [PluginListRow(id: "no-settings", title: pluginText("Plugin.NoSettings", "This plugin does not provide settings."))]))
        }
        var removeRow = PluginListRow(id: "remove", title: pluginText("Plugin.Remove", "Delete plugin"))
        removeRow.style = .destructive
        removeRow.enabled = !self.isBusy
        removeRow.action = { [weak self] in self?.confirmRemove(plugin) }
        sections.append(PluginListSection(rows: [removeRow]))
        self.setSections(sections)
    }

    private func renderLogs() {
        self.title = pluginText("Logs.Title", "Runtime log")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Conversation_ContextMenuCopy, style: .plain, target: self, action: #selector(self.copyLogs))
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.logLines.isEmpty
        var rows = self.logLines.enumerated().map { index, line in
            return PluginListRow(id: "log:\(index)", title: line)
        }
        if rows.isEmpty {
            rows.append(PluginListRow(id: "empty-log", title: pluginText("Logs.Empty", "No log entries")))
        }
        self.setSections([self.runtimeSection(), PluginListSection(footer: pluginText("Logs.Limit", "Shows the last 100 entries, up to 2,000 characters per entry. Pull to refresh."), rows: rows)])
    }

    private func stateDescription(_ plugin: Plugin) -> String {
        if plugin.notResponding { return pluginText("Plugin.NotResponding", "Not responding") }
        if plugin.loadError != nil { return pluginText("Plugin.Failed", "Load failed") }
        if plugin.loaded { return pluginText("Plugin.Running", "Running") }
        if plugin.enabled { return pluginText("Plugin.NotLoaded", "Enabled · Not loaded") }
        return pluginText("Plugin.Disabled", "Disabled")
    }

    private func subtitle(_ plugin: Plugin) -> String {
        var lines = [plugin.subtitle, self.stateDescription(plugin)]
        if let error = plugin.loadError {
            let prefix = error.prefix(240)
            lines.append(String(prefix) + (prefix.endIndex == error.endIndex ? "" : "…"))
        }
        return lines.joined(separator: "\n")
    }

    private func setEnabled(id: String, enabled: Bool) {
        let actions = self.actions
        self.perform(title: pluginText("Plugin.Updating", "Updating plugin…"), operation: {
            try await actions.setEnabled(id, enabled)
        }, completion: { [weak self] _ in
            self?.readSnapshot(force: true)
        }, failed: { [weak self] in
            self?.readSnapshot(force: true)
        })
    }

    private func confirmRemove(_ plugin: Plugin) {
        guard !self.isBusy else { return }
        let alert = UIAlertController(title: pluginText("Plugin.Remove", "Delete plugin"), message: plugin.displayName, preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        alert.view.tintColor = self.presentationData.theme.list.itemAccentColor
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Delete, style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            let actions = self.actions
            self.perform(title: pluginText("Plugin.Removing", "Deleting plugin…"), operation: {
                try await actions.remove(plugin.id)
            }, completion: { [weak self] _ in
                guard let self else { return }
                self.readSnapshot(force: true)
                if case .plugin = self.mode, self.isScreenVisible, !self.plugins.contains(where: { $0.id == plugin.id }) {
                    self.dismiss(animated: true)
                }
            }, failed: { [weak self] in self?.readSnapshot(force: true) })
        }))
        self.present(alert, animated: true)
    }

    @objc private func copyLogs() {
        UIPasteboard.general.string = self.logLines.joined(separator: "\n")
    }

    @objc private func importPressed() {
        guard !self.isBusy, !self.isPickingDocument else { return }
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            // Unregistered .plugin files are reported as generic data by some
            // document providers. Validate the extension after selection as well.
            let pluginType = UTType(filenameExtension: "plugin", conformingTo: .data) ?? .data
            let pythonType = UTType(filenameExtension: "py", conformingTo: .text) ?? .text
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [pluginType, pythonType, .data], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.data", "public.python-script"], in: .import)
        }
        self.isPickingDocument = true
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.render()
        self.present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.isPickingDocument = false
        self.render()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        self.isPickingDocument = false
        self.render()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.isPickingDocument = false
        guard let url = urls.first else { self.render(); return }
        let actions = self.actions
        self.perform(title: pluginText("Import.Working", "Importing plugin…"), operation: {
            let copy = try await PluginImportCopy.create(from: url)
            defer { try? FileManager.default.removeItem(at: copy.directory) }
            try Task.checkCancellation()
            // The coordinator parses metadata using native Python AST and copies
            // the validated source into its durable Application Support store.
            try await actions.importPlugin(copy.url)
        }, completion: { [weak self] _ in
            self?.readSnapshot(force: true)
        }, failed: { [weak self] in
            self?.readSnapshot(force: true)
        })
    }
}

private struct PluginImportCopy: Sendable {
    let url: URL
    let directory: URL

    static func create(from url: URL) async throws -> PluginImportCopy {
        guard url.isFileURL, ["plugin", "py"].contains(url.pathExtension.lowercased()) else {
            throw PluginUIError(message: pluginText("Import.InvalidFile", "Choose a .plugin or .py source file."))
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                var stagingDirectory: URL?
                do {
                    let manager = FileManager.default
                    let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let directory = support.appendingPathComponent("exteraless/imports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                    stagingDirectory = directory
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                    let target = directory.appendingPathComponent(url.lastPathComponent)
                    var coordinationError: NSError?
                    var copyError: Error?
                    var didCopy = false
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                        do {
                            guard try readableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                                throw PluginUIError(message: pluginText("Import.NotSource", "The selected item is not a regular source file."))
                            }
                            try manager.copyItem(at: readableURL, to: target)
                            didCopy = true
                        } catch {
                            copyError = error
                        }
                    }
                    if let error = coordinationError { throw error }
                    if let error = copyError { throw error }
                    guard didCopy else {
                        throw PluginUIError(message: pluginText("Import.CopyFailed", "The document provider did not supply the file."))
                    }
                    continuation.resume(returning: PluginImportCopy(url: target, directory: directory))
                } catch {
                    if let directory = stagingDirectory { try? FileManager.default.removeItem(at: directory) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
