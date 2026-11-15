# Appearance / general — implementer handoff

Source-only implementation; no commit, push, CI dispatch, clone, IPA inspection,
external plugin execution, network request or message sent by this agent.

**Current source handoff:** [appearance-remediation.md](appearance-remediation.md)
tracks AP-01…AP-11 and Identity stitching; [appearance-owner-completion.md](appearance-owner-completion.md)
covers the final controls/state IDs and coordinator hunks. The earlier phase-2
details and frame plan remain in [appearance-subwave.md](appearance-subwave.md).
Windows has no Swift toolchain, WSL or XcodeBuildMCP. Native compile, Swift test
execution and recorded-frame verification remain **pending**, not visual passes.
Unported options are explicitly listed and have no inert settings definition.

Latest supplied initial base: **43693106297**, **b1424e10**, green
(280 Core + 89 Host + 16 Hooks). It predates the remediation/completion fixtures
and is not native build/frame evidence for this source snapshot.

`[x]` below means a connected source consumer, **not** device/visual acceptance;
`[~]` is a stock-equivalent/platform adaptation; `[ ]` is pending; `D` is another
owner's domain and is not claimed complete by this handoff.

Paths below are relative to `telegram-ios/submodules` unless prefixed otherwise.
Android root `A` = `third_party/exteraless-android/TMessagesProj/src/main`.

## Composition / shared insertion hunks

### Application composition

The coordinator has added `ExteralessClientRuntime` with optional domain holders,
constructed after selecting/configuring the shared settings file, and calls to
`appearance.update(context:)` / `clearContext()`. It registers
`AppearanceFeatures.definitions` with the other domains. The appearance class is
`@MainActor` and observes ClientSettings, presentationData, native Calls settings
and the current account's local peer record. It sends no requests.

- Native Calls preferences are read from `CallListSettings`, and writes use
  `updateCallListSettingsInteractively`. The original iOS setting is imported on
  attaching a context, so opening Exteraless does not unhide a user's hidden tab.
- JSON mirroring runs on a utility queue; native mirroring is not fed back as a
  new native command. A generation drops stale queued mirrors after a newer
  native setting/account, and a concurrent user edit wins over an older mirror.
- Icons are decoded off-main and installed as immutable cache generations;
  cancellation/stale completions cannot install another account lifetime's cache.
- `clearContext` disposes account/presentation subscriptions, cancels native
  writes/resource work, removes the image provider and clears cached identity.
- Main Menu is installed through the weak account-scoped
  `AccountContext.ExteralessAppearanceEntry`. Context replacement closes an old
  drawer and drops its deferred actions; persistent tab hiding is cleared on detach.

Current coordinator source uses `ExteralessClientSettingsWorker.prepare` for
serial configure/register/reload and generation-checked main publication. AP-09
separately prevents cheap Appearance/Identity revisions from restarting native
theme file reconstruction. Both changes still need native execution evidence.

### 1. AppDelegate alternate icons — installed by coordinator

The installed change in `TelegramUI/Sources/AppDelegate.swift` replaces the **body** of the existing
`getAvailableAlternateIcons` binding (between that label and `getAlternateIconName`):

```swift
        }, getAvailableAlternateIcons: {
            return exteralessAvailableAppIcons()
        }, getAlternateIconName: {
```

No new import: the callee is public in TelegramUI's
`ExteralessClient/Appearance/ExteralessAppIcons.swift`.

The previous body listed `BlueIcon`, `New1`, `New2`, `Premium`, etc. The checked source
Info.plist actually declares **Black, BlackClassic, BlackFilled, Blue, BlueClassic,
BlueFilled, WhiteFilled**, identically for iPhone/iPad, plus primary `AppIconLLC`.
The catalog reads each build's real plist and uses the **dictionary key**, not the
image filename, as the UIApplication alternate-icon name. It honors
`supportsAlternateIcons` and has a primary-icon reset. The separate Exteraless
App Icon screen already calls this catalog directly. The native Appearance grid
uses the installed binding; its selection/error handling and key labels are fixed.

### 2. Root Contacts-tab filtering — installed in both native rebuilds

`TelegramUI/Sources/TelegramRootController.swift`:

```diff
@@ addRootControllers(showCallsTab:showNewsTab:)
         controllers.append(accountSettingsController)
+        controllers = exteralessFilterRootTabs(controllers, contactsController: contactsController)
         let chatsIndex = controllers.firstIndex(where: { $0 === chatListController }) ?? 0
@@ updateRootControllers(showCallsTab:showNewsTab:)
         controllers.append(self.accountSettingsController!)
+        controllers = exteralessFilterRootTabs(controllers, contactsController: self.contactsController)

          // A removed selected tab would otherwise fall back to index 0 (Contacts): select Chats instead.
@@ openContacts()
         if let index = rootTabController.controllers.firstIndex(where: { $0 is ContactsController }) {
             rootTabController.selectedIndex = index
+        } else {
+            self.pushViewController(ContactsController(context: self.context))
         }
```

