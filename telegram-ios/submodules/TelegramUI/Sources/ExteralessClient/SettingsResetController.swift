import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

/// Internal bounded worker-completion seams for the given-context native
/// fixture. The shipping factory leaves both nil and uses the real provider.
struct SettingsResetWorkHooks: Sendable {
    var afterPrepare: (@Sendable () -> Void)?
    var afterReset: (@Sendable () -> Void)?
}

/// Also the native fixture seam: pass a disposable configured store and a fresh
/// authority with the harness's AccountContext to exercise the real provider/UI.
@MainActor
public func settingsResetController(context: AccountContext, settings: ClientSettings = .shared,
                                    authority: CoreSettingsResetAuthority,
                                    scope: CoreSettingsResetScope = .exteraless) -> ViewController {
    return SettingsResetController(context: context, provider: CoreSettingsResetProvider(settings: settings),
                                   authority: authority, scope: scope)
}

@MainActor
class SettingsResetController: ExteralessSettingsListController {
    private let provider: CoreSettingsResetProvider
    private let workHooks: SettingsResetWorkHooks
    private let contextAuthority: CoreSettingsResetAuthority
    private var pageAuthority: CoreSettingsResetAuthority
    private var scope: CoreSettingsResetScope
    private var plan: CoreSettingsResetPlan?
    private var session: CoreSettingsResetSession?
    private var result: CoreSettingsResetReport?
    private var showUnavailable = false
    private var needsPreviewWhenIdle = false

