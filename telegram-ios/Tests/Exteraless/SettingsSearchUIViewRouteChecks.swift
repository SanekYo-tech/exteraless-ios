import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramUI
import UIKit

/// Executable given-context UIKit checks, compiled into the existing bounded
/// ClientUIHarness by the handoff packet. No synthetic AccountContext, replacement
/// settings renderer, XCTest skip or model-only "view passed" flag lives here.
@MainActor
final class SettingsSearchUIViewRouteChecks {
    struct Failure: Error { let message: String }
    private final class Lifetime {
        var active = true
        var registration = UUID()
        var actionCalls = 0
    }

    private let context: AccountContext
    private let settings: ClientSettings
    private let navigation: NavigationController
    private let lifetime: Lifetime
    let session: ExteralessSettingsSearchSession

    init(context: AccountContext, settings: ClientSettings, navigation: NavigationController) {
        self.context = context
        self.settings = settings
        self.navigation = navigation
        let lifetime = Lifetime()
        self.lifetime = lifetime
        self.session = ExteralessSettingsSearchSession(context: context, settings: settings, actions: {
            [ExteralessSettingsAction(id: "harness.search.nativePage", title: "Fixture native settings page", section: "Acceptance fixture", action: { given, parent in
                // Actual shipping renderer. This fixture does not impersonate a
                // Cloud/API provider or claim that its network services executed.
                guard let controller = exteralessSettingsController(context: given) else { return }
                lifetime.actionCalls += 1
                parent.push(controller)
            })]
        }, registration: { _ in lifetime.registration }, isCurrent: { lifetime.active })
    }