No imports needed. `exteralessFilterRootTabs` is public in
`ExteralessTabNavigation.swift`. The integration already applies the filter on
setting/presentation/native-Calls changes and restores the same controller object
when unhidden. The hunk prevents a later unrelated Calls/News rebuild reintroducing
Contacts, and keeps existing `openContacts()` deeplinks functional while hidden.
Phase 2 also filters the Settings tab when explicitly requested and the permanent
menu is installed. Removed selection falls back to Chats, not index zero. The
Settings/whole-bar-hidden deeplink guards are already installed. AP-02/03 correct
the actual Settings type predicate and replay appearance after ready-root mount.

`@MainActor public exteralessPresentMainMenu(context:from:)` is connected to the
permanent ChatList header action through AccountContext, and to the existing
`appearance.mainMenu` settings action. ChatListUI has no TelegramUI dependency.

### 3. Per-chat theme/wallpaper suppression — installed with its definition

`TelegramUI/Sources/ChatController.swift`, in the presentationData subscription,
after preview handling / the Saved Messages guard and before constructing the
effective presentationData:

```diff
@@
                 if strongSelf.chatLocation.peerId == strongSelf.context.account.peerId {
                     chatTheme = nil
                 }
+                let exteralessOverrides = exteralessChatThemeOverrides(theme: chatTheme, wallpaper: chatWallpaper)
+                chatTheme = exteralessOverrides.theme
+                chatWallpaper = exteralessOverrides.wallpaper

                  var presentationData = presentationData
```

Callee is in `ExteralessChatThemeOverrides.swift`; no new imports. It filters only
rendered optional overrides, preserving saved per-chat values. Forced previews'
`forcedTheme` / `forcedWallpaper` still have their existing later precedence.
Shared presentation invalidations already cause recomputation after a toggle.

The coordinator also installed the matching entry in `AppearanceFeatures.definitions`
in `swift/ExteralessCore/Sources/ExteralessCore/AppearanceFeatures.swift`:

```swift
ClientSettingDefinition(
    key: "appearance.customThemes", title: "Per-chat themes and wallpapers",
    section: "Appearance · Themes", defaultValue: .bool(true),
    explanation: "Disabling uses the global appearance without deleting saved chat themes or wallpapers.",
    androidSymbols: ["AppearanceConfig.customThemes", "ChatActivity.setupChatTheme", "ChatThemeController.getDialogWallpaper"]
),
```

The callsite and definition are both present in the current source.

### 4. Shared Exteraless settings card style — installed by coordinator

The effect is connected in appearance/menu/icon screens and the shared client
settings root. The installed `ExteralessSettingsListController` hunk is:

```swift
func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
    let rows = self.sections[indexPath.section].rows
    ExteralessAppearanceListStyle.apply(to: cell, theme: self.presentationData.theme,
        first: indexPath.row == 0, last: indexPath.row == rows.count - 1,
        hasDetail: rows[indexPath.row].detail != nil)
}
```

At the start of its existing `setSections(_ sections:)`, before assigning the
stored sections, the exact transform is:

```swift
let policy = ExteralessAppearanceListStyle.policy()
let sections = sections.enumerated().map { index, section -> ExteralessSettingsSection in
    guard !policy.separateHeaders, let title = section.title, !title.isEmpty else { return section }
    var header = ExteralessSettingsRow(id: "appearance.header.\(index)", title: title)
    header.style = .accent
    header.enabled = false
    return ExteralessSettingsSection(footer: section.footer, rows: [header] + section.rows)
}
self.tableView.separatorStyle = policy.showsDividers ? .singleLine : .none
```

This is deliberately feature-scoped, not a change to defaultPresentationTheme,
UIKit appearance proxies or every stock Telegram list.

## Changed native callsites / build dependencies

Core now has **13 Appearance source files and five Appearance test files**.
Current native targets and the final four dependency edges/Switch test ownership
are recorded in `appearance-remediation.md` and `appearance-build-handoff.patch`.
No BUILD/MODULE edits were made by this role.

Add `//third-party/exteraless:ExteralessCore` to direct importers:

- `//submodules/TelegramUI:TelegramUI` (recursive `ExteralessClient/Appearance/**`).
- `//submodules/TelegramPresentationData:TelegramPresentationData` — new
  `ExteralessAppearanceUpdates`, `ExteralessHeaderIdentity`, `ExteralessFolderTitle`,
  `ExteralessTabIcons`; existing PresentationData/NumericFormat edits.
- `//submodules/TextFormat:TextFormat` — `DateFormat.swift`.
- `//submodules/TelegramStringFormatting:TelegramStringFormatting` — DateFormat/PresenceStrings.
- `//submodules/Display:Display` — HapticFeedback, including continuous haptics.
- `//submodules/AvatarNode:AvatarNode` — new ExteralessAvatarShape plus AvatarNode/PeerAvatar.
- `//submodules/ChatListUI:ChatListUI` — folder unread-count policy.
- `//submodules/TabBarUI:TabBarUI` and
  `//submodules/TelegramUI/Components/TabBarComponent:TabBarComponent`.

TelegramUI additionally needs its existing `Svg` dependency visible to the new
file and native SDK `Compression` / `ImageIO` (UIKit already present).
`AppBundle` .m/.h keep their current target: the thread-safe optional image
provider and tab-image provenance are Objective-C, with no Swift/Core dependency.
No new binary/icon artwork is needed: the base adaptation uses system SF Symbols,
and real alternate app-icon PNGs/plist already belong to Telegram's source bundle.

