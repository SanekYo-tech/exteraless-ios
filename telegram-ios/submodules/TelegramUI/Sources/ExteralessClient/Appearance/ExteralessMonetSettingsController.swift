import AccountContext
import Display
import ExteralessCore
import Foundation
import SettingsUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

/// Native theme selection, not a preview-only Monet toggle. Native preferences
/// own both selected references and automatic night scheduling; the sole client
/// setting here is Original's Telemone/Classic selector.
final class ExteralessMonetSettingsController: ExteralessAppearanceListController {
    private var settings: PresentationThemeSettings?
    private var settingsDisposable: Disposable?
    private let applyDisposable = MetaDisposable()
    private var applying = false
    private var target: ExteralessMonetThemeSlot
    private var seedDraft: String?

    override init(context: AccountContext) {
        self.target = context.sharedContext.currentPresentationData.with { $0.autoNightModeTriggered ? .night : .day }
        super.init(context: context)
        self.title = "Monet Themes"
        self.allowsRefresh = false
        self.settingsDisposable = (context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.presentationThemeSettings])
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.settings = data.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) ?? .defaultSettings
            self.render()
        })
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.settingsDisposable?.dispose()
        self.applyDisposable.dispose()
    }

    override func viewWillDisappear(_ animated: Bool) {
        // Cancellation is admitted by the same operation token checked inside
        // the preference transaction, rather than just suppressing late UI.
        self.applyDisposable.set(nil)
        self.applying = false
        super.viewWillDisappear(animated)
    }

    private var seedText: String {
        if let seedDraft { return seedDraft }
        let current = exteralessMonetDescriptor(self.presentationData.theme)?.seedRGB ?? self.presentationData.theme.list.itemAccentColor.rgb
        return String(format: "%06X", current)
    }

    override func render() {
        let style = AppearanceMonetStyle(setting: ClientSettings.shared.integer(AppearanceMonetPolicy.settingKey))
        let editable = !self.applying && !self.isBusy
        let styleRows = AppearanceMonetStyle.allCases.map { value -> PluginListRow in
            var row = PluginListRow(id: "monet.style.\(value.rawValue)", title: value.title, detail: value == .telemone ? "Material 3 roles" : "Tonal palette tokens")
            row.accessory = value == style ? .checkmark : .none
            row.enabled = editable
            row.action = { [weak self] in self?.setStyle(value) }
            return row
        }
        let targetRows: [PluginListRow] = [ExteralessMonetThemeSlot.day, .night].map { slot in
            var row = PluginListRow(id: slot == .day ? "monet.target.day" : "monet.target.night", title: slot == .day ? "Day theme" : "Automatic Night theme")
            row.accessory = slot == self.target ? .checkmark : .none
            if let settings = self.settings {
                row.detail = themeDisplayName(strings: self.presentationData.strings, reference: slot.reference(in: settings))
            }
            row.enabled = editable
            row.action = { [weak self] in self?.target = slot; self?.render() }
            return row
        }
        var seedRow = PluginListRow(id: "monet.seed", title: "Accent seed · sRGB")
        seedRow.enabled = editable
        seedRow.input = PluginListInput(text: self.seedText, placeholder: "RRGGBB", multiline: false, maxLength: 7, updated: { [weak self] value in
            self?.seedDraft = value
        }, submitted: { [weak self] in self?.tableView.endEditing(true); self?.render() })
        var useCurrent = PluginListRow(id: "monet.currentSeed", title: "Use current native accent")
        useCurrent.enabled = editable
        useCurrent.action = { [weak self] in self?.seedDraft = nil; self?.render() }
        let active = exteralessMonetDescriptor(self.presentationData.theme)
        let selectedReference = self.settings.map { self.target.reference(in: $0) }
        let modes = AppearanceMonetMode.allCases.map { mode -> PluginListRow in
            var row = PluginListRow(id: "monet.mode.\(mode.rawValue)", title: mode.title)
            if selectedReference?.index == self.presentationData.theme.index, active?.mode == mode {
                row.accessory = .checkmark
            }
            row.enabled = editable && self.settings != nil
            row.action = { [weak self] in self?.select(mode) }
            return row
        }
        var native = PluginListRow(id: "monet.nativeThemes", title: "Themes, Colors and Wallpapers")
        native.accessory = .disclosure
        native.action = { [weak self] in
            guard let self else { return }
            self.push(themeSettingsController(context: self.context))
        }
        var night = PluginListRow(id: "monet.autoNight", title: "Automatic Night Schedule")
        night.accessory = .disclosure
        night.action = { [weak self] in
            guard let self else { return }
            self.push(themeAutoNightSettingsController(context: self.context))
        }
        let activeSlot: ExteralessMonetThemeSlot = self.presentationData.autoNightModeTriggered ? .night : .day
        let targetFooter = activeSlot == self.target ? "This is the currently active native appearance." : "This theme becomes visible when the native day/night schedule selects it."
        var sections = [
            PluginListSection(title: "Style", footer: "Applies only to selected Monet themes. Ordinary native themes keep their colors.", rows: styleRows),
            PluginListSection(title: "Apply to", footer: targetFooter, rows: targetRows),
            PluginListSection(title: "Palette", footer: "Enter a six-digit accent or use your current accent. iOS has no Android system wallpaper palette API. Native text contrast is retained.", rows: [seedRow, useCurrent]),
            PluginListSection(title: self.applying ? "Saving native theme…" : "Choose a Monet theme", footer: "Telemone uses Material 3 roles. Classic adapts pinned upstream tonal tokens. AMOLED uses black background planes with tonal bubbles and panels.", rows: modes),
            PluginListSection(rows: [native, night])
        ]
        sections.append(contentsOf: self.operationSections())
        self.setSections(sections)
    }

    private func setStyle(_ style: AppearanceMonetStyle) {
        guard !self.applying, !self.isBusy else { return }
        self.perform(title: "Saving Monet style…", operation: {
            try await ExteralessAppearancePersistence.set(.integer(Int64(style.rawValue)), for: AppearanceMonetPolicy.settingKey)
        }, completion: { [weak self] in self?.render() })
    }

    private func select(_ mode: AppearanceMonetMode) {
        guard !self.applying, !self.isBusy, let settings = self.settings else { return }
        guard let seed = AppearanceMonetPolicy.parseSeed(self.seedText) else {
            self.errorText = "Enter exactly six hexadecimal digits, for example 007AFF."
            self.render()
            return
        }
        self.tableView.endEditing(true)
        self.errorText = nil
        self.applying = true
        let signal = MainActor.assumeIsolated {
            ExteralessMonetThemeActions.shared.select(context: self.context, mode: mode, seedRGB: seed, slot: self.target, expected: self.target.reference(in: settings))
        }
        self.render()
        self.applyDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else { return }
            self.applying = false
            if case let .failure(error) = result { self.errorText = error.errorDescription }
            self.render()
        }))
    }
}
