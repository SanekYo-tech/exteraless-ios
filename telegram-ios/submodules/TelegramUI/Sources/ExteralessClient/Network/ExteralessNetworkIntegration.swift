import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramCore
import UIKit

@MainActor
public final class ExteralessNetworkIntegration {
    private final class ScreenReference {
        weak var screen: ExteralessNetworkStatusController?
        init(_ screen: ExteralessNetworkStatusController) { self.screen = screen }
    }
    private weak var context: AccountContext?
    private var screens: [ScreenReference] = []
    public init() {
        // configure(rootPath:) constructs this before initializedNetwork, including
        // the login network. DNS is app-scoped and survives active-account changes.
        ExteralessNetworkResolverRuntime.shared.start()
        ExteralessSettingsUI.registerActions([
            .init(id: "network.resolverStatus", title: "Resolver status and cache", section: "Network", action: { [weak self] context, parent in
                guard let self, self.context === context else { return }
                let screen = ExteralessNetworkStatusController(context: context)
                self.screens.removeAll { $0.screen == nil }; self.screens.append(ScreenReference(screen))
                parent.push(screen)
            })
        ])
    }
    public func update(context: AccountContext) {
        if self.context !== context { clearContext(); self.context = context }
    }
    public func clearContext() {
        for reference in screens { reference.screen?.invalidateAccount() }
        screens.removeAll(); context = nil
    }
}

@MainActor
private final class ExteralessNetworkStatusController: ExteralessSettingsListController {
    private var observation: NSObjectProtocol?
    private var accountValid = true
    override init(context: AccountContext) {
        super.init(context: context)
        title = "App DNS resolver"
        observation = NotificationCenter.default.addObserver(forName: ExteralessNetworkResolverRuntime.stateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }

    func invalidateAccount() { accountValid = false; render() }

    override func render() {
        guard accountValid else { setSections([.init(rows: [.init(id: "network.accountChanged", title: "Account changed")])]); return }
        let runtime = ExteralessNetworkResolverRuntime.shared
        let state = runtime.resolver.state()
        let label: String
        switch state.mode {
        case .telegram: label = "Telegram · native iOS DNS"
        case .system: label = "System DNS"
        case .nagramX: label = "NagramX DoH"
        case .customDoH: label = state.emptyCustomUsesDefaults ? "Custom list empty · NagramX DoH" : "Custom DoH"
        }
        var rows = [
            ExteralessSettingsRow(id: "network.active", title: "Applied policy", detail: state.blockedConfiguration == nil ? label : "No valid resolver configuration · DNS lookups blocked"),
            ExteralessSettingsRow(id: "network.epoch", title: "Configuration epoch", detail: String(state.epoch)),
            ExteralessSettingsRow(id: "network.cache", title: "Cached / in-flight questions", detail: "\(state.cachedQuestions) / \(state.inFlightQuestions)"),
            ExteralessSettingsRow(id: "network.fallbacks", title: "Fallback attempts this session", detail: String(state.nativeFallbacks))
        ]
        if let error = runtime.configurationError() {
            let disposition = state.blockedConfiguration == nil ? "The previous valid policy remains active." : "No public/native DNS fallback was selected."
            rows.insert(.init(id: "network.rejected", title: "Custom configuration rejected", detail: "\(error.rawValue). \(disposition) Correct the HTTPS endpoint list."), at: 0)
        }
        var clear = ExteralessSettingsRow(id: "network.clear", title: "Clear resolver cache")
        clear.action = { runtime.clearCachedState() }
        rows.append(clear)
        setSections([.init(footer: "Scope: MTProto TCP, proxy endpoint DNS and signed backup TXT. Native iOS DNS bootstraps DoH endpoint hostnames and local names. Safari, WebKit, unrelated URLSessions and device-wide DNS keep their own policy. Certificate trust is never bypassed. Pull to refresh counts.", rows: rows)])
    }
}
