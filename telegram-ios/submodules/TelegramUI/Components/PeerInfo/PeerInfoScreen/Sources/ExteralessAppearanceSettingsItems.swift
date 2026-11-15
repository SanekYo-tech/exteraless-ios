import ExteralessCore
import TelegramPresentationData

/// Shared-builder seam supplied to the coordinator. Uses native section identity
/// and the already implemented .stickers action, never localized string matching.
func exteralessAppearanceSettingsItems(_ source: [(AnyHashable, [PeerInfoScreenItem])], data: PeerInfoScreenData, presentationData: PresentationData, interaction: PeerInfoInteraction) -> [(AnyHashable, [PeerInfoScreenItem])] {
    let settings = ClientSettings.shared
    let hideHelp = settings.bool("appearance.hideHelpSection", default: true)
    let hidePremium = settings.bool("appearance.hidePremiumSection")
    let showStickers = settings.bool("appearance.showStickersRowToplevel", default: true) && data.globalSettings != nil
    let stickersId = AnyHashable("appearance.stickers")
    return source.compactMap { section, originalRows in
        if hideHelp && section == AnyHashable(SettingsSection.support) { return nil }
        if hidePremium && section == AnyHashable(SettingsSection.payment) { return nil }
        var rows = originalRows.filter { $0.id != stickersId }
        if showStickers && section == AnyHashable(SettingsSection.advanced) {
            let index = rows.firstIndex { $0.id == AnyHashable(3) }.map { $0 + 1 } ?? rows.count
            rows.insert(PeerInfoScreenDisclosureItem(id: stickersId, text: presentationData.strings.StickerPacksSettings_Title, icon: PresentationResourcesSettings.stickers, action: {
                interaction.openSettings(.stickers)
            }), at: index)
        }
        return rows.isEmpty ? nil : (section, rows)
    }
}
