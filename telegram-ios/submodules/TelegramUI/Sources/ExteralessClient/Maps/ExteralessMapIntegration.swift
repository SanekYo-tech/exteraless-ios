import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

@MainActor
public final class ExteralessMapIntegration {
    private var accountId: Int64?
    public init() {
        _ = MapPolicyRuntime.shared
        ExteralessSettingsUI.registerActions([
            .init(id: "maps.providerScope", title: "Map providers and privacy", section: "Maps", action: { context, parent in
                parent.push(ExteralessMapScopeController(context: context))
            })
        ])
    }
    public func update(context: AccountContext) {
        let id = context.account.id.int64
        if accountId != id { clearContext(); accountId = id }
    }
    public func clearContext() {
        if let accountId { MapResourceCache.shared.clear(namespace: "account:\(accountId)") }
        accountId = nil
    }
}

@MainActor
private final class ExteralessMapScopeController: ExteralessSettingsListController {
    override func render() {
        title = "Map providers"
        let policy = MapPolicy.current()
        let preview = policy.preview == .disabled ? "Disabled; a local labelled placeholder is drawn" : policy.preview == .yandex ? "Yandex; Apple Maps fallback is labelled if unavailable" : "Apple Maps (native Telegram iOS adaptation)"
        setSections([.init(rows: [
            .init(id: "maps.preview", title: "Cloud messages and articles", detail: preview),
            .init(id: "maps.secret", title: "Secret chats", detail: "Keep native preview behavior; the cloud-preview selector does not opt a secret chat into Yandex."),
            .init(id: "maps.picker", title: "Picker and location messages", detail: policy.useOpenStreetMap ? "Visible standard tiles: © OpenStreetMap contributors. Satellite / hybrid: Apple Maps." : "Apple Maps with the native standard, satellite and hybrid modes."),
            .init(id: "maps.coordinates", title: "Coordinates", detail: "Sent / received positions stay WGS84. The correction switch only changes Google Maps navigation in the source-defined China bounds. It never transforms MapKit, Yandex or OSM coordinates."),
            .init(id: "maps.storage", title: "Cache and credentials", detail: "Account/view-scoped bounded memory cache. Changing providers cancels old work. Provider keys use Keychain. No location permission is requested by this settings screen."),
            .init(id: "maps.offline", title: "Offline", detail: "Previously cached visible tiles / snapshots may display until expiry. No offline-region download is provided. An unavailable map is labelled, not replaced with another provider's name.")
        ])])
    }
}