Other native seams (phase-2 direct imports are included in its dependency list):

- `ChatListUI/Sources/ChatListController.swift`: actual `updateChatList` title and status.
- `ChatListUI/Sources/Node/ChatListItem.swift`: online-dot offset, sender avatars,
  thumbnail and bot-action layout eligibility.
- `ChatListFilterTabContainerNode/...swift`: folder display title, preserving VoiceOver name.
- `AvatarStoryIndicatorComponent/...swift`: explicit optional corner fraction, included in equality.
- `SettingsUI/Sources/Themes/ThemeSettingsController.swift` and `ThemeSettingsAppIconItem.swift`:
  system-confirmed checkmark, failure alert, correct names/primary-image fallback.

## Original-source setting matrix

### AppearanceConfig.kt — all fields (not shim getter names)

Source: `A/kotlin/app/exteraless/appearance/AppearanceConfig.kt`. Unless shown
otherwise, the storage key is `OEAppearance` plus the field's capitalized name.
Constants: `AVATAR_CORNERS_MAX=28`, `MONET_STYLE_TELEMONE=0`.

| State | Original field / default | Real Android consumer | Swift consumer / disposition |
|---|---|---|---|
| [x] adapted | `avatarCorners=28` | ImageReceiver / `AppearanceConfig.getAvatarCorners` | `AvatarNodeClipStyle.withExteralessShape`, legacy photo/placeholder clipping and V2 layer corners; resolved shape is part of state/cache equality. 28 retains native forum shape. |
| [x] adapted | `singleCornerRadius=false` | `getAvatarCorners`, forum 42/64 and community 40/72 | Same helper; forum becomes the ordinary shape when enabled. Pure original radius formula is pinned, native default forum quarter-radius is explicit adaptation. |
| [x] adapted | `senderMiniAvatars=true` | `DialogCell.java:751–764`, sender-avatar span | `ChatListItem` renders an 18pt peer-matched image beside the author or inline forum preview; self/draft/name-only authors skipped, width restored on reset. |
| [x] | `hideActionBarStatus=false` | `ActionBar.filterStatusDrawable`, DialogStoriesCell | Chat-list, chat and profile headers filter emoji/Premium status; verification/fake/scam badges retain native behavior. |
| [x] | `titleText=0` | `TypefaceHelper.getTitleText:326–355` | `exteralessChatListTitle` / actual header callsite. 0 app name, 1 public username **without @**, fallback first name, 2 first name, 3 Chats, 4 custom. Stock tab title remains Chats. |
| [~]/[ ] | `monetStyle=0` | `monetAssetSuffix`: Telemone vs `_gram` Monet assets | Native theme/color editor is a real alternative. The supplied Android source tree has no res/assets token base; exact Telemone/Classic palettes and selector remain absent. |
| [x] adapted | `squareFab=true` | `fabCornerRadius`, FAB shape consumers | Native 56pt floating compose action, ceil(side*16/56) radius vs circle; real header compose restored when floating action is disabled. |
| [x] alias | private legacy `centerTitle=false` | Getter reads `NaConfig.centerActionBarTitle`; setter also writes type 1/0 | Legacy field is not duplicated. The real boolean drives leading/centered chat-list title layout with bounded hit area. |
| [x] adapted | `gooeyAvatarAnimation=true` | Android profile stretch/morph | Native expanded-photo elasticity on/off; normal expansion/collapse preserved. Android mesh equivalence is not claimed. |
| [x] | `customThemes=true` | ChatActivity:47540; ChatThemeController:380 | Coordinator-wired ChatController suppression of rendered overrides; saved themes/wallpapers restored when re-enabled. |
| [x] adapted | `sectionRadius=20` | RecyclerListView.setSections / SectionsScrollView | `ExteralessAppearanceListStyle.apply`, per-cell masks with outer-section corners; 0..28pt. Only feature lists, not stock defaults. |
| [x] adapted | `separateHeaders=true` | `sectionsSeparatedHeaders` | `ExteralessAppearanceListController.setSections`; segmented/M3 force separated headers. |
| [x] adapted | `dividerStyle=1` | dividerHidden cache, RecyclerListView segments | Lines/hidden/separate native cards; canonical Hidden also suppresses native list/context-menu separators through an immutable palette and restores their original colors on reset. |
| [x] adapted | `glassOutlineStyle=0` | GlassOutlineStyle.dispatchChange | Shared GlassBackgroundView: native glare, material with solid stroke, material without stroke. Custom tints and reset preserved; LiquidLens internals are outside this scope. |
| [x] adapted | `glassMessageMenu=true` | Android message popup | Native ContextController stacked/legacy panel backgrounds switch glass/opaque; includes other menus using those containers. |
| [x] partial | `newLoadingStyle=true` | RadialProgressView, LineProgressView, CacheControlActivity | Actual ActivityIndicator Material arc/track with native/custom restoration. Line/cache-progress variants remain unported. |
| [x] adapted | `newChatHeaderStyle=false` | ChatHeaderUiHelper | No title pill, +4pt avatar inside the native 44pt control, +30pt top fade. Default restores native metrics. |
| [x] adapted | `newNavigationBarStyle=false` | MainTabsUiHelper | Native full-width tonal tabs and 56×32 selection chips; Material takes precedence over wide style. |
| [x] adapted | `m3ListItems=false` | `M3ListItems`, stock 50→56 / 64→72, hidden dividers | Feature-list minimum heights and tonal cards; only Exteraless lists. Exact Android HSL tonal palette not claimed. |
| [x] adapted | `iosNavigationBarStyle=false` | MainTabsLayout, M3 takes priority | Real wide native capsule with 8pt side insets; off restores floating stock width. |
| [~] | `iosChatHeader=false` | ChatActivity.canShowCenteredTitle | Android selects an iOS-style centered-header path; native ChatNavigationBarTitleView already supplies it. No redundant inactive flag; mode-specific equivalence remains unverified. |
| [x] adapted | `navigationDrawer=false` | DrawerContainer / LaunchActivity.syncDrawerContainerEnabled | Permanent account-scoped header entry: native navigation page when off, interactive side panel when on. |
| [x] adapted | `immersiveDrawerAnimation=false`, key `OEAppearanceImmersiveDrawer` | DrawerContainer reveal | Passive snapshot scales behind the real drawer, with swipe/cancel/fling and Reduce Motion handling. |
| [x] adapted | `mainMenuLayout=""` | MainMenuLayout + MainMenuHelper | Native menu/editor preserves original format and unavailable provider positions. Dynamic routes, required Settings/Search fallbacks; 128 parsed entries per side. |
| D | `showFeedTab=false` | MainTabsLayout feed-for-Contacts | Chat/feed owner; native parked News API must not be re-enabled as a fake feed. |
| D | `showFeedUnreadCounter=true`, key `OEAppearanceFeedUnreadCounter` | Feed tab badge | Chat/feed owner; no duplicate appearance definition. |
| D | `profileMusicCard=true` | Profile music card | Chat/player owner; no claim here. |
| D | `hideAiEditor=false` | composer / attachment / caption AI editor | AI owner. |
| D | `hideMessageSummary=false` | message summary button | AI/chat owner. |
| D | `hideIvSummary=false` | Instant View Cocoon summary | AI owner. |

