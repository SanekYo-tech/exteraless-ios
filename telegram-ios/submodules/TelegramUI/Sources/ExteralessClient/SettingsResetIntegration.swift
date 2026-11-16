import AccountContext
import Display
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Created after the application's real ClientSettings configure/register gate.
/// Coordinator calls update/clearContext alongside the existing native domains.
@MainActor
public final class SettingsResetIntegration {
    public static let actionID = "general.settingsReset"
    static let contextDidChange = Notification.Name("Exteraless.SettingsResetContextDidChange")
    private let settings: ClientSettings
    private weak var context: AccountContext?
    private var authority: CoreSettingsResetAuthority?

    public init(settings: ClientSettings = .shared) { self.settings = settings }
    deinit { self.authority?.invalidate() }

    public func update(context: AccountContext) {
        if self.context === context, self.authority?.isValid == true { return }
        self.authority?.invalidate()
        self.context = context
        self.authority = CoreSettingsResetAuthority()
        ExteralessSettingsUI.registerActions([
            ExteralessSettingsAction(id: Self.actionID, title: "Reset settings…", section: "General", action: { [weak self] context, presenter in
                guard let self else { return }
                let opened = CoreSettingsResetActionGate.open(requested: context as AnyObject,
                    current: self.context.map { $0 as AnyObject }, authority: self.authority,
                    make: { authority in settingsResetController(context: context, settings: self.settings, authority: authority) },
                    present: { presenter.push($0) })
                if !opened {
                    let data = context.sharedContext.currentPresentationData.with { $0 }
                    let alert = UIAlertController(title: clientSettingsText("Reset.ContextChanged", "Account changed"),
                                                  message: CoreSettingsResetError.contextChanged.errorDescription, preferredStyle: .alert)
                    alert.overrideUserInterfaceStyle = data.theme.overallDarkAppearance ? .dark : .light
                    alert.view.tintColor = data.theme.list.itemAccentColor
                    alert.addAction(UIAlertAction(title: data.strings.Common_OK, style: .default))
                    presenter.present(alert, animated: true)
                }
            })
        ])
        NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
    }

    public func clearContext() {
        self.authority?.invalidate()
        self.authority = nil
        self.context = nil
        ExteralessSettingsUI.unregisterActions(ids: [Self.actionID])
        NotificationCenter.default.post(name: Self.contextDidChange, object: nil)
    }
}
