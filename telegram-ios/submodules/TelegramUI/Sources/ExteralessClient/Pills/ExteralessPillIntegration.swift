import AccountContext
import Display
import ExteralessCore
import Foundation

@MainActor public final class ExteralessPillIntegration {
    private var runtime: ExteralessPillRuntime?
    public init() {
        ExteralessPillEntry.setHeaderFactory { [weak self] context, open in
            guard let self, self.runtime?.context === context, self.runtime?.lease.isValid == true else { return nil }
            return ExteralessPillHeaderView(context: context, open: open)
        }
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: "pills.status", title: "Status Pills", section: "Chats · Status pills", action: { [weak self] context, parent in
                guard let self else { return }
                ExteralessPillSettingsActionGate.open(requested: context, current: self.runtime?.context, active: self.runtime?.lease.isValid == true,
                    make: { ExteralessPillSettingsController(context: context) },
                    present: { parent.push($0) })
            })
        ])
    }
    public func update(context: AccountContext) {
        if self.runtime?.context === context, self.runtime?.lease.isValid == true { return }
        self.clearContext()
        self.runtime = ExteralessPillRuntimes.get(context: context)
    }
    public func clearContext() { ExteralessPillRuntimes.clear(); self.runtime = nil }
}

func exteralessPillSettingsAffectView(_ keys: Set<String>) -> Bool {
    if keys.isEmpty { return true }
    let fields: Set<String> = ["activePillsRaw", "hiddenPillsRaw", "lastActivePillId", "infiniteScrolling", "rateInstancesRaw", "weatherUseCurrentLocation", "weatherLatitude", "weatherLongitude", "weatherAddress", "gramTargetCurrency", "btcTargetCurrency", "usdTargetCurrency", "goldTargetCurrency", "ethTargetCurrency", "eurTargetCurrency"]
    return keys.contains { $0.hasPrefix("pills.") || $0.hasPrefix("privacy.") || ($0.hasPrefix("chats.") && fields.contains(String($0.dropFirst(6)))) }
}