Player fields are explicitly outside this role, but all defaults read from this
same file are recorded to prevent them vanishing from the inventory:

| Owner | Fields / exact defaults | Original storage prefix |
|---|---|---|
| D chat/player | `md3Player=true`, `md3MiniPlayer=true` | `OEAppearanceMd3*` |
| D chat/player | `lrclibAllowed=false` | `OEPlayerLrclibAllowed` |
| D chat/player | `playerCoverStyle=0`, `playerCoverSize=100`, `playerCoverRadius=28`, `playerDiscSpin=true`, `playerCoverSwipe=true` | `OEPlayer*` |
| D chat/player | `playerTitleAlign=0`, `playerTitleSize=1`, `playerTitleAbove=false`, `playerOrder=""` | `OEPlayer*` |
| D chat/player | `playerShowActions=true`, `playerShowModes=true`, `playerShowLike=true`, `playerShowSource=true`, `playerWavy=true` | `OEPlayer*` |
| D chat/player | `playerControlsSize=1`, `playerActionsStyle=0`, `playerColors=0`, `playerBackground=0`, `playerCoverExtend=true` | `OEPlayer*` |
| D chat/player | `playerMiniCover=0`, `playerMiniShape=0`, `playerMiniProgress=0`, `playerMiniColors=1` | `OEPlayer*` |
| D chat/player | `playerMiniCompact=false`, `playerMiniArtist=true`, `playerMiniPrevious=false`, `playerMiniNext=true`, `playerMiniClose=true`, `playerMiniTop=false` | `OEPlayer*` |

### Appearance/navigation screen settings backed by NaConfig / NekoConfig

Sources: `A/java/app/exteraless/settings/OpenExteraAppearanceActivity.java`,
`OpenExteraAppNavigationActivity.java`, actual definitions in
`A/kotlin/xyz/nextalone/nagram/NaConfig.kt` and `A/java/tw/nekomimi/nekogram/NekoConfig.java`.