    func root() throws -> ViewController {
        guard let result = exteralessSettingsController(context: context) else {
            throw Failure(message: "current native settings factory refused the given context")
        }
        return result
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private func views(_ root: UIView) -> [UIView] {
        var result: [UIView] = []
        func visit(_ view: UIView, depth: Int) {
            guard depth < 32, result.count < 2048 else { return }
            result.append(view)
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return result
    }

    private func table(_ controller: ViewController) throws -> UITableView {
        guard let table = views(controller.view).compactMap({ $0 as? UITableView }).first, table.window != nil else {
            throw Failure(message: "the actual controller has no mounted native table")
        }
        return table
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 650_000_000)
        navigation.view.window?.layoutIfNeeded()
    }

    private func until(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<20 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try require(predicate(), message)
    }

    private func cell(_ id: String, in table: UITableView) throws -> UITableViewCell {
        for _ in 0..<5 {
            table.layoutIfNeeded()
            if let cell = table.visibleCells.first(where: { views($0).contains { $0.accessibilityIdentifier == id } }) { return cell }
            let end = max(-table.contentInset.top, table.contentSize.height - table.bounds.height + table.contentInset.bottom)
            let offset = min(end, table.contentOffset.y + table.bounds.height * 0.55)
            if offset <= table.contentOffset.y { break }
            table.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
        throw Failure(message: "actual mounted row missing: " + id)
    }

    private func select(_ cell: UITableViewCell, in table: UITableView) throws {
        guard let path = table.indexPath(for: cell), cell.window != nil else { throw Failure(message: "selection needs a mounted cell") }
        table.selectRow(at: path, animated: false, scrollPosition: .none)
        table.delegate?.tableView?(table, didSelectRowAt: path)
    }

    private func send(_ button: UIBarButtonItem) throws {
        guard let target = button.target, let action = button.action else { throw Failure(message: "retained native button lost its target/action") }
        try require(UIApplication.shared.sendAction(action, to: target, from: button, for: nil), "retained native action was not delivered")
    }

    private func replacing(_ definition: ClientSettingDefinition, title: String? = nil, section: String? = nil) -> ClientSettingDefinition {
        .init(key: definition.key, title: title ?? definition.title, section: section ?? definition.section,
            defaultValue: definition.defaultValue, options: definition.options, minimum: definition.minimum,
            maximum: definition.maximum, step: definition.step, isSecret: definition.isSecret,
            explanation: definition.explanation, androidSymbols: definition.androidSymbols, valueShape: definition.valueShape)
    }

    /// Existing selector/editor probes call these checks after the real table
    /// actions. Those actions now use the same typed session/factory as links.
    func assertSelector(_ key: String) throws {
        guard let current = navigation.topViewController as? ViewController else { throw Failure(message: "missing selector") }
        let table = try table(current)
        try require(table.visibleCells.contains { cell in views(cell).contains { $0.accessibilityIdentifier?.hasPrefix("option:" + key + ":") == true } }, "typed selector did not render its actual option rows")
    }

    func assertEditor(_ key: String) throws {
        guard let current = navigation.topViewController as? ViewController else { throw Failure(message: "missing editor") }
        try require(views(current.view).contains { ($0 is UITextField || $0 is UITextView) && $0.accessibilityIdentifier == "input:" + key && $0.window != nil }, "typed editor did not render its actual input")
    }

    /// Two added probes only. The existing process deadline still bounds the
    /// complete scenario; this segment contains six fixed 650ms settles.
    func exerciseSearch(probe: (String, [String: Any]) throws -> Void) async throws {
        guard let root = navigation.topViewController as? ViewController else { throw Failure(message: "missing Root") }
        let depth = navigation.viewControllers.count
        let before = settings.readSnapshot()
        guard let button = root.navigationItem.rightBarButtonItems?.first(where: { $0.accessibilityIdentifier == "settings.search.open" }),
              button.isEnabled, let target = button.target, let selector = button.action else { throw Failure(message: "Root's actual Search action is unavailable") }
        try require(root.view.window != nil && UIApplication.shared.sendAction(selector, to: target, from: button, for: nil), "Search target/action was not delivered")
        try await settle()
        guard let search = navigation.topViewController as? ViewController, search !== root,
              let field = views(search.view).compactMap({ $0 as? UITextField }).first(where: { $0.accessibilityIdentifier == "settings.search.query" }) else {
            throw Failure(message: "shipping search controller/input was not mounted")
        }
        // Scripted UIKit editingChanged, not a model-only query helper or HID claim.
        field.text = "harness.enabled"
        field.sendActions(for: .editingChanged)
        search.view.layoutIfNeeded()
        let results = try table(search)
        guard let cell = results.visibleCells.first(where: { $0.accessibilityIdentifier?.hasSuffix("/setting:harness.enabled") == true }),
              let path = results.indexPath(for: cell), cell.window != nil else { throw Failure(message: "actual matching result cell missing") }
        let rect = cell.convert(cell.bounds, to: cell.window)
        try require(rect.height > 0 && rect.width > 0, "result cell has no actual geometry")
        try probe("settings-search-results", ["query": field.text ?? "", "id": cell.accessibilityIdentifier ?? "",
            "frame": [rect.minX, rect.minY, rect.width, rect.height], "factory": "ExteralessSettingsSearchSession.makeSearchController"])
        results.selectRow(at: path, animated: false, scrollPosition: .none)
        results.delegate?.tableView?(results, didSelectRowAt: path)
        try await settle()
        guard let selected = navigation.topViewController as? ViewController, selected !== search else { throw Failure(message: "result did not navigate") }
        let selectedTable = try table(selected)
        guard let selectedCell = selectedTable.visibleCells.first(where: { views($0).contains { $0.accessibilityIdentifier == "setting:harness.enabled" } }),
              let control = views(selectedCell).compactMap({ $0 as? UISwitch }).first else { throw Failure(message: "result did not reveal the real bool row") }
        try require(selectedCell.isHighlighted, "selected row was not highlighted after native layout")
        try require(before.values == settings.readSnapshot().values && before.storedKeys == settings.readSnapshot().storedKeys, "navigation mutated settings")
        let selectedRect = selectedCell.convert(selectedCell.bounds, to: selectedCell.window)
        try probe("settings-search-row", ["id": control.accessibilityIdentifier ?? "", "isOn": control.isOn,
            "frame": [selectedRect.minX, selectedRect.minY, selectedRect.width, selectedRect.height], "navigationOnly": true])
        try require(navigation.displayNode.accessibilityPerformEscape(), "selected page Back failed")
        try await settle()
        try require(navigation.displayNode.accessibilityPerformEscape(), "search Back failed")
        try await settle()
        try require(navigation.topViewController === root && navigation.viewControllers.count == depth, "search left an extra native page")

        // A supplied native action opens the shipping renderer, not an empty test
        // UIViewController. The link request itself contains no settings value.
        try require(session.open(request: .canonical(.action("harness.search.nativePage")), context: context, from: root), "typed action route failed")
        try await settle()
        guard let actionPage = navigation.topViewController as? ViewController else { throw Failure(message: "action page missing") }
        _ = try table(actionPage)
        try require(lifetime.actionCalls == 1 && before.values == settings.readSnapshot().values, "action route did not open exactly once without value mutation")
        try require(navigation.displayNode.accessibilityPerformEscape(), "action page Back failed")
        try await settle()
        try require(navigation.topViewController === root && navigation.viewControllers.count == depth, "action route leaked a page")
    }

    /// Actual-store/native-session regressions for the review witnesses. Runs in
    /// the existing core scenario, with six additional 650ms transitions and three
    /// at-most-500ms checks. It creates no account and uses no external services.
    func exerciseClosureChecks(from home: ViewController) async throws -> [String: Any] {
        let originalDepth = navigation.viewControllers.count
        let before = settings.readSnapshot()
        guard let root = ExteralessSettingsEntry.makeController(context: context) else {
            throw Failure(message: "installed shipping default Root factory refused the live fixture scope")
        }
        navigation.pushViewController(root)
        try await settle()
        let rootTable = try table(root)
        guard let searchButton = root.navigationItem.rightBarButtonItems?.first(where: { $0.accessibilityIdentifier == "settings.search.open" }) else {
            throw Failure(message: "default Root did not install its real Search action")
        }
        let unrelated = try session.resolve(.canonical(.setting("harness.enabled"))).ticket
        var stale: [ClientSettingsSearchTicket] = []
        for (key, hidden) in [("harness.text", false), ("harness.mode", true)] {
            guard let a = before.definitions.first(where: { $0.key == key }) else { throw Failure(message: "ABA fixture schema missing") }
            let ticket = try session.resolve(.canonical(.setting(key))).ticket
            let b = replacing(a, title: hidden ? nil : a.title + " B", section: hidden ? "AI state" : nil)
            try settings.register([b])
            try settings.register([a])
            // Same MainActor turn: neither native observer can have refreshed at B.
            try require(!session.accepts(ticket), "coalesced actual-store schema ABA revived a ticket before observer delivery")
            try require(session.accepts(unrelated), "schema ABA invalidated an unrelated definition")
            stale.append(ticket)
        }
        let stable = try session.resolve(.canonical(.setting("harness.number"))).ticket
        guard let numberValue = before.values["harness.number"] else { throw Failure(message: "numeric fixture value missing") }
        try settings.set(.integer(6), for: "harness.number")
        try require(session.accepts(stable) && session.accepts(unrelated), "value-only publication changed navigation authority")
        if before.storedKeys.contains("harness.number") { try settings.set(numberValue, for: "harness.number") }
        else { try settings.reset("harness.number") }

        // The real default Root's old row opens the private numeric editor. Its
        // schema stayed unchanged during the earlier value-only publications.
        let numberCell = try cell("setting:harness.number", in: rootTable)
        let retainedActions = views(numberCell).flatMap { $0.accessibilityCustomActions ?? [] }
        try require(!retainedActions.isEmpty, "default Root's native row actions missing")
        try select(numberCell, in: rootTable)
        try await settle()
        guard let editor = navigation.topViewController as? ViewController, editor !== root,
              let field = views(editor.view).compactMap({ $0 as? UITextField }).first(where: { $0.accessibilityIdentifier == "input:harness.number" }),
              let save = editor.navigationItem.rightBarButtonItem, save.isEnabled,
              let a = before.definitions.first(where: { $0.key == "harness.number" }) else {
            throw Failure(message: "default Root's private editor was not mounted")
        }
        field.text = "6"
        field.sendActions(for: .editingChanged)
        let editorTicket = try session.resolve(.canonical(.setting(a.key))).ticket
        try settings.register([replacing(a, title: a.title + " B")])
        try settings.register([a])
        try send(save) // real retained Save, before queued render/refresh drains
        try require(!session.accepts(editorTicket), "private editor retained ABA authority")
        try require(before.values == settings.readSnapshot().values && before.storedKeys == settings.readSnapshot().storedKeys, "stale private editor saved its draft")
        try await until("stale editor did not render its changed-route state") {
            views(editor.view).contains { $0.accessibilityIdentifier == "settings.route.changed" }
        }
        try require(stale.allSatisfy { !session.accepts($0) } && !session.accepts(editorTicket), "queued observer refresh revived schema tickets")
        try require(editor.navigationItem.rightBarButtonItem == nil && editor.presentedViewController == nil, "stale editor kept Save or constructed an alert")
        try require(navigation.displayNode.accessibilityPerformEscape(), "stale editor Back failed")
        try await settle()

        let copied = ClientSettingsLink.url(for: .setting("harness.text"))!
        let unlocked = ValuePromise<Bool>(false, ignoreRepeated: true)
        let cancellations = Atomic<Int>(value: 0)
        var oldParentLookups = 0
        guard let pending = ExteralessSettingsSearchEntry.prepare(url: copied, context: context),
              let notStarted = ExteralessSettingsSearchEntry.prepare(url: copied, context: context) else {
            throw Failure(message: "live session did not prepare the copied URL")
        }
        pending.start(whenUnlocked: unlocked.get() |> afterDisposed { _ = cancellations.modify { $0 + 1 } }, from: { [context] in
            oldParentLookups += 1
            let navigationController: NavigationController? = nil
            return (navigationController ?? context.sharedContext.mainWindow?.viewController as? NavigationController)?.topViewController as? ViewController
        })
        let ticket = try session.resolve(.canonical(.action("harness.search.nativePage"))).ticket
        let depth = navigation.viewControllers.count, calls = lifetime.actionCalls
        lifetime.active = false
        session.retire()
        try require(cancellations.with { $0 } == 1, "retirement did not synchronously cancel the pending unlock subscription")
        try require(session.makeSearchController() == nil, "retired scope created a search controller")
        try require(exteralessSettingsController(context: context) == nil, "real default factory constructed retired Root")
        try require(ExteralessSettingsEntry.makeController(context: context) == nil, "installed default entry constructed retired Root")
        try require(exteralessSettingsController(context: context, settings: settings) == nil, "store overload implicitly accepted a missing live scope")
        try require(exteralessSettingsController(context: context, settings: settings, searchSession: session) == nil, "explicit retired scope constructed Root")
        try require(!session.open(ticket: ticket, context: context, from: root) && !session.open(request: .canonical(.setting("harness.text")), context: context, from: root), "retired route navigated")
        try send(searchButton)
        for action in retainedActions {
            guard let handler = action.actionHandler else { throw Failure(message: "native accessibility action has no retained handler") }
            try require(handler(action), "native accessibility action was not delivered")
        }
        session.show(error: .invalidLink, context: context, from: root)
        try require(depth == navigation.viewControllers.count && calls == lifetime.actionCalls && root.presentedViewController == nil, "retired Root constructed a controller, action or alert")

        // Three publication lifetimes deliberately reuse the GIVEN context object;
        // object identity alone cannot authorize the original pending operation.
        let replacement = ExteralessSettingsSearchSession(context: context, settings: settings, actions: { [] }, registration: { _ in UUID() }, isCurrent: { true })
        ExteralessSettingsSearchEntry.install(replacement)
        let current = ExteralessSettingsSearchSession(context: context, settings: settings, actions: { [] }, registration: { _ in UUID() }, isCurrent: { true })
        ExteralessSettingsSearchEntry.install(current)
        defer { ExteralessSettingsSearchEntry.install(nil) }
        try require(!replacement.isCurrent, "provider replacement did not retire its previous lifetime")
        notStarted.start(whenUnlocked: .single(true), from: { oldParentLookups += 1; return root })
        unlocked.set(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(oldParentLookups == 0 && depth == navigation.viewControllers.count && root.presentedViewController == nil, "pending URL rebound after same-object publication ABA")

        guard let fresh = ExteralessSettingsSearchEntry.prepare(url: copied, context: context) else { throw Failure(message: "new explicit copied-URL operation was refused") }
        fresh.start(whenUnlocked: .single(true), from: { [context] in
            let navigationController: NavigationController? = nil
            return (navigationController ?? context.sharedContext.mainWindow?.viewController as? NavigationController)?.topViewController as? ViewController
        })
        try await settle()
        guard let currentEditor = navigation.topViewController as? ViewController, currentEditor !== root else { throw Failure(message: "fresh copied URL did not create the current editor") }
        try assertEditor("harness.text")
        try require(navigation.viewControllers.count == depth + 1, "fresh copied URL did not open exactly once")

        // Consumption is not navigation success. Unavailable selections keep the
        // production false result and show the actual native local error.
        try require(!current.open(request: .canonical(.unavailable("Owned unavailable destination")), context: context, from: currentEditor), "unavailable selection falsely reported navigation success")
        try await until("unavailable route alert did not settle") { currentEditor.presentedViewController is UIAlertController && currentEditor.presentedViewController?.isBeingPresented == false }
        guard let unavailable = currentEditor.presentedViewController as? UIAlertController else { throw Failure(message: "unavailable selection did not show its native error") }
        try require(unavailable.message == "Owned unavailable destination" && navigation.viewControllers.count == depth + 1, "unavailable selection changed destination")
        await withCheckedContinuation { continuation in unavailable.dismiss(animated: false) { continuation.resume() } }

        let invalid = URL(string: "tg://settings/exteraless/setting/clientAPI.customAppHash?value=OWNED_CANARY")!
        try require(ExteralessSettingsSearchEntry.recognizes(invalid), "canary escaped the local settings namespace")
        guard let denial = ExteralessSettingsSearchEntry.prepare(url: invalid, context: context) else { throw Failure(message: "recognized invalid URL lost local denial") }
        let denialGate = ValuePromise<Bool>(false, ignoreRepeated: true)
        denial.start(whenUnlocked: denialGate.get(), from: { currentEditor })
        try require(currentEditor.presentedViewController == nil, "invalid route bypassed the unlock gate")
        denialGate.set(true)
        try await until("invalid URL denial did not settle") { currentEditor.presentedViewController is UIAlertController && currentEditor.presentedViewController?.isBeingPresented == false }
        guard let denialAlert = currentEditor.presentedViewController as? UIAlertController else { throw Failure(message: "invalid URL did not produce its local typed error") }
        try require(denialAlert.message == ClientSettingsRouteError.invalidLink.message && denialAlert.message?.contains("OWNED_CANARY") == false, "invalid URL query reached its error UI")
        await withCheckedContinuation { continuation in denialAlert.dismiss(animated: false) { continuation.resume() } }

        guard let currentSave = currentEditor.navigationItem.rightBarButtonItem, currentSave.isEnabled else { throw Failure(message: "current private editor has no active Save before retirement") }
        ExteralessSettingsSearchEntry.install(nil)
        try send(currentSave)
        try require(current.makeSearchController() == nil && exteralessSettingsController(context: context) == nil, "final retirement manufactured a settings controller")
        try require(before.values == settings.readSnapshot().values && before.storedKeys == settings.readSnapshot().storedKeys, "retired current editor or links mutated values")
        try require(currentEditor.presentedViewController == nil, "retired private editor constructed an alert")
        try require(navigation.displayNode.accessibilityPerformEscape(), "current editor Back failed")
        try await settle()
        try require(navigation.displayNode.accessibilityPerformEscape(), "retired default Root Back failed")
        try await settle()
        try require(navigation.topViewController === home && navigation.viewControllers.count == originalDepth, "closure checks leaked a native page")
        return ["defaultRootAndPrivateEditor": true, "publicationABAImmediateAndDrained": true,
            "unrelatedValueTicketsStable": true, "pendingUnlockCancelled": cancellations.with { $0 },
            "retiredParentLookups": oldParentLookups, "freshCopiedURL": true,
            "unavailableSelectionReturnedFalse": true, "invalidURLLocalGatedDenial": true,
            "appDelegateIngress": "source-order check; full application launch/notification execution remains pending"]
    }

}
