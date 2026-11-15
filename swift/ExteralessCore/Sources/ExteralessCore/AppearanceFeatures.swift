import Foundation

/// Only settings with a native consumer belong here. Android-only controls and
/// compatibility-storage fields are documented in the appearance handoff instead.
public enum AppearanceFeatures {
    public static let resourcesChangedNotification = Notification.Name("Exteraless.Appearance.ResourcesChanged")

    public static let definitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(
            key: "appearance.hideStoriesFromHeader", title: "Hide chat-list stories", section: "Appearance · Chat List",
            defaultValue: .bool(true), explanation: "Hides the header story strip and its expansion space. Stories remain available from profiles.", androidSymbols: ["NaConfig.hideStoriesFromHeader", "DialogsActivity.updateStoriesVisibility"]
        ),
        ClientSettingDefinition(
            key: "appearance.hideDialogsSearchField", title: "Hide idle search field", section: "Appearance · Chat List",
            defaultValue: .bool(false), explanation: "The permanent Main Menu keeps a Search action. Active search retains its native field and cancellation controls.", androidSymbols: ["NaConfig.hideDialogsSearchField", "DialogsActivity.searchFieldVisible"]
        ),
        ClientSettingDefinition(
            key: "appearance.mediaPreview", title: "Chat-list media thumbnails", section: "Appearance · Chat List",
            defaultValue: .bool(true), explanation: "Disabling restores the text-only message preview without a thumbnail cutout.", androidSymbols: ["NekoConfig.mediaPreview", "DialogCell"]
        ),
        ClientSettingDefinition(
            key: "appearance.disableBotOpenButton", title: "Hide inline Open App button", section: "Appearance · Chat List",
            defaultValue: .bool(false), explanation: "Removes the bot mini-app shortcut from chat-list rows. Opening the bot chat keeps its normal native actions.", androidSymbols: ["NaConfig.disableBotOpenButton", "DialogCell.setAllowBotOpenButton"]
        ),
        ClientSettingDefinition(
            key: "appearance.senderMiniAvatars", title: "Sender mini avatars", section: "Appearance · Chat List",
            defaultValue: .bool(true), explanation: "Shows an 18pt avatar beside another sender’s name in chat-list previews. Drafts and your own messages keep their existing preview.",
            androidSymbols: ["AppearanceConfig.senderMiniAvatars", "DialogCell.addSenderAvatar"]
        ),
        ClientSettingDefinition(
            key: "appearance.centerActionBarTitle", title: "Center chat-list title", section: "Appearance · Header",
            defaultValue: .bool(false), explanation: "Aligns the chat-list title within the space left by the navigation buttons.",
            androidSymbols: ["NaConfig.centerActionBarTitle", "AppearanceConfig.setCenterTitle"]
        ),
        ClientSettingDefinition(
            key: "appearance.disableAvatarBlur", title: "Disable profile avatar blur", section: "Appearance · Avatars",
            defaultValue: .bool(false), explanation: "Removes the blur behind profile actions and the profile’s scroll-edge overlay. Avatar thumbnail loading is unaffected.",
            androidSymbols: ["NaConfig.disableAvatarBlur", "ProfileGalleryBlurView", "ProfileActivity.avatarsBlurView"]
        ),
        ClientSettingDefinition(
            key: "appearance.gooeyAvatarAnimation", title: "Elastic profile avatar", section: "Appearance · Avatars",
            defaultValue: .bool(true), explanation: "Allows the expanded profile photo to stretch when pulled. Disabling preserves normal expansion, scrolling and collapse.",
            androidSymbols: ["AppearanceConfig.gooeyAvatarAnimation"]
        ),
        ClientSettingDefinition(
            key: "appearance.newChatHeaderStyle", title: "Material-style chat header", section: "Appearance · Header",
            defaultValue: .bool(false), explanation: "Removes the title glass pill, enlarges the avatar within its native 44pt control and extends the top wallpaper fade. Disabling restores native metrics.",
            androidSymbols: ["AppearanceConfig.newChatHeaderStyle", "ChatHeaderUiHelper"]
        ),
        ClientSettingDefinition(
            key: "appearance.alwaysShowDownloadIcon", title: "Always show Downloads", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "Adds a persistent chat-list header button opening Telegram’s real Downloads search pane.",
            androidSymbols: ["NaConfig.alwaysShowDownloadIcon"]
        ),
        ClientSettingDefinition(
            key: "appearance.squareFab", title: "Rounded-square compose button", section: "Appearance · Navigation",
            defaultValue: .bool(true), explanation: "Uses the original 16/56 corner ratio for the native floating compose button; disabling makes it round.", androidSymbols: ["AppearanceConfig.squareFab", "AppearanceConfig.fabCornerRadius"]
        ),
        ClientSettingDefinition(
            key: "appearance.disableDialogsFloatingButton", title: "Use header compose button", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "Hides the floating button and restores the native header compose action.", androidSymbols: ["NaConfig.disableDialogsFloatingButton"]
        ),
        ClientSettingDefinition(
            key: "appearance.newLoadingStyle", title: "Material-style loading indicators", section: "Appearance · Controls",
            defaultValue: .bool(true), explanation: "Uses a growing arc and tonal track in native activity indicators. Reduce Motion shows a static progress shape; disabling restores native/custom stock indicators.",
            androidSymbols: ["AppearanceConfig.newLoadingStyle", "RadialProgressView", "LineProgressView"]
        ),
        ClientSettingDefinition(
            key: "appearance.glassOutlineStyle", title: "Glass outline", section: "Appearance · Glass",
            defaultValue: .integer(0), options: [ClientSettingOption(value: .integer(0), title: "Glare"), ClientSettingOption(value: .integer(1), title: "Solid"), ClientSettingOption(value: .integer(2), title: "Hidden")],
            explanation: "Glare uses native glass. Solid and Hidden use a native material backdrop with a uniform edge or no edge, including older iOS versions.", androidSymbols: ["AppearanceConfig.glassOutlineStyle", "GlassOutlineStyle"]
        ),
        ClientSettingDefinition(
            key: "appearance.glassMessageMenu", title: "Glass context menus", section: "Appearance · Glass",
            defaultValue: .bool(true), explanation: "Disabling gives Telegram’s custom context-menu panels an opaque theme background; actions, selection and dismissal remain native.", androidSymbols: ["AppearanceConfig.glassMessageMenu"]
        ),
        ClientSettingDefinition(
            key: "appearance.actionBarDecoration", title: "Header decoration", section: "Appearance · Decorations",
            defaultValue: .integer(0), options: [ClientSettingOption(value: .integer(0), title: "None"), ClientSettingOption(value: .integer(1), title: "Snow")],
            explanation: "Passive chat-list header snow. Respects Reduce Motion and Low Power Mode.", androidSymbols: ["NekoConfig.actionBarDecoration", "SnowflakesEffect"]
        ),
        ClientSettingDefinition(
            key: "appearance.chatDecoration", title: "Chat decoration", section: "Appearance · Decorations",
            defaultValue: .integer(0), options: [ClientSettingOption(value: .integer(0), title: "None"), ClientSettingOption(value: .integer(1), title: "Snow")],
            explanation: "Bounded snow over the wallpaper, below messages and controls. Respects Reduce Motion and Low Power Mode.", androidSymbols: ["NaConfig.chatDecoration", "SnowflakesEffect"]
        ),
        ClientSettingDefinition(
            key: "appearance.customThemes", title: "Per-chat themes and wallpapers",
            section: "Appearance · Themes", defaultValue: .bool(true),
            explanation: "Disabling uses the global appearance without deleting saved chat themes or wallpapers.",
            androidSymbols: ["AppearanceConfig.customThemes", "ChatActivity.setupChatTheme", "ChatThemeController.getDialogWallpaper"]
        ),
        ClientSettingDefinition(
            key: "appearance.avatarCorners", title: "Avatar corners", section: "Appearance · Avatars",
            defaultValue: .integer(28), minimum: 0, maximum: 28, step: 1,
            explanation: "0 is square; 28 is round. The default retains native iOS forum avatars.",
            androidSymbols: ["AppearanceConfig.avatarCorners", "AppearanceConfig.getAvatarCorners"]
        ),
        ClientSettingDefinition(
            key: "appearance.singleCornerRadius", title: "Same shape for forum avatars", section: "Appearance · Avatars",
            defaultValue: .bool(false), androidSymbols: ["AppearanceConfig.singleCornerRadius"]
        ),
        ClientSettingDefinition(
            key: "appearance.tabsTitleType", title: "Folder titles", section: "Appearance · Folders",
            defaultValue: .integer(0), options: [
                ClientSettingOption(value: .integer(2), title: "Names with icons"),
                ClientSettingOption(value: .integer(0), title: "Names only"),
                ClientSettingOption(value: .integer(1), title: "Icons only")
            ], explanation: "Uses a folder’s leading emoji, or the native folder symbol. VoiceOver keeps the full folder name.",
            androidSymbols: ["NekoConfig.tabsTitleType", "OpenExteraAppearanceActivity.TAB_TITLE_ORDER"]
        ),
        ClientSettingDefinition(
            key: "appearance.ignoreUnreadCount", title: "Folder unread counters", section: "Appearance · Folders",
            defaultValue: .integer(0), options: [
                ClientSettingOption(value: .integer(0), title: "All"),
                ClientSettingOption(value: .integer(1), title: "Unmuted"),
                ClientSettingOption(value: .integer(2), title: "Off")
            ], androidSymbols: ["NaConfig.ignoreUnreadCount"]
        ),
        ClientSettingDefinition(
            key: "appearance.disableNumberRounding", title: "Show full numbers", section: "General · Formatting",
            defaultValue: .bool(false), explanation: "Show 12345 instead of 12.3K.",
            androidSymbols: ["NekoConfig.disableNumberRounding", "LocaleController.formatShortNumber"]
        ),
        ClientSettingDefinition(
            key: "appearance.showSeconds", title: "Show seconds", section: "General · Formatting",
            defaultValue: .bool(false), explanation: "Include seconds in message timestamps and precise dates.",
            androidSymbols: ["NekoConfig.showSeconds", "LocaleController.recreateFormatters"]
        ),
        ClientSettingDefinition(
            key: "appearance.relativeLastSeen", title: "Relative last seen", section: "General · Formatting",
            defaultValue: .bool(false), explanation: "Use minutes or hours ago for known last-seen times within 24 hours. Privacy-hidden times stay hidden.",
            androidSymbols: ["OpenExteraConfig.relativeLastSeen", "LocaleController.formatDateOnline"]
        ),
        ClientSettingDefinition(
            key: "appearance.disableVibration", title: "Disable interface haptics", section: "General · Interface",
            defaultValue: .bool(false), explanation: "Disables in-app taps, selection and feedback vibrations. Notification vibration has its own native setting.",
            androidSymbols: ["NekoConfig.disableVibration", "AndroidUtilities.vibrateCursor"]
        ),
        ClientSettingDefinition(
            key: "appearance.mainTabsHideTitles", title: "Hide tab titles", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "Icons remain centered, with their accessibility labels and unread badges.",
            androidSymbols: ["NaConfig.mainTabsHideTitles", "MainTabsLayout"]
        ),
        ClientSettingDefinition(
            key: "appearance.mainTabsHideCallsSettings", title: "Hide Calls tab", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "Uses Telegram’s native Calls-tab preference. Settings remains reachable.",
            androidSymbols: ["NaConfig.mainTabsHideCallsSettings"]
        ),
        ClientSettingDefinition(
            key: "appearance.mainTabsHideContacts", title: "Hide Contacts tab", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "Contacts remains available from the customizable main menu.",
            androidSymbols: ["NaConfig.mainTabsHideContacts"]
        ),
        ClientSettingDefinition(
            key: "appearance.mainTabsHideProfile", title: "Hide Profile / Settings tab", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "The permanent Main Menu keeps a Settings route while this tab is hidden.", androidSymbols: ["NaConfig.mainTabsHideProfile"]
        ),
        ClientSettingDefinition(
            key: "appearance.hideBottomNavigationBar", title: "Hide bottom navigation", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "The root stays on Chats; use its permanent Main Menu for other destinations. Back returns to the menu-enabled Chats screen.", androidSymbols: ["NaConfig.hideBottomNavigationBar", "MainTabsLayout"]
        ),
        ClientSettingDefinition(
            key: "appearance.newNavigationBarStyle", title: "Material-style navigation", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "A full-width tonal navigation surface with 56×32 selection chips. Native tap, drag and context actions are retained; takes precedence over Wide style.", androidSymbols: ["AppearanceConfig.newNavigationBarStyle", "MainTabsUiHelper"]
        ),
        ClientSettingDefinition(
            key: "appearance.iosNavigationBarStyle", title: "Wide native tab bar", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "Expands the native capsule to the available width with 8pt side insets, including iPad and compact layouts. Off restores the stock floating capsule.", androidSymbols: ["AppearanceConfig.iosNavigationBarStyle", "MainTabsUiHelper"]
        ),
        ClientSettingDefinition(
            key: "appearance.navigationDrawer", title: "Side navigation drawer", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "A native side panel with swipe-to-close and a dimmed backdrop. Off opens the same shortcuts as a navigation page.",
            androidSymbols: ["AppearanceConfig.navigationDrawer", "DrawerContainer"]
        ),
        ClientSettingDefinition(
            key: "appearance.immersiveDrawerAnimation", title: "Immersive drawer animation", section: "Appearance · Navigation",
            defaultValue: .bool(false), explanation: "Scales a passive native snapshot behind the side drawer. It never transforms the live navigation or intercepts vertical scrolling; Reduce Motion disables the animation.", androidSymbols: ["AppearanceConfig.immersiveDrawerAnimation", "DrawerContainer"]
        ),
        ClientSettingDefinition(
            key: "appearance.predictiveBackIntensity", title: "Navigation parallax intensity", section: "Appearance · Navigation",
            defaultValue: .integer(100), minimum: 0, maximum: 200, step: 1,
            explanation: "iOS adaptation: scales the background screen’s parallax in standard push/back transitions. 100% preserves stock geometry. Gesture thresholds, springs, flat modals and profile expansions remain native.", androidSymbols: ["UtilsConfig.predictiveBackIntensity"]
        ),
        ClientSettingDefinition(
            key: "appearance.mainMenuLayout", title: "Main menu layout", section: "Appearance · Navigation",
            defaultValue: .string(""), explanation: "Use Customize Main Menu to reorder or hide shortcuts. Android’s visible;hidden ID format is preserved; unavailable routes are omitted.",
            androidSymbols: ["AppearanceConfig.mainMenuLayout", "MainMenuLayout"]
        ),
        ClientSettingDefinition(
            key: "appearance.sectionRadius", title: "Exteraless card corners", section: "Appearance · Cards",
            defaultValue: .integer(20), minimum: 0, maximum: 28, step: 1,
            explanation: "Corner radius for Exteraless appearance and menu cards, in iOS points.",
            androidSymbols: ["AppearanceConfig.sectionRadius"]
        ),
        ClientSettingDefinition(
            key: "appearance.separateHeaders", title: "Separate section headers", section: "Appearance · Cards",
            defaultValue: .bool(true), explanation: "Segmented cards and Material-style rows always keep separate headers.",
            androidSymbols: ["AppearanceConfig.separateHeaders", "AppearanceConfig.sectionsSeparatedHeaders"]
        ),
        ClientSettingDefinition(
            key: "appearance.dividerStyle", title: "Card dividers", section: "Appearance · Cards",
            defaultValue: .integer(1), options: [
                ClientSettingOption(value: .integer(0), title: "Hidden"),
                ClientSettingOption(value: .integer(1), title: "Lines"),
                ClientSettingOption(value: .integer(2), title: "Separate cards")
            ], explanation: "Applied to Exteraless appearance and main-menu lists.",
            androidSymbols: ["AppearanceConfig.dividerStyle"]
        ),
        ClientSettingDefinition(
            key: "appearance.m3ListItems", title: "Material-style menu rows", section: "Appearance · Cards",
            defaultValue: .bool(false), explanation: "Larger tonal rows with separate headers in Exteraless appearance and menu screens. Native Telegram screens retain their own layout.",
            androidSymbols: ["AppearanceConfig.m3ListItems", "M3ListItems"]
        ),
        ClientSettingDefinition(
            key: "appearance.iconReplacements", title: "Native icon style", section: "Appearance · Icons",
            defaultValue: .integer(0), options: [
                ClientSettingOption(value: .integer(0), title: "Telegram"),
                ClientSettingOption(value: .integer(1), title: "SF Symbols · regular"),
                ClientSettingOption(value: .integer(2), title: "SF Symbols · light")
            ], explanation: "iOS symbol alternatives for mapped menu and navigation icons. Imported packs take priority. Android Solar/Remix artwork is not included.",
            androidSymbols: ["NaConfig.iconReplacements", "BaseIconPacks"]
        ),
        ClientSettingDefinition(
            key: "appearance.enabled", title: "Enable custom icon packs", section: "Appearance · Icons",
            defaultValue: .bool(false), androidSymbols: ["IconPacksConfig.enabled", "IconPackManager.getDrawable"]
        ),
        ClientSettingDefinition(
            key: "appearance.activePacks", title: "Active icon packs", section: "Appearance · Icons",
            defaultValue: .string(""), explanation: "Comma-separated pack IDs, highest priority first. Use Icon Packs to manage them.",
            androidSymbols: ["IconPacksConfig.activePacks"]
        ),
        ClientSettingDefinition(
            key: "appearance.editingPackId", title: "Icon pack being edited", section: "Appearance · Icons",
            defaultValue: .string(""), explanation: "Pack opened by Edit Selected Icon Pack. Empty turns editing off.",
            androidSymbols: ["IconPacksConfig.editingPackId"]
        )
    ] + headerDefinitions

    private static let headerDefinitions: [ClientSettingDefinition] = [
        ClientSettingDefinition(key: "appearance.titleText", title: "Chat-list title", section: "Appearance · Header", defaultValue: .integer(0), options: [
            ClientSettingOption(value: .integer(0), title: "App name"),
            ClientSettingOption(value: .integer(1), title: "Username"),
            ClientSettingOption(value: .integer(2), title: "Name"),
            ClientSettingOption(value: .integer(3), title: "Chats"),
            ClientSettingOption(value: .integer(4), title: "Custom")
        ], androidSymbols: ["AppearanceConfig.titleText", "DialogsActivity"]),
        ClientSettingDefinition(key: "appearance.customTitle", title: "Custom chat-list title", section: "Appearance · Header", defaultValue: .string("exteraless"), androidSymbols: ["NaConfig.customTitle"]),
        ClientSettingDefinition(key: "appearance.hideActionBarStatus", title: "Hide header emoji status", section: "Appearance · Header", defaultValue: .bool(false), androidSymbols: ["AppearanceConfig.hideActionBarStatus"])
    ]
}
