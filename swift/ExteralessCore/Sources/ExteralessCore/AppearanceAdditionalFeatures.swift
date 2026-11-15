import Foundation

/// Remaining appearance-owner controls. Each entry has a native consumer; state
/// aliases and Android helper bookkeeping are documented in the owner receipt.
public enum AppearanceAdditionalFeatures {
    /// Append with the coordinator's settingsItems hook; not exposed before its
    /// native section filter/route is wired into the shared PeerInfo builder.
    public static let settingsSectionDefinitions: [ClientSettingDefinition] = [
        .init(key: "appearance.hideHelpSection", title: "Hide Help section", section: "Appearance · Native Settings",
              defaultValue: .bool(true), androidSymbols: ["NaConfig.hideHelpSection", "SettingsActivity.fillItems"]),
        .init(key: "appearance.hidePremiumSection", title: "Hide Premium / payments section", section: "Appearance · Native Settings",
              defaultValue: .bool(false), explanation: "Hides Premium, Stars, TON earnings, Business and gifting rows as one native section. The separate Wallet route is retained.", androidSymbols: ["NaConfig.hidePremiumSection", "SettingsActivity.fillItems"]),
        .init(key: "appearance.showStickersRowToplevel", title: "Stickers in top-level Settings", section: "Appearance · Native Settings",
              defaultValue: .bool(true), androidSymbols: ["NaConfig.showStickersRowToplevel", "SettingsActivity.fillItems"])
    ]

    public static let definitions: [ClientSettingDefinition] = [
        .init(key: "appearance.forceFontWeightFallback", title: "Use bold weight fallback", section: "Appearance · Text",
              defaultValue: .bool(false), explanation: "Uses bold for native medium/semibold system text, including italic variants. Font size and family are retained.", androidSymbols: ["NekoConfig.forceFontWeightFallback", "TypefaceHelper.createTypeface"]),
        .init(key: "appearance.hideAllTab", title: "Hide All Chats tab in folders", section: "Appearance · Folders",
              defaultValue: .bool(false), explanation: "Hides the All Chats chip while a custom folder is selected. Native All Chats navigation, transitions and reordering keep a visible recovery tab.", androidSymbols: ["NekoConfig.hideAllTab", "FilterTabsView.toggleAllTabs"]),
        .init(key: "appearance.switchStyle", title: "Modern switch style", section: "Appearance · Controls",
              defaultValue: .integer(2), options: [.init(value: .integer(0), title: "Native"), .init(value: .integer(2), title: "Filled capsule"), .init(value: .integer(3), title: "Material 3")],
              explanation: "Native component-based switches use the chosen geometry. Slot 2 is the original filled Extera capsule; slot 3 is the outlined Material switch.", androidSymbols: ["NaConfig.switchStyle", "Switch.drawExteraSwitch", "Switch.drawMaterial3Switch"]),
        .init(key: "appearance.sliderStyle", title: "Slider style", section: "Appearance · Controls",
              defaultValue: .integer(2), options: [.init(value: .integer(0), title: "Native"), .init(value: .integer(2), title: "Material-style")],
              explanation: "Simple native component sliders use an 8pt rail and 3×24pt grip. Specialized two-sided, constrained or custom-sized sliders retain their explicit geometry.", androidSymbols: ["NaConfig.sliderStyle", "SeekBarView.canUseMaterialSlider"]),
        .init(key: "appearance.centerActionBarTitleType", title: "Centered header scope", section: "Appearance · Header",
              defaultValue: .integer(1), options: [.init(value: .integer(0), title: "Off"), .init(value: .integer(1), title: "All appearance headers"), .init(value: .integer(2), title: "Appearance settings only"), .init(value: .integer(3), title: "Chat list only")],
              explanation: "Selects the scope when centered headers are enabled: chat list and Exteraless appearance/menu pages. Native iOS controllers keep their own title layout.", androidSymbols: ["NaConfig.centerActionBarTitleType", "NekoGeneralSettingsActivity.isCentered"]),
        .init(key: "appearance.useSystemIconShape", title: "Rounded in-app logo", section: "Appearance · Icons",
              defaultValue: .bool(false), explanation: "Uses a continuous rounded-square on the App Icon preview instead of a circle. This is an iOS-style approximation; SpringBoard does not expose its exact launcher mask.", androidSymbols: ["IconPacksConfig.useSystemIconShape", "IconShapeHelper.getFinalIconShapePath"]),
        .init(key: "appearance.backAnimationStyle", title: "Navigation motion", section: "Appearance · Navigation",
              defaultValue: .integer(1), options: [.init(value: .integer(0), title: "Classic · brisk"), .init(value: .integer(1), title: "Native spring"), .init(value: .integer(2), title: "Predictive · damped"), .init(value: .integer(3), title: "Paired slide")],
              explanation: "Native tap/release curves and paired-screen slide geometry. Gesture tracking, keyboard/bar timelines and profile expansions keep their native contracts. Android's predictive shrinking-card renderer is adapted to a damped iOS release.", androidSymbols: ["NaConfig.backAnimationStyle", "UtilsConfig.applyMotionDefaults", "ActionBarLayout.BACK_ANIMATION_SLIDE"]),
        .init(key: "appearance.springAnimationCrossfade", title: "Header-content crossfade", section: "Appearance · Navigation",
              defaultValue: .bool(true), explanation: "Crossfades native navigation-capsule content in Spring mode. Off switches content at the midpoint of the same sampled timeline.", androidSymbols: ["NaConfig.springAnimationCrossfade", "ActionBarLayout.USE_ACTIONBAR_CROSSFADE"])
    ]
}