| State | Original field / default | Real source and native mapping |
|---|---|---|
| [x] | `NaConfig.customTitle="exteraless"` | TypefaceHelper; native header identity/policy. Empty custom string falls back to app name; multiline text rendered as one bounded line. |
| [x] adapted | `NekoConfig.tabsTitleType=0` (TEXT) | Option order **[2,0,1]**. Both modern/legacy tabs use `exteralessFolderTitle`, preserving UTF-16 entities and VoiceOver names. Icons-only mode derives the selected-folder header; edit/network/inline titles retain precedence. |
| [x] | `NaConfig.ignoreUnreadCount=1` on fresh install | AP-01: absent IgnoreMutedCount defaults to **true**, so native registration/reset/fallback now use Exclude Muted=1. Explicit All=0 is preserved. The consumer uses the real numeric unmuted aggregate; native All Chats keeps its stock no-badge behavior. |
| [x] | `NaConfig.mainTabsHideTitles=false` | TabBarComponent and legacy TabBarNode: center icons, move badges with them, keep VoiceOver labels/selected state. |
| [x] | `NaConfig.mainTabsHideCallsSettings=false` | Native Calls-only adaptation through CallListSettings; Settings stays reachable. |
| [x] | `NaConfig.mainTabsHideContacts=false` | Both root rebuild filters and whole-bar-hidden Contacts fallback are installed; retained controller identity, Feed replacement and menu recovery are preserved. |
| [x] | `NaConfig.mainTabsHideProfile=false` | AP-02 uses actual PeerInfoScreen type; AP-03 replays after mount. Mandatory menu Settings and external openSettings fallback are installed. |
| [~] | `NekoConfig.typeface=true` | Android chooses bundled vs system font **family**; iOS native system Font/UIFont already supplies the family. **Not** mapped to `PresentationThemeSettings.useSystemFont`, which means Dynamic Type size on iOS. Text size uses the real native Appearance controller/preferences. |
| [x] adapted | `NaConfig.switchStyle=2`, `sliderStyle=2` | Real SwitchComponent backends: 0 native, 2 filled, 3 M3. Eligible SliderComponent: 0 native/legacy, 2 8pt rail and 3×24 grip; specialized geometry stays caller-owned. Legacy slot 1→2 belongs to import normalization. |
| [x] adapted | `NaConfig.centerActionBarTitle=false`, `centerActionBarTitleType=1` | Master boolean plus 0 off / 1 both / 2 appearance settings / 3 chat list, on actual native title lanes. Original Android startup collapses 2/3 to 1; native explicit scope is preserved. |
| [x] adapted | `NekoConfig.forceFontWeightFallback=false` | Real Font factories resolve medium/semibold to bold, including italic and cache identity; camera font resources are preserved. Chat-list title font is recomputed on presentation updates. |
| [x] adapted | `NekoConfig.hideAllTab=false` | Both tab renderers hide All in a selected folder, with recovery during All selection, transitions, editing/reordering and no-folder state. |
| [x] adapted | `NekoConfig.actionBarDecoration=0`, `NaConfig.chatDecoration=0` | Independent 0/1 native header/wallpaper snow with fixed layer caps and system/lifecycle gates. Android combined screen toggle is an explicit UI difference. |
| [~]/[ ] | `LiteMode.FLAG_CHAT_BLUR` device/LiteMode-dependent | Native Appearance → Power Saving uses actual MediaAutoDownloadSettings/energy usage. The ExteraConfig `forceBlur=false` getter is storage-only, not this live setting. No fake force-blur toggle. |
| [x] adapted | `NaConfig.disableAvatarBlur=false` | Actual native profile action/edge/Dynamic Island avatar-cover blur gates; thumbnail decoding remains separate. |
| [~]/[ ] | `NekoConfig.tabletMode=0` (auto) | Native `TelegramRootController(mode: .automaticMasterDetail)` uses size classes/safe areas; forced tablet/phone override is not implemented. |
| [x] adapted | `NaConfig.backAnimationStyle=0` declared; effective fresh default **SPRING=1** | Original IDs 0 Classic / 1 Spring / 2 Predictive / 3 Slide select native tap/release/reverse curves and paired-slide geometry. Interactive tracking/profile expansion remain native; exact Android shrinking-card rendering is not claimed. |
| [x] adapted | `NaConfig.springAnimationCrossfade=true` | Spring-mode navigation capsule content uses common live/sampled opacity; off switches content at midpoint. |
| [x] adapted | `UtilsConfig.predictiveBackIntensity=100`, range 0..200 | Native latched background parallax, shared by live and baked timelines. Unlike Android adjusted progress, 0 removes parallax without disabling back navigation; 100 restores stock 0.3 factor. |
| [x] | `NaConfig.alwaysShowDownloadIcon=false` | Real persistent header action calls native Downloads search, removed on reset. |
| [x] | `NaConfig.hideBottomNavigationBar=false`; `OEAppearanceBottomNavigationFloating=false` | Native persistent hide/show is independent of search hiding; main menu remains reachable. Ready-root application and external fallback are wired. Floating/wide/Material are real native variants. |
| [x] | `NaConfig.disableDialogsFloatingButton=false` | True restores native header compose; false enables the real floating action. |
| [x] | `NaConfig.hideStoriesFromHeader=true` | Native story-strip rendering and expansion/inset paths share one gated predicate. |
| [x] | `NaConfig.hideDialogsSearchField=false` | Hides only the idle native search field; permanent menu Search remains accessible and active search retains native controls. |
| [x] | `NekoConfig.mediaPreview=true` | Native thumbnail eligibility also removes image nodes and text cutouts on disable. |
| [x] | `NaConfig.disableBotOpenButton=false` | Native row Open App button eligibility, hit target and width restore through the existing removal path. |

The Help/Premium/Stickers defaults (`true / false / true`), canonical hideDividers
alias, raw source-unused fields and eight drawer/picker/intro/animation state IDs
are individually traced in `appearance-owner-completion.md`. The three native
Settings controls have a paired coordinator hook and are not registered before it.

### IconPacksConfig.kt / app icons / drawer routes

