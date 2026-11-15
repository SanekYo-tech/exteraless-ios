import AccountContext
import AppBundle
import Display
import ExteralessCore
import Foundation
import TelegramPresentationData
import UIKit

/// UIApplication accepts CFBundleAlternateIcons keys, not asset filenames. This
/// also follows build-time icon substitutions and the iPad-specific icon table.
public func exteralessAvailableAppIcons() -> [PresentationAppIcon] {
    guard UIApplication.shared.supportsAlternateIcons else { return [] }
    return AppearanceAppIconPolicy.catalog(info: getAppBundle().infoDictionary ?? [:], isPad: UIDevice.current.userInterfaceIdiom == .pad).map {
        PresentationAppIcon(name: $0.name, imageName: $0.imageName, isDefault: $0.isDefault)
    }
}

/// The system persists the selected launcher icon. No second JSON preference can
/// report a successful change before UIApplication has actually accepted it.
final class ExteralessAppIconsController: ExteralessAppearanceListController {
    private var applying = false
    private let logoView = ExteralessAppIconLogoView(frame: CGRect(x: 0, y: 0, width: 320, height: 88))

    override init(context: AccountContext) {
        super.init(context: context)
        self.allowsRefresh = false
        self.title = "App Icon"
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        self.tableView.tableHeaderView = self.logoView
        self.logoView.toggleShape = { [weak self] in
            guard let self, !self.isBusy, !self.applying else { return }
            let value = !ClientSettings.shared.bool("appearance.useSystemIconShape")
            self.perform(title: "Saving logo shape…", operation: {
                try await ExteralessAppearancePersistence.set(.bool(value), for: "appearance.useSystemIconShape")
            }, completion: { [weak self] in self?.render() })
        }
    }

    override func render() {
        let icons = exteralessAvailableAppIcons()
        let current = self.context.sharedContext.applicationBindings.getAlternateIconName()
        let logo = AppearanceAppIconPolicy.catalog(info: getAppBundle().infoDictionary ?? [:], isPad: UIDevice.current.userInterfaceIdiom == .pad).first { $0.isDefault ? current == nil : current == $0.name }
        self.logoView.update(image: logo.flatMap { UIImage(named: $0.imageName, in: getAppBundle(), compatibleWith: nil) })
        var rows: [PluginListRow] = []
        for icon in icons {
            var row = PluginListRow(id: icon.name, title: icon.isDefault ? self.presentationData.strings.Appearance_AppIconDefault : icon.name)
            row.accessory = (icon.isDefault ? current == nil : current == icon.name) ? .checkmark : .none
            row.enabled = !self.applying && !self.isBusy
            row.action = { [weak self] in self?.select(icon) }
            rows.append(row)
        }
        if icons.isEmpty {
            rows.append(PluginListRow(id: "unavailable", title: "Alternate icons are unavailable", detail: "This app build or device does not support alternate launcher icons."))
        }
        var sections = [PluginListSection(footer: "Only icons declared in this iOS app bundle can be used. Android adaptive XML and icon packs cannot replace the iOS launcher icon.", rows: rows)]
        if let errorText = self.errorText {
            var row = PluginListRow(id: "error", title: "Appearance change failed", detail: errorText)
            row.style = .error
            sections.append(PluginListSection(rows: [row]))
        }
        self.setSections(sections)
    }

    private func select(_ icon: PresentationAppIcon) {
        guard !self.applying, !self.isBusy else { return }
        let requested: String? = icon.isDefault ? nil : icon.name
        guard self.context.sharedContext.applicationBindings.getAlternateIconName() != requested else { return }
        self.applying = true
        self.errorText = nil
        self.render()
        self.context.sharedContext.applicationBindings.requestSetAlternateIconName(requested) { [weak self] succeeded in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applying = false
                if !succeeded || self.context.sharedContext.applicationBindings.getAlternateIconName() != requested {
                    self.errorText = "iOS did not accept the icon change. The checkmark shows the icon that is actually active."
                }
                self.render()
            }
        }
    }
}
