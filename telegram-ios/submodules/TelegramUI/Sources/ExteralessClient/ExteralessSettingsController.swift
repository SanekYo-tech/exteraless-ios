import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

/// A native domain-owned screen/action. The current account and presenting
/// controller are provided at invocation, rather than captured at registration.
public struct ExteralessSettingsAction {
    public let id: String
    public let title: String
    public let section: String
    public let action: @MainActor (AccountContext, ViewController) -> Void

    public init(id: String, title: String, section: String, action: @escaping @MainActor (AccountContext, ViewController) -> Void) {
        self.id = id
        self.title = title
        self.section = section
        self.action = action
    }
}

@MainActor
public enum ExteralessSettingsUI {
    private static var actionsById: [String: ExteralessSettingsAction] = [:]
    private static var actionOrder: [String] = []
    static let actionsDidChange = Notification.Name("ExteralessSettingsActionsDidChange")

    /// Merges by unique id; repeated account updates replace closures/titles
    /// without duplicating rows. Registration does not invoke domain actions.
    public static func registerActions(_ actions: [ExteralessSettingsAction]) {
        for action in actions {
            if self.actionsById[action.id] == nil { self.actionOrder.append(action.id) }
            self.actionsById[action.id] = action
            ExteralessSettingsSearchRegistry.registered(action.id)
        }
        if !actions.isEmpty { NotificationCenter.default.post(name: self.actionsDidChange, object: nil) }
    }

    public static func unregisterActions(ids: Set<String>) {
        for id in ids { self.actionsById.removeValue(forKey: id) }
        self.actionOrder.removeAll { ids.contains($0) }
        ExteralessSettingsSearchRegistry.removed(ids)
        if !ids.isEmpty { NotificationCenter.default.post(name: self.actionsDidChange, object: nil) }
    }

    static var registeredActions: [ExteralessSettingsAction] {
        return self.actionOrder.compactMap { self.actionsById[$0] }
    }
}

/// Composition registers domains separately; opening this screen invents no
/// settings, starts no plugin runtime and assumes no singleton AccountContext.
@MainActor
public func exteralessSettingsController(context: AccountContext) -> ViewController? {
    return ExteralessSettingsSearchEntry.makeRoot(context: context)
}

/// An explicitly requested store must belong to the installed live scope. An
/// independently owned fixture uses the explicit searchSession overload below.
@MainActor
public func exteralessSettingsController(context: AccountContext, settings: ClientSettings) -> ViewController? {
    return ExteralessSettingsSearchEntry.makeRoot(context: context, settings: settings)
}

@MainActor
public func exteralessSettingsController(context: AccountContext, settings: ClientSettings, searchSession: ExteralessSettingsSearchSession) -> ViewController? {
    guard searchSession.matches(context: context, settings: settings),
          let ticket = try? searchSession.resolve(.canonical(.root)).ticket else { return nil }
    return ExteralessClientSettingsController(context: context, settings: settings, mode: .root,
        searchSession: searchSession, routeTicket: ticket)
}

@MainActor
func exteralessSettingsDestinationController(context: AccountContext, settings: ClientSettings, route: ClientSettingsRoute,
                                            searchSession: ExteralessSettingsSearchSession, ticket: ClientSettingsSearchTicket) -> ViewController? {
    guard searchSession.matches(context: context, settings: settings), searchSession.accepts(ticket) else { return nil }
    let mode: ExteralessClientSettingsController.Mode
    let focus: String?
    switch route {
    case .root:
        mode = .root
        focus = nil
    case let .row(key), let .setting(key):
        let snapshot = settings.readSnapshot()
        guard let definition = snapshot.definitions.first(where: { $0.key == key }),
              ClientSettingsSearchIndex.isGenericVisible(definition) else { return nil }
        if case .row = route {
            mode = .root
            focus = "setting:" + key
        } else if snapshot.secretKeys.contains(key) {
            mode = .editor(key)
            focus = "input:" + key
        } else if !definition.options.isEmpty {
            mode = .selector(key)
            focus = nil
        } else if case .bool = definition.defaultValue {
            mode = .root
            focus = "setting:" + key
        } else {
            mode = .editor(key)
            focus = "input:" + key
        }
    default: return nil
    }
    guard searchSession.accepts(ticket) else { return nil }
    return ExteralessClientSettingsController(context: context, settings: settings, mode: mode,
        searchSession: searchSession, routeTicket: ticket, focusRowID: focus)
}