| State | Original field / default | Actual native effect |
|---|---|---|
| [x] | `enabled=false` / `OEIconPacksEnabled` | Predecoded custom-pack map enabled/disabled at AppBundle image lookup. Base icon choice stays independent, as in IconPackManager.getDrawable. |
| [x] | `activePacks=""` / `OEIconPacksActive` | Ordered first-pack-wins map with per-resource fallback; UI toggle prepends new pack, priority action moves it first, removal forgets it. |
| [x] | `editingPackId=""` / `OEIconPacksEditing` | Edit Selected Icon Pack uses this ID; picking an image pins pack/resource before picker opens. Replace, per-icon restore, create/rename/delete/export are real file operations. |
| [~] | `customNotificationIcon=false` / `OEIconPacksNotificationIcon` | iOS notification app icon is system-managed, follows the declared launcher icon; no ContentProvider/small-notification-icon replacement API. Not registered. |
| [x] adapted | `useSystemIconShape=false` / `OEIconPacksSystemShape` | Actual App Icon preview: circle/continuous rounded square, long-press/accessibility toggle. Exact SpringBoard mask is not claimed; launcher selection still uses UIApplication. |
| [x] adapted | `NaConfig.iconReplacements=0` | 0 stock, 1 regular SF Symbols, 2 light SF Symbols on **38 explicit real menu/tab asset mappings**. Numeric semantics preserve base choice, but these are honestly labelled iOS alternatives, not Solar/Remix artwork. Source checkout has Java maps but no Android drawable assets. |
| [x] adapted | `AppIcons.current/apply`, Android default EXTERALESS | Actual UIApplication binding and bundle-driven native catalog; completion/error re-reads actual system selection. No arbitrary launcher XML or downloaded app-icon promise. |

Archive format is Android's `.icons` ZIP with schema-version-1 `metadata.json`:
`packId`, `packName`, optional author/version, `icons: {drawable:relativePath}`.
Native import accepts stored/DEFLATE entries; export uses stored entries, which
Android ZipFile supports. Unknown drawable mappings survive import/export and are
reported separately from mapped ones. PNG/JPEG/WebP use bounded ImageIO thumbnails;
SVG uses the repository's native Svg renderer. No scripts are executed.
Bounds: 100 MiB archive/expanded data, 10 MiB file, 256 KiB metadata, 3000 entries,
compression ratio 250; UTF-8 relative paths, duplicate/case-fold path, symlink,
ZIP64/encryption/method, local-header and CRC checks. SVG is further bounded to
512 KiB, raster dimensions to 4096. A whole validated pack moves from staging;
existing IDs are never silently overwritten. Failed metadata writes clean new
uncommitted replacement files; original files survive.

Drawer ID coverage (`MainMenuItem.java`): Archive 14, New Group 2, New Channel 3,
Contacts 6, Calls 10, Saved 11, Settings 8, Plugins 102, Exteraless Settings 110;
plus Profile 18, Apps search 105, Browser 101, validated QR 17, Recent Chats 108,
capability-gated Wallet 109 and dynamic Feed 106 / Ghost 107 actions. Group opens
native selection then creation UI; the shortcut creates/sends nothing. Repeated
divider -1 is preserved. Unavailable providers retain positions and can be replaced
through `ExteralessMainMenuRegistry`. iOS kill-app 111 is explicitly rejected.
Android per-bot side-menu expansion and automatic browser homepage selection remain
routing differences; see the subwave handoff.

### GeneralConfig.kt / OpenExteraConfig.kt / General & Other screens

