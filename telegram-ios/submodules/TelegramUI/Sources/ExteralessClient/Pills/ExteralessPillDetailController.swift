import AccountContext
import ExteralessCore
import Foundation
import SettingsUI
import UIKit

final class ExteralessPillDetailController: ExteralessPillTableController {
    private let id: Int
    private var descriptor: PillDescriptor?
    private var subscription: ExteralessPillSubscription?
    private var model: PillModel?
    init(context: AccountContext, id: Int) {
        self.id = id
        super.init(context: context, title: "Status reading")
        self.settingsChanged = { [weak self] in self?.restart() }
        self.accountInvalidated = { [weak self] in self?.subscription?.cancel(); self?.subscription = nil }
        self.refreshAction = { [weak self] in self?.subscription?.refresh(force: true) }
        self.render()
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillDisappear(_ animated: Bool) {
        self.subscription?.cancel(); self.subscription = nil
        super.viewWillDisappear(animated)
    }
    private func restart() {
        self.subscription?.cancel(); self.subscription = nil; self.model = nil
        self.descriptor = (try? self.pillRuntime.descriptors())?.first { $0.id == self.id }
        if let descriptor = self.descriptor {
            self.title = descriptor.title
            self.subscription = self.pillRuntime.subscribe(descriptor) { [weak self] model in
                guard let self, self.accountIsValid else { return }
                guard self.pillRuntime.lease.isValid else { self.invalidateAccount(); return }
                self.model = model; self.render()
                if model.phase != .loading { self.tableView.refreshControl?.endRefreshing() }
            }
        }
        self.render()
    }
    private func render() {
        guard self.accountIsValid else { return }
        let updated = self.model?.updatedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "No timestamped reading"
        self.sections = [.init(rows: [
            .init(id: "pills.detail.value", title: self.model?.displayText ?? (self.descriptor == nil ? "Pill unavailable" : "Loading…"), detail: self.model?.detail, enabled: false),
            .init(id: "pills.detail.source", title: "Source", detail: self.model?.source ?? "Waiting for selected provider", enabled: false),
            .init(id: "pills.detail.time", title: "Updated", detail: updated, enabled: false),
            .init(id: "pills.detail.phase", title: "State", detail: self.model?.phase.rawValue ?? "idle", enabled: false),
            .init(id: "pills.detail.refresh", title: "Refresh", enabled: self.descriptor != nil, action: { [weak self] in self?.subscription?.refresh(force: true) })
        ])]
        if let descriptor = self.descriptor, let pair = descriptor.pair {
            let store = self.pillRuntime.store
            var rows: [ExteralessChatRow] = [
                .init(id: "pills.rate.base", title: "Base", detail: pair.base == "XAU" ? "Gold · one troy ounce" : pair.base, enabled: self.id >= 100, action: { [weak self] in guard let self else { return }; self.pushChild(ExteralessPillCurrencyController(context: self.context, id: self.id, pair: pair, editsBase: true)) }),
                .init(id: "pills.rate.target", title: "Target", detail: pair.target, action: { [weak self] in guard let self else { return }; self.pushChild(ExteralessPillCurrencyController(context: self.context, id: self.id, pair: pair, editsBase: false)) })
            ]
            if self.id >= 100 {
                let id = self.id
                rows.append(.init(id: "pills.rate.remove", title: "Remove this rate pair", action: { [weak self] in
                    self?.writePillSettings({ try store.removeRate(id: id) }, completion: { [weak self] in self?.navigationController?.popViewController(animated: true) })
                }))
            }
            self.sections.append(.init(title: "Currency pair", rows: rows))
            self.sections.append(.init(title: "Provider usage", rows: self.usageRows(domains: pair.base == "XAU" ? ["gold", "rates"] : ["rates"])))
        } else if self.id == 1 {
            self.sections.append(.init(rows: [.init(id: "pills.weather.configure", title: "Weather settings", action: { [weak self] in guard let self else { return }; self.pushChild(ExteralessPillWeatherSettingsController(context: self.context)) })]))
            if ClientSettings.shared.string("pills.weatherProvider", default: "telegram") == "openMeteo" {
                self.sections.append(.init(title: "Provider usage", rows: self.usageRows(domains: ["weather"])))
            } else {
                self.sections.append(.init(rows: [.init(id: "pills.weather.usage", title: "Telegram bot requests", detail: "This account generation: \(self.pillRuntime.botRequests) started, \(self.pillRuntime.botResponses) valid replies. Quota is not exposed by Telegram.", enabled: false)]))
            }
        } else if self.id == 5 {
            self.sections.append(.init(rows: [.init(id: "pills.cache.open", title: "Manage storage", action: { [weak self] in guard let self else { return }; self.pushChild(self.context.sharedContext.makeStorageManagementController(context: self.context)) })]))
        } else if self.id == 6 {
            self.sections.append(.init(rows: [.init(id: "pills.proxy.open", title: "Proxy settings", action: { [weak self] in guard let self else { return }; self.pushChild(proxySettingsController(context: self.context)) })]))
        } else if self.id == 7 {
            self.sections.append(.init(rows: [
                .init(id: "pills.ghost.toggle", title: "Toggle ghost mode", action: { [weak self] in self?.pillRuntime.toggleGhost { [weak self] error in if let error { self?.displayError(error) } } }),
                .init(id: "pills.ghost.settings", title: "Ghost-mode fields and exceptions", action: { [weak self] in guard let self else { return }; self.pushChild(ExteralessPrivacyOverviewController(context: self.context)) })
            ]))
        }
        self.reloadRows()
    }
    private func usageRows(domains: [String]) -> [ExteralessChatRow] {
        domains.map { domain in
            let value = self.pillRuntime.http.statistics(domain: domain)
            var detail = "This account generation: \(value.requests) HTTP requests, \(value.responses) responses, \(value.failures) HTTP/transport failures. "
            detail += value.remaining.map { "Source-reported remaining: \($0). " } ?? "Source quota not exposed. "
            if let status = value.lastHTTPStatus { detail += "Last HTTP status: \(status). " }
            if let retry = value.retryAt { detail += (value.retryIsSourceReported ? "Source Retry-After: " : "Local retry backoff until: ") + DateFormatter.localizedString(from: retry, dateStyle: .none, timeStyle: .medium) }
            return .init(id: "pills.usage.\(domain)", title: domain == "rates" ? "Coinbase" : domain == "gold" ? "gold-api.com" : "Open-Meteo", detail: detail, enabled: false)
        }
    }
}

private final class ExteralessPillCurrencyController: ExteralessPillTableController {
    init(context: AccountContext, id: Int, pair: PillRatePair, editsBase: Bool) {
        super.init(context: context, title: editsBase ? "Base currency" : "Target currency")
        let choices = editsBase ? PillCurrencies.bases : PillCurrencies.targets.filter { $0 != pair.base }
        let store = self.pillRuntime.store
        self.sections = [.init(footer: "AUTO uses the active account's phone-country; USD is used when that currency is unavailable. GRAM denotes TON, matching the original. Gold is quoted per troy ounce.", rows: choices.map { code in
            .init(id: "pills.currency.\(code)", title: code, checked: code == (editsBase ? pair.base : pair.target), action: { [weak self] in
                let updated = PillRatePair(base: editsBase ? code : pair.base, target: editsBase ? pair.target : code)
                self?.writePillSettings({ try store.setPair(id: id, pair: updated, expectedPair: pair) }, completion: { [weak self] in self?.navigationController?.popViewController(animated: true) })
            })
        })]
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