@MainActor
private final class ExteralessClientSettingsController: ExteralessSettingsListController {
    enum Mode {
        case root
        case selector(String)
        case editor(String)
    }

    private let settings: ClientSettings
    private let mode: Mode
    private var observation: ClientSettingsObservation?
    private var draft = ""
    private var draftWasEdited = false
    private var editingSecret = false
    private var exportButton: UIBarButtonItem?
    private var searchButton: UIBarButtonItem?
    private let searchSession: ExteralessSettingsSearchSession
    private let routeTicket: ClientSettingsSearchTicket
    private var routeFocus: ExteralessSettingsRowFocus?

    init?(context: AccountContext, settings: ClientSettings, mode: Mode, searchSession: ExteralessSettingsSearchSession,
          routeTicket: ClientSettingsSearchTicket, focusRowID: String? = nil) {
        guard searchSession.matches(context: context, settings: settings), searchSession.accepts(routeTicket) else { return nil }
        self.settings = settings
        self.mode = mode
        self.searchSession = searchSession
        self.routeTicket = routeTicket
        super.init(context: context)
        if let focusRowID {
            self.routeFocus = ExteralessSettingsRowFocus(rowID: focusRowID, valid: { [weak self] in self?.routeIsCurrent == true })
        }
        // Subscribe before the initial coherent read; callbacks only invalidate.
        self.observation = settings.observe { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
        if case let .editor(key) = mode {
            self.allowsRefresh = false
            let snapshot = settings.readSnapshot()
            self.editingSecret = snapshot.secretKeys.contains(key)
            if let definition = snapshot.definitions.first(where: { $0.key == key }), !self.editingSecret {
                self.draft = Self.editingText(snapshot.values[key] ?? definition.defaultValue)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.actionsChanged), name: ExteralessSettingsUI.actionsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.actionsChanged), name: ExteralessSettingsSearchSession.didChange, object: self.searchSession)
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { self.observation?.cancel() }

    private var routeIsCurrent: Bool {
        self.searchSession.matches(context: self.context, settings: self.settings) && self.searchSession.accepts(self.routeTicket)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.routeFocus?.apply(to: self)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.routeFocus?.apply(to: self)
    }

    override func refresh() {
        guard self.routeIsCurrent else { self.render(); return }
        if case .editor = self.mode {
            self.render()
            return
        }
        guard !self.isBusy else { return }
        let settings = self.settings
        self.perform({ try settings.reload() }, completion: { _ in })
    }

    override func render() {
        guard self.routeIsCurrent else {
            self.navigationItem.rightBarButtonItems = nil
            self.draft = ""
            self.draftWasEdited = false
            if self.isNodeLoaded { self.view.endEditing(true) }
            self.setSections([ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "settings.route.changed", title: clientSettingsText("Search.Changed", "Reopen this setting from the current search results."))])])
            return
        }
        let snapshot = self.settings.readSnapshot()
        switch self.mode {
        case .root:
            self.renderRoot(snapshot)
        case let .selector(key):
            self.renderSelector(key, snapshot: snapshot)
        case let .editor(key):
            self.renderEditor(key, snapshot: snapshot)
        }
        self.routeFocus?.apply(to: self)
    }

    private func renderRoot(_ snapshot: ClientSettingsSnapshot) {
        self.title = clientSettingsText("Title", "Exteraless Settings")
        let export: UIBarButtonItem
        if let current = self.exportButton {
            export = current
        } else {
            export = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(self.exportPressed))
            self.exportButton = export
        }
        export.accessibilityLabel = clientSettingsText("Export", "Export settings")
        export.isEnabled = !self.isBusy && snapshot.definitions.contains(where: { !$0.isSecret })
        let search: UIBarButtonItem
        if let current = self.searchButton { search = current }
        else {
            search = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(self.searchPressed))
            self.searchButton = search
        }
        search.accessibilityIdentifier = "settings.search.open"
        search.accessibilityLabel = clientSettingsText("Search.Open", "Search settings")
        search.isEnabled = !self.isBusy && self.searchSession.isCurrent
        self.navigationItem.rightBarButtonItems = [export, search]
        var sections = self.operationSections(storageError: snapshot.lastError)
        let tickets = self.searchSession.items(context: self.context).reduce(into: [String: ClientSettingsSearchTicket]()) { result, item in
            if item.isAvailable { result[item.ticket.identifier] = item.ticket }
        }
        let versions = self.settings.readSnapshot().definitionVersions
        var groups: [ExteralessSettingsSection] = []
        var sectionIndices: [String: Int] = [:]
        func append(_ row: ExteralessSettingsRow, section: String) {
            if let index = sectionIndices[section] {
                groups[index].rows.append(row)
            } else {
                sectionIndices[section] = groups.count
                groups.append(ExteralessSettingsSection(title: clientSettingsText("Section." + section, section), rows: [row]))
            }
        }
        for definition in snapshot.definitions where ClientSettingsSearchIndex.isGenericVisible(definition) {
            let ticket = versions[definition.key] == snapshot.definitionVersions[definition.key] ? tickets["setting:" + definition.key] : nil
            append(self.settingRow(definition, snapshot: snapshot, ticket: ticket), section: definition.section)
        }
        for action in self.searchSession.rootActions {
            let ticket = tickets["action:" + action.id]
            var row = ExteralessSettingsRow(id: "action:" + action.id, title: clientSettingsText("Action." + action.id, action.title))
            row.accessory = .disclosure
            row.enabled = !self.isBusy && ticket != nil
            row.longAction = { [weak self] in
                guard let self, let ticket, self.routeIsCurrent, self.searchSession.accepts(ticket) else { return }
                self.searchSession.presentRowMenu(request: .canonical(.action(action.id)), from: self, reset: nil)
            }
            row.action = { [weak self] in
                guard let self, let ticket, !self.isBusy, self.routeIsCurrent else { return }
                _ = self.searchSession.open(ticket: ticket, context: self.context, from: self)
            }
            append(row, section: action.section)
        }
        if groups.isEmpty {
            sections.append(ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "empty", title: clientSettingsText("Empty", "No settings available"))]))
        } else {
            if !snapshot.definitions.isEmpty {
                groups[groups.count - 1].footer = clientSettingsText("Reset.Hint", "Touch and hold a setting to reset it to its default.")
            }
            sections.append(contentsOf: groups)
        }
        self.setSections(sections)
    }

    private func settingRow(_ definition: ClientSettingDefinition, snapshot: ClientSettingsSnapshot, ticket: ClientSettingsSearchTicket?) -> ExteralessSettingsRow {
        let key = definition.key
        let value = snapshot.values[key] ?? definition.defaultValue
        let explanation = self.explanation(definition)
        var row = ExteralessSettingsRow(id: "setting:" + key, title: self.settingTitle(definition), detail: explanation)
        row.enabled = !self.isBusy && ticket != nil
        row.reset = { [weak self] in
            guard let ticket else { return }
            self?.confirmReset(key, ticket: ticket)
        }
        row.longAction = { [weak self] in
            guard let self, let ticket, self.routeIsCurrent, self.searchSession.accepts(ticket) else { return }
            self.searchSession.presentRowMenu(request: .canonical(.row(key)), from: self,
                reset: { [weak self] in self?.confirmReset(key, ticket: ticket) })
        }
        if snapshot.secretKeys.contains(key) {
            let status: String
            if !definition.isSecret {
                status = clientSettingsText("Secret.MigrationPending", "Secure storage migration needs to complete.")
                row.enabled = false
            } else if snapshot.values[key] == nil {
                status = snapshot.storedKeys.contains(key)
                    ? clientSettingsText("Secret.StoredUnavailable", "Stored value unavailable")
                    : clientSettingsText("Secret.Unavailable", "Secure storage unavailable")
            } else {
                status = snapshot.storedKeys.contains(key)
                    ? clientSettingsText("Secret.Stored", "Stored securely") : clientSettingsText("Secret.Empty", "Not set")
            }
            row.detail = [explanation, status].compactMap { $0 }.joined(separator: "\n")
            row.accessory = .disclosure
            row.action = { [weak self] in self?.open(ticket) }
        } else if !definition.options.isEmpty {
            let option = definition.options.enumerated().first { (try? definition.validatedValue($0.element.value)) == value }
            let label = option.map { clientSettingsText("Setting." + key + ".Option.\($0.offset)", $0.element.title) }
                ?? clientSettingsText("NoSelection", "No selection")
            row.detail = [explanation, label].compactMap { $0 }.joined(separator: "\n")
            row.accessory = .disclosure
            row.action = { [weak self] in self?.open(ticket) }
        } else {
            switch definition.defaultValue {
            case .bool:
                if case let .bool(enabled) = value {
                    row.toggle = (enabled, { [weak self] updated in self?.update(.bool(updated), key: key, ticket: ticket) })
                }
            case .integer, .number:
                row.slider = ExteralessSettingsSlider(definition: definition, value: value, commit: { [weak self] number in
                    // The core performs the final exact integer/step validation.
                    self?.update(.number(number), key: key, ticket: ticket)
                })
                if row.slider == nil { row.detail = [explanation, self.summary(value)].compactMap { $0 }.joined(separator: "\n") }
                row.accessory = .disclosure
                row.action = { [weak self] in self?.open(ticket) }
            case .string, .array, .object, .null:
                row.detail = [explanation, self.summary(value)].compactMap { $0 }.joined(separator: "\n")
                row.accessory = .disclosure
                row.action = { [weak self] in self?.open(ticket) }
            }
        }
        return row
    }

    private func renderSelector(_ key: String, snapshot: ClientSettingsSnapshot) {
        self.navigationItem.rightBarButtonItem = nil
        var sections = self.operationSections(storageError: snapshot.lastError)
        guard let definition = snapshot.definitions.first(where: { $0.key == key }) else {
            self.setSections(sections + [self.missingSection()])
            return
        }
        self.title = self.settingTitle(definition)
        let selected = snapshot.values[key]
        let rows = definition.options.enumerated().map { index, option -> ExteralessSettingsRow in
            var row = ExteralessSettingsRow(id: "option:\(key):\(index)", title: clientSettingsText("Setting." + key + ".Option.\(index)", option.title))
            row.enabled = !self.isBusy
            if (try? definition.validatedValue(option.value)) == selected { row.accessory = .checkmark }
            row.action = { [weak self] in
                guard let self else { return }
                self.update(option.value, key: key, ticket: self.routeTicket, closeOnSuccess: true)
            }
            return row
        }
        sections.append(ExteralessSettingsSection(footer: self.explanation(definition), rows: rows))
        self.setSections(sections)
    }

    private func renderEditor(_ key: String, snapshot: ClientSettingsSnapshot) {
        var sections = self.operationSections(storageError: snapshot.lastError)
        guard let definition = snapshot.definitions.first(where: { $0.key == key }) else {
            self.navigationItem.rightBarButtonItem = nil
            self.setSections(sections + [self.missingSection()])
            return
        }
        self.title = self.settingTitle(definition)
        let secret = snapshot.secretKeys.contains(key)
        if secret && !self.editingSecret {
            self.draft = ""
            self.draftWasEdited = false
        }
        self.editingSecret = secret
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Save, style: .done, target: self, action: #selector(self.savePressed))
        self.updateSaveButton()
        let kind: ExteralessSettingsInput.Kind
        if secret { kind = .secret }
        else {
            switch definition.defaultValue {
            case .string: kind = .text
            case .integer: kind = .integer
            case .number: kind = .decimal
            default: kind = .json
            }
        }
        var row = ExteralessSettingsRow(id: "input:" + key, title: self.settingTitle(definition), detail: self.explanation(definition))
        row.enabled = !self.isBusy
        let placeholder = secret
            ? clientSettingsText("Secret.Replacement", "Enter a replacement value") : clientSettingsText("EnterValue", "Enter a value")
        row.input = ExteralessSettingsInput(text: self.draft, placeholder: placeholder, kind: kind, updated: { [weak self] text in
            guard let self, self.routeIsCurrent else { return }
            self.draft = text
            self.draftWasEdited = true
            self.updateSaveButton()
        }, submitted: { [weak self] in self?.savePressed() })
        var hints: [String] = []
        if secret { hints.append(clientSettingsText("Secret.Hint", "The stored value is not displayed. Save replaces it; reset removes it.")) }
        if kind == .json || (secret && definition.defaultValue != .string("")) {
            hints.append(clientSettingsText("JSON.Hint", "Enter a JSON value of the same type."))
        }
        if let minimum = definition.minimum { hints.append(clientSettingsText("Minimum", "Minimum") + ": \(minimum)") }
        if let maximum = definition.maximum { hints.append(clientSettingsText("Maximum", "Maximum") + ": \(maximum)") }
        if let step = definition.step { hints.append(clientSettingsText("Step", "Step") + ": \(step)") }
        sections.append(ExteralessSettingsSection(footer: hints.isEmpty ? nil : hints.joined(separator: "\n"), rows: [row]))
        var reset = ExteralessSettingsRow(id: "reset:" + key, title: clientSettingsText("Reset", "Reset to default"))
        reset.style = .destructive
        reset.enabled = !self.isBusy
        reset.action = { [weak self] in
            guard let self else { return }
            self.confirmReset(key, ticket: self.routeTicket)
        }
        sections.append(ExteralessSettingsSection(rows: [reset]))
        self.setSections(sections)
    }

    private func missingSection() -> ExteralessSettingsSection {
        return ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "missing", title: clientSettingsText("Missing", "This setting is no longer available."))])
    }

    private func settingTitle(_ definition: ClientSettingDefinition) -> String {
        return clientSettingsText("Setting." + definition.key + ".Title", definition.title)
    }

    private func explanation(_ definition: ClientSettingDefinition) -> String? {
        return definition.explanation.map { clientSettingsText("Setting." + definition.key + ".Explanation", $0) }
    }

    private func summary(_ value: ClientSettingValue) -> String {
        switch value {
        case .null: return clientSettingsText("Value.Null", "Not set")
        case let .bool(value): return value ? clientSettingsText("Value.On", "On") : clientSettingsText("Value.Off", "Off")
        case let .integer(value): return String(value)
        case let .number(value): return String(value)
        case let .string(value):
            if value.isEmpty { return clientSettingsText("Value.Empty", "Empty") }
            let prefix = value.prefix(200)
            return String(prefix) + (prefix.endIndex == value.endIndex ? "" : "…")
        case let .array(values): return clientSettingsText("Value.Items", "Items") + ": \(values.count)"
        case let .object(values): return clientSettingsText("Value.Fields", "Fields") + ": \(values.count)"
        }
    }

    private static func editingText(_ value: ClientSettingValue) -> String {
        if case let .string(value) = value { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func open(_ ticket: ClientSettingsSearchTicket?) {
        guard !self.isBusy, self.routeIsCurrent, let ticket else { return }
        _ = self.searchSession.open(ticket: ticket, context: self.context, from: self)
    }

    @objc private func searchPressed() {
        guard !self.isBusy, self.routeIsCurrent, let controller = self.searchSession.makeSearchController() else { return }
        self.push(controller)
    }

    private func update(_ value: ClientSettingValue, key: String, ticket: ClientSettingsSearchTicket?, closeOnSuccess: Bool = false) {
        guard !self.isBusy, self.routeIsCurrent, let ticket, self.searchSession.accepts(ticket) else { return }
        do {
            guard let definition = self.settings.definitions().first(where: { $0.key == key }) else { throw ClientSettingsError.unregisteredKey(key) }
            let validated = try definition.validatedValue(value)
            try NewNetworkFeatures.validate(validated, for: key)
            let settings = self.settings
            self.perform({ try settings.set(validated, for: key) }, completion: { [weak self] _ in
                guard let self, self.routeIsCurrent else { return }
                // Every page re-queries all registered values after mutation,
                // including dependent settings updated by domain observers.
                if closeOnSuccess, self.isScreenVisible { self.dismiss(animated: true) }
            })
        } catch { self.showError(error) }
    }

    private func confirmReset(_ key: String, ticket: ClientSettingsSearchTicket) {
        guard !self.isBusy, self.routeIsCurrent, self.searchSession.accepts(ticket),
              let definition = self.settings.definitions().first(where: { $0.key == key }) else { return }
        let alert = UIAlertController(title: clientSettingsText("Reset", "Reset to default"), message: self.settingTitle(definition), preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        alert.view.tintColor = self.presentationData.theme.list.itemAccentColor
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: clientSettingsText("Reset.Action", "Reset"), style: .destructive, handler: { [weak self] _ in
            guard let self, self.routeIsCurrent, self.searchSession.accepts(ticket) else { return }
            let settings = self.settings
            self.perform({ try settings.reset(key) }, completion: { [weak self] _ in
                guard let self, self.routeIsCurrent else { return }
                if case .editor = self.mode {
                    let current = self.settings.readSnapshot()
                    if let definition = current.definitions.first(where: { $0.key == key }) {
                        self.draft = definition.isSecret ? "" : Self.editingText(current.values[key] ?? definition.defaultValue)
                        self.draftWasEdited = false
                    }
                }
            })
        }))
        self.present(alert, animated: true)
    }

    private func updateSaveButton() {
        guard self.routeIsCurrent else {
            self.navigationItem.rightBarButtonItem?.isEnabled = false
            return
        }
        guard case let .editor(key) = self.mode,
              let definition = self.settings.definitions().first(where: { $0.key == key }) else { return }
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy && (!self.editingSecret || self.draftWasEdited)
            && (!self.editingSecret || definition.isSecret)
    }

    @objc private func savePressed() {
        guard !self.isBusy, self.routeIsCurrent, case let .editor(key) = self.mode else { return }
        let snapshot = self.settings.readSnapshot()
        guard let definition = snapshot.definitions.first(where: { $0.key == key }) else { return }
        let secret = snapshot.secretKeys.contains(key)
        if secret != self.editingSecret { self.render(); return }
        guard !secret || (definition.isSecret && self.draftWasEdited) else { return }
        do {
            let value: ClientSettingValue
            let trimmed = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            switch definition.defaultValue {
            case .string: value = .string(self.draft)
            case .integer:
                guard let integer = Int64(trimmed) else { throw ClientSettingsError.invalidValue(key: key, reason: .type) }
                value = .integer(integer)
            case .number:
                let separator = Locale.current.decimalSeparator ?? "."
                guard let number = Double(trimmed.replacingOccurrences(of: separator, with: ".")) else { throw ClientSettingsError.invalidValue(key: key, reason: .type) }
                value = .number(number)
            default:
                do { value = try JSONDecoder().decode(ClientSettingValue.self, from: Data(self.draft.utf8)) }
                catch { throw ClientSettingsError.invalidValue(key: key, reason: .type) }
            }
            _ = try definition.validatedValue(value)
            self.view.endEditing(true)
            self.update(value, key: key, ticket: self.routeTicket, closeOnSuccess: true)
        } catch { self.showError(error) }
    }

    @objc private func actionsChanged() { self.render() }

    @objc private func exportPressed() {
        guard !self.isBusy, self.routeIsCurrent else { return }
        let settings = self.settings
        self.perform({ try settings.exportJSON() }, completion: { [weak self] data in
            guard let self, self.routeIsCurrent, self.isScreenVisible, self.presentedViewController == nil else { return }
            let controller = UIActivityViewController(activityItems: [String(decoding: data, as: UTF8.self)], applicationActivities: nil)
            controller.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
            controller.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItem
            self.present(controller, animated: true)
        })
    }
}