| State | Source field / default | Native callsite or owner/remaining |
|---|---|---|
| [x] | `NekoConfig.disableNumberRounding=false` | `TelegramPresentationData.compactNumericCountString` → `AppearanceNumberPolicy`; exact decimal string, no grouping, matches LocaleController.formatShortNumber:3071. |
| [x] | `NekoConfig.showSeconds=false` | PresentationDateTimeFormat carries the preference; TextFormat.stringForMessageTimestamp and precise date/presence formatters pass actual timestamp seconds. Explicit withSeconds still wins after reset. |
| [x] | `NekoConfig.disableVibration=false` | `Display.HapticFeedback.withImpl` and ContinuousHaptic; running continuous feedback stops when disabled. Not conflated with InAppNotificationSettings.vibrate (different native default/meaning). |
| [x] | `OpenExteraConfig.relativeLastSeen=false` | PresenceStrings.stringAndActivityForUserPresence; exact known timestamps by default, relative for <24h when enabled, native privacy buckets untouched. Timer refresh aligns to minute/hour boundaries. |
| D | `OpenExteraConfig.addCommaAfterMention=true` | Chat/composer owner; no duplicate appearance key. |
| [~]/D | `OpenExteraConfig.downloadEmojiPacks=false` | Android metadata-channel download is opt-in; iOS uses native/system emoji and native sticker settings. No external channel request added. |
| D | `OpenExteraConfig.proxyDisableConditions=0` | Privacy/network owner; this is a bit mask, not a boolean VPN shim. |
| D | `GeneralConfig.botPrivacyEnabled=false`, `botPrivacyAlwaysAsk=false`, `botPrivacyUserId=0L` | Privacy owner; stable Telegram user ID, not reused account slot. |
| D/[ ] | `GeneralConfig.downloadSpeedBoost=0` | Android FileLoadOperation chunk/concurrency 0/1/2; transfer/network coordinator. Not a cosmetic appearance preference. |
| [~] compat/hidden | `GeneralConfig.showNagramSettings=false` | Source migration forces false; OtherActivity's nagramSettingsRow is -1. No iOS NagramX settings root. |
| D Tools | `GeneralConfig.crashReports=false` | **Live Android release gate**: AndroidUtil.shouldEnableCrashlytics is `!DEBUG && GeneralConfig.crashReports()`. Tools owns the local MetricKit/manual-export adaptation and its receipt. The stale Appearance pending receipt was removed. |
| D | `GeneralConfig.contentCapture=false` | Android ContentCaptureManager; privacy agent maps iOS Siri interaction donation separately. No attempt to call Android window APIs. |
| D/[ ] | `NaConfig.zalgoFilter=false` | MessageHelper uses four consecutive combining marks; chat rendering/entity-aware filter is another owner, not a text-mutating appearance hack. |
| D | `NekoConfig.translationProvider=1`, `translateToLang=""`; ChatsConfig.translateInSheet | AI/translation/chat owners and native translation preferences. |
| D/[ ] | `NekoConfig.uploadBoost=false`, `useIPv6=false`, `dnsType=DNS_TYPE_DEFAULT`, `customDoH=""` | Native transfer/network composition, not registered here. |
| D/[ ] | `NekoConfig.customSavePath="exteraless"`, `NaConfig.saveToChatSubfolder=false` | Tools/storage owner. iOS Files security-scoped destinations differ from Android shared-storage folder names. |
| D | `NekoConfig.hidePhone=true`, `NaConfig.idDcType=1` | Privacy/coordinator PeerInfo rows, API vs Bot API IDs differ. |
| D | `NaConfig.sortByUnread=false`, `hideArchive=false`, `doNotUnarchiveBySwipe=false`; `NekoConfig.unlimitedPinnedDialogs=false`, `openArchiveOnPull=false` | Chat-list behavior owner. Distinguish NaConfig.sortByUnread from unused same-named Neko legacy field. |
| [~]/D | `NekoConfig.useOSMDroidMap=false`, `mapDriftingFixForGoogleMaps=true`, `mapPreviewProvider=0` | Native MapKit / location implementation, Android Google/OSMDroid SDK knobs have no direct iOS setting. Provider opt-out needs its own native consumer. |
| [~]/D | `NaConfig.pushServiceType=1`, `pushServiceTypeInAppDialog=false`, `pushServiceTypeUnifiedGateway=""`; `NekoConfig.disableNotificationBubbles=false` | Native APNs/privacy owner. FCM/UnifiedPush/MicroG, Android persistent-service notification, notification bubbles and battery-exemption intents are Android platform APIs, not successful iOS toggles. |
| D | `NekoConfig.localPremium=false`, `NaConfig.noiseSuppressAndVoiceEnhance=false`, `enhancedVideoBitrate=false` | Chat/media/other owner; latter rows are -1 on the inspected Other screen. No server entitlement claims. |

### Why ExteraConfig is not the setting inventory

`A/java/com/exteragram/messenger/ExteraConfig.java:37–51` explicitly describes
compatibility storage. Live forwarding examples are number rounding → Neko,
seconds → showSeconds, vibration → **inverted** disableVibration, avatar radius →
AppearanceConfig, and iconPack → NaConfig.iconReplacements. In contrast,
`tabIcons` (TITLES_ONLY), `tabCounter=true`, `newSliderStyle=true`,
`newSwitchStyle=true`, `springAnimations=true`, `forceBlur=false`, `eventType=0`
read/write the private `exteraconfig` file. Their real screens use tabsTitleType,
ignoreUnreadCount, sliderStyle/switchStyle, backAnimationStyle and LiteMode.
They must not become duplicate inert client controls or override the actual defaults.

## Tests, evidence, and outstanding acceptance

Source checks performed on this Windows host:

- `git diff --check` for owned Core/native paths: passed before final handoff.
- Independent Python stdlib `zipfile` probe validates the **418-byte** fixture's
  CRC, metadata and 100-byte SVG; it is not emitted by the Swift codec under test.
- Bounded native source scan initially found 36/38 icon literals, catching wrong
  `Unread` / `Mute` names. Corrected to actual `MarkAsUnread` / `Muted`; MarkAsRead
  is also aligned with the real ChatList context menu. Final rescan passed **38/38**.
- Parsed both real source plist icon tables and Kotlin/Java ConfigItem defaults.
- `PostboxImportCheck.py`: the phase-2 whole-checkout run **passed**. Earlier
  privacy-owned findings from the initial handoff are no longer current.

Swift tests authored, **not executed here**:

- `AppearancePolicyTests`: original avatar clamp/forum/story rounding order,
  non-overflowing full counts, seconds reset/explicit override, relative presence
  boundaries and refresh, folder unmuted numeric counts, UTF-16/emoji title
  transformation, real title fallback semantics, stable tab selection, forced
  separated headers and menu serialization/reachability, real plist name mapping,
  per-chat override suppression/restoration.