    init(context: AccountContext, provider: CoreSettingsResetProvider,
         authority: CoreSettingsResetAuthority, scope: CoreSettingsResetScope, workHooks: SettingsResetWorkHooks = SettingsResetWorkHooks()) {
        self.provider = provider
        self.workHooks = workHooks
        self.contextAuthority = authority
        self.pageAuthority = authority.child()
        self.scope = scope
        super.init(context: context)
        NotificationCenter.default.addObserver(self, selector: #selector(self.contextChanged), name: SettingsResetIntegration.contextDidChange, object: nil)
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.pageAuthority.invalidate() }

    override func viewWillAppear(_ animated: Bool) {
        self.restorePageAfterAppearanceIfNeeded()
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard self.contextAuthority.isValid else { self.needsPreviewWhenIdle = false; self.render(); return }
        // Display's cancelled interactive pop calls DidAppear without WillAppear.
        // A normal Will+Did pair already has a fresh authority/preparation.
        if self.restorePageAfterAppearanceIfNeeded() { self.refresh() }
        else { self.resumePreviewIfNeeded() }
    }

    @discardableResult
    private func restorePageAfterAppearanceIfNeeded() -> Bool {
        guard !self.pageAuthority.isValid, self.contextAuthority.isValid else { return false }
        self.pageAuthority = self.contextAuthority.child()
        self.session = nil
        self.plan = nil
        self.result = nil
        self.needsPreviewWhenIdle = true
        return true
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.pageAuthority.invalidate()
        self.needsPreviewWhenIdle = false
        super.viewWillDisappear(animated)
    }

    override func refresh() {
        guard self.contextAuthority.isValid, self.pageAuthority.isValid else {
            self.tableView.refreshControl?.endRefreshing()
            self.render()
            return
        }
        if self.isBusy {
            self.tableView.refreshControl?.endRefreshing()
        } else {
            self.preparePreview()
        }
    }

    private func preparePreview() {
        guard !self.isBusy, self.contextAuthority.isValid, self.pageAuthority.isValid else { return }
        self.needsPreviewWhenIdle = false
        self.pageAuthority.invalidate()
        self.pageAuthority = self.contextAuthority.child()
        self.plan = nil
        self.session = nil
        self.result = nil
        let provider = self.provider
        let authority = self.pageAuthority
        let scope = self.scope
        let workHooks = self.workHooks
        self.perform({ () -> Result<CoreSettingsResetPlan, CoreSettingsResetError> in
            defer { workHooks.afterPrepare?() }
            do { return .success(try provider.prepare(scope: scope, authority: authority)) }
            catch { return .failure((error as? CoreSettingsResetError) ?? .nativeFailure) }
        }, completion: { [weak self] value in
            guard let self else { return }
            guard self.scope == scope, authority.isValid else { self.resumePreviewIfNeeded(); return }
            switch value {
            case let .success(plan):
                self.plan = plan
                self.errorText = plan.preview.storageError?.errorDescription
            case let .failure(error):
                self.errorText = error.errorDescription
            }
            if self.errorText != nil { self.revealFailure() }
        })
    }

    override func render() {
        self.title = clientSettingsText("Reset.PageTitle", "Reset settings")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: clientSettingsText("Reset.Refresh", "Refresh preview"), style: .plain,
                                                                 target: self, action: #selector(self.refreshPreviewPressed))
        self.navigationItem.rightBarButtonItem?.isEnabled = !self.isBusy && self.contextAuthority.isValid
        self.navigationItem.rightBarButtonItem?.accessibilityIdentifier = "reset.refresh"
        var sections = self.operationSections()
        var choices: [ExteralessSettingsRow] = []
        for scope in CoreSettingsResetScope.allCases {
            var row = ExteralessSettingsRow(id: "reset.scope." + scope.rawValue, title: self.scopeTitle(scope), detail: scope.originalMethod)
            row.accessory = scope == self.scope ? .checkmark : .none
            row.enabled = !self.isBusy && self.contextAuthority.isValid
            row.action = { [weak self] in
                guard let self, !self.isBusy, self.scope != scope else { return }
                self.scope = scope
                self.showUnavailable = false
                self.preparePreview()
            }
            choices.append(row)
        }
        sections.append(ExteralessSettingsSection(title: clientSettingsText("Reset.Scope", "Reset scope"), rows: choices))
        if let result = self.result {
            var progress = "\(result.confirmedKeys.count) confirmed · \(result.remainingKeys.count) pending"
            let awaiting = result.observedResetKeys.subtracting(result.confirmedKeys).count
            if awaiting != 0 { progress += "\n\(awaiting) already reset, awaiting confirmation" }
            var row = ExteralessSettingsRow(id: "reset.result", title: result.isComplete
                                           ? clientSettingsText("Reset.Complete", "Selected native settings reset")
                                           : clientSettingsText("Reset.Partial", "Reset needs attention"),
                                           detail: progress)
            row.style = result.isComplete ? .accent : .destructive
            sections.append(ExteralessSettingsSection(rows: [row]))
        }
        if let plan = self.plan {
            let preview = plan.preview
            let groups = CoreSettingsResetGroup.allCases.filter { group in preview.entries.contains { $0.sources.contains { $0.group == group } } }
            let description = groups.map(\.title).joined(separator: ", ")
            sections.append(ExteralessSettingsSection(footer: self.retainedDescription, rows: [
                ExteralessSettingsRow(id: "reset.summary", title: "\(preview.publicKeys.count) public settings · \(preview.credentialKeys.count) secure entries", detail: description)
            ]))
            if !preview.unavailable.isEmpty {
                var disclosure = ExteralessSettingsRow(id: "reset.unavailable", title: "\(preview.unavailable.count) Original fields unavailable here",
                                                       detail: clientSettingsText("Reset.UnavailableDetail", "These fields have no usable registered counterpart in this store."))
                disclosure.accessory = .disclosure
                disclosure.action = { [weak self] in self?.showUnavailable.toggle(); self?.render() }
                sections.append(ExteralessSettingsSection(rows: [disclosure]))
                if self.showUnavailable {
                    sections.append(ExteralessSettingsSection(rows: preview.unavailable.map {
                        ExteralessSettingsRow(id: "reset.unavailable." + $0.source.id, title: $0.source.symbol,
                                             detail: $0.source.preferenceNamespace + "." + $0.source.preferenceKey + "\n" + $0.reason)
                    }))
                }
            }
            var reset = ExteralessSettingsRow(id: "reset.apply", title: self.session == nil
                                             ? clientSettingsText("Reset.ApplyScope", "Reset this scope…")
                                             : clientSettingsText("Reset.Retry", "Retry remaining steps"))
            reset.style = .destructive
            reset.enabled = !self.isBusy && self.pageAuthority.isValid && !preview.entries.isEmpty && self.result?.isComplete != true
            if self.result?.requiresNewPreview == true { reset.enabled = false }
            reset.action = { [weak self] in
                guard let self else { return }
                if let session = self.session { self.run(session) }
                else { self.confirm(plan) }
            }
            sections.append(ExteralessSettingsSection(rows: [reset]))
            var nativeRows: [ExteralessSettingsRow] = []
            for entry in preview.entries {
                let state: String
                if self.result?.confirmedKeys.contains(entry.key) == true {
                    state = self.result?.observedResetKeys.contains(entry.key) == true
                        ? clientSettingsText("Reset.Confirmed", "Reset confirmed")
                        : clientSettingsText("Reset.ChangedLater", "Changed after the reset step")
                } else if self.result?.observedResetKeys.contains(entry.key) == true {
                    state = clientSettingsText("Reset.AwaitingConfirmation", "Override removed; confirmation pending")
                } else if self.result != nil {
                    state = clientSettingsText("Reset.Pending", "Pending reset")
                } else if entry.definition.isSecret {
                    state = clientSettingsText("Reset.SecureEntry", "Explicit native credential reset")
                } else {
                    state = entry.hasOverride ? clientSettingsText("Reset.HasOverride", "Saved override") : clientSettingsText("Reset.Default", "Currently uses default")
                }
                let title = clientSettingsText("Setting." + entry.key + ".Title", entry.definition.title)
                nativeRows.append(ExteralessSettingsRow(id: "reset.native." + entry.key, title: title, detail: state + "\n" + entry.key))
            }
            sections.append(ExteralessSettingsSection(title: clientSettingsText("Reset.NativeEntries", "Native entries in this scope"), rows: nativeRows))
        }
        if !self.contextAuthority.isValid {
            sections.append(ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "reset.context", title: CoreSettingsResetError.contextChanged.errorDescription ?? "Account changed")]))
        }
        self.setSections(sections)
    }

    private var retainedDescription: String {
        if self.scope == .allOriginal {
            return clientSettingsText("Reset.AllRetained", "Resets the listed native preferences, including cloud sync, saved API mode/ID/hash and translation/transcription credentials. Existing account identities, pending recovery drafts, account data, installed plugins/packs, Assistant state and native-only preferences are retained.")
        }
        return clientSettingsText("Reset.SelectedRetained", "Only the listed source-matched native preferences lose their overrides. Account data, authorization/API pins, installed plugins and unrelated settings are retained. Missing Original fields are listed below.")
    }

    private func scopeTitle(_ scope: CoreSettingsResetScope) -> String {
        return clientSettingsText("Reset.Scope." + scope.rawValue, scope.title)
    }

    private func confirm(_ plan: CoreSettingsResetPlan) {
        guard !self.isBusy, self.pageAuthority.isValid, self.plan?.id == plan.id else { return }
        let authority = self.pageAuthority
        let alert = UIAlertController(title: clientSettingsText("Reset.ConfirmTitle", "Reset selected settings?"),
                                      message: self.scopeTitle(plan.preview.scope) + "\n\(plan.preview.publicKeys.count) public settings · \(plan.preview.credentialKeys.count) secure entries",
                                      preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        alert.view.tintColor = self.presentationData.theme.list.itemAccentColor
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: clientSettingsText("Reset.Action", "Reset"), style: .destructive, handler: { [weak self] _ in
            self?.applyConfirmedPlan(plan.id, authorityID: authority.id)
        }))
        self.present(alert, animated: true)
    }

    /// The actual positive-confirmation continuation, also used by the native
    /// lifecycle fixture to hold an already completed reset's reply in flight.
    func applyConfirmedPlan(_ planID: UUID, authorityID: UUID) {
        guard !self.isBusy else { return }
        guard let plan = self.plan, plan.id == planID, self.scope == plan.preview.scope,
              self.pageAuthority.id == authorityID, self.pageAuthority.isValid else {
            self.errorText = CoreSettingsResetError.contextChanged.errorDescription
            self.render()
            return
        }
        do {
            let session = try self.provider.begin(plan, authority: self.pageAuthority)
            self.session = session
            self.run(session)
        } catch {
            self.errorText = (error as? CoreSettingsResetError)?.errorDescription ?? clientSettingsErrorText(error)
            self.render()
        }
    }

    private func run(_ session: CoreSettingsResetSession) {
        guard !self.isBusy else { return }
        let authority = self.pageAuthority
        let workHooks = self.workHooks
        self.perform({
            let report = session.run()
            workHooks.afterReset?()
            return report
        }, completion: { [weak self] report in
            guard let self else { return }
            guard authority.isValid, self.scope == report.scope else { self.resumePreviewIfNeeded(); return }
            self.result = report
            self.errorText = report.error?.errorDescription
            if report.requiresNewPreview {
                self.errorText = [self.errorText, clientSettingsText("Reset.NewPreviewRequired", "Refresh the preview before continuing.")].compactMap { $0 }.joined(separator: "\n")
            }
            if self.errorText != nil { self.revealFailure() }
        })
    }

    private func resumePreviewIfNeeded() {
        // Base.perform clears isBusy before completion. A result that arrives
        // during the gesture waits for DidAppear; an actual pop never resumes it.
        if self.needsPreviewWhenIdle, self.isScreenVisible, !self.isBusy,
           self.contextAuthority.isValid, self.pageAuthority.isValid { self.preparePreview() }
    }

    var navigationStateForTesting: (authorityID: UUID, authorityIsValid: Bool, planID: UUID?, sessionPlanID: UUID?, pendingPreview: Bool) {
        return (self.pageAuthority.id, self.pageAuthority.isValid, self.plan?.id, self.session?.plan.id, self.needsPreviewWhenIdle)
    }

    private func revealFailure() {
        self.tableView.setContentOffset(CGPoint(x: 0.0, y: -self.tableView.contentInset.top), animated: false)
        if self.isScreenVisible { UIAccessibility.post(notification: .announcement, argument: self.errorText) }
    }

    @objc private func contextChanged() {
        guard !self.contextAuthority.isValid else { return }
        self.pageAuthority.invalidate()
        self.needsPreviewWhenIdle = false
        self.errorText = CoreSettingsResetError.contextChanged.errorDescription
        self.render()
        self.revealFailure()
    }

    @objc private func refreshPreviewPressed() { self.preparePreview() }
}