- `AppearanceIconPackTests`: independent ZIP fixture, CRC corruption, local-header
  mismatch, traversal, oversized declarations before inflation, alias/priority/
  disabled behavior, actor-backed install/no-overwrite/replace/reset/export/delete.
- `AppearancePresentationPolicyTests`: nine phase-2 tests for sender eligibility,
  action-safe title lanes, compose/elastic geometry, transient-vs-persistent tab
  hiding, exact Material chips, bounded parallax/snow/drawer policies, and provider
  unregister/re-register layout preservation. These are authored source fixtures.

On the Mac build lane, run the appropriate full native build and bounded tests:

```sh
swift test --package-path swift/ExteralessCore --filter Appearance
```

Bound test execution to 20–30 seconds after building, per contract. Include the
existing TextFormat tests because its real timestamp formatting function changed.
Native DEFLATE/SVG/ImageIO and UIApplication completion flows need the iOS build;
Foundation tests alone cannot certify them.

Local source defects fixed during the port:

- PeerAvatar now reads the completed resource callback's `data.path`, not an old
  captured `maybeData.path`; forwards `provideUnrounded` correctly; full-size
  replacement retains requested clip style; unrounded empty image is actually unrounded.
- Avatar shape goes into cache identity, not only a late draw getter. Stories'
  optional corner fraction participates in equality. Online-dot offset moves with
  squareness; native circle/default and voice-chat marker placement are preserved.
- Native app-icon checkmark changes only after UIApplication completion, and
  failures show actual active selection. Stale retained tab images are resolved
  from provenance when packs are disabled, including extracted/context images.
- Relative refresh uses the time **until** the next boundary, not elapsed modulo.
- Late icon/cache generations and native-preference mirrors are discarded;
  images/archives and durable JSON writes do not block the main thread.

### Required frame scenarios — expectations recorded before capture

No frames have been captured; every visual/animation claim is pending AGENTS.md.

1. Avatar corners 28→14→0→28 with a loaded photo, placeholder, forum and stories:
   photo and ring change together, no cached circular crop at 0, no clipped marker,
   reset restores native circle/forum shapes. Check voice-chat and online markers.
2. Tab title hide/show and icon pack on/off: icon/badge centers move together,
   VoiceOver label and selected trait remain; context extraction uses the same icon.
   Hide currently selected Contacts, keep Settings/Calls selection stable, unhide,
   then toggle native Calls setting and switch accounts.
3. App icons: select each actually declared alternate and primary; cancel/failure
   never leaves a checkmark on an unapplied icon; iPad uses its own assets. Device
   UIApplication confirmation is a prerequisite, not a simulator-only claim.
4. Folder titles/counters: names/mixed/icons and all/unmuted/off, folders containing
   UTF-16 custom emoji, muted and unmuted chats. Original name remains in accessibility.
5. Menu/card styles: page/drawer close and reopen, move/hide/unhide/repeated dividers,
   reset, section corners 0/20/28, lines/segments, large Dynamic Type, dark/light,
   rotation and asymmetric safe areas. Stock Telegram settings keep their own defaults.
6. Time/header: real timestamps with nonzero seconds in 12/24-hour formats;
   explicit long dates still show seconds after reset; username missing uses first
   name; account switch never shows the other account's cached name; reconnecting
   network titles still have native precedence.
7. Pack import/edit/export: two packs overlap, first wins; corrupt import preserves
   installed pack; replace and restore a real mapped icon; disabled state restores
   native assets; changing theme recolors templates without a flash or stale cache.

AP frame expectations are in `appearance-remediation.md`; the additional control
frames and source-backed state dispositions are in `appearance-owner-completion.md`.
Exact Monet/font assets, forced device layout and documented renderer differences
remain partial. Connected variants still require native/visual acceptance.

## Machine-readable integration fragment

`docs/wave-2/appearance-parity.json` follows `docs/parity/schema.md`: **78 original
feature IDs**, plus `module.appicons` for its stateless native selection surface.
Actual typed keys override proposals where this role owns the effect (for example
`openextera.relativeLastSeen` → `appearance.relativeLastSeen`, `icons.enabled` →
the actual unique `appearance.enabled` definition). Pending/unregistered controls
have an empty `ios.implementation_callsites` array and an explicit reason.

All evidence is `kind=source`, including authored-but-unexecuted XCTest sources.
No entry is verified or `ported=true`. Feature statuses: **15 implemented, 58 partial,
0 pending, 2 unsupported, 3 compat-storage**. Shared wiring, scoped UI adaptations
and icon subset limitations are marked partial. Player/feed/AI/privacy-owned IDs
are not duplicated from the delegated rows in the matrix above.

Final read-only validation and FROZEN pins are recorded in `appearance-remediation.md`.
All 56 active typed keys have original-ID consumer receipts. The three native
Settings controls await `appearance-owner-common.patch`; their rows are explicitly
partial. Tools already delegates predictive intensity to Appearance. Combined
wave reconciliation and primary inventory regeneration remain coordinator-owned.

Additional lifecycle repair: New Group's result subscription is attached to the
native selector by `ExteralessAppearanceLifetime.swift`, because a native Back
gesture does not emit a cancellation result. It no longer leaves a standalone
subscription holding the account after that controller is released.
