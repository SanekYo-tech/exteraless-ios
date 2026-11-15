# Appearance original-scope completion — source handoff

Continuation after AP-01…AP-11 (`appearance-remediation.md`). Independent review
remains read-only. Native compilation/XCTest/frames are pending on the Xcode 27.1
graph; the old 280-Core green base does not certify these additions.

## New connected controls and canonical aliases

| Original ID / original default | Actual iOS key / consumer | Scope and restoration |
|---|---|---|
| `neko.forceFontWeightFallback=false` | `appearance.forceFontWeightFallback`; `Display/Font.with`, `medium`, `semibold`, `mediumItalic` | Medium/semibold → native bold, including italic weight; resolved weight is in the cache key. Off uses original factories/cache entries. ChatListTitleView re-evaluates its font on presentation updates; camera-specific font resources are preserved. |
| `nagram.switchStyle=2` | `appearance.switchStyle`; `SwitchComponent` + `AppearanceSwitchControl` | Slot 0 is real UISwitch; 2 is the original filled Extera capsule; 3 is the outlined M3 geometry. Actual UIControl touch, drag, cancel and accessibility action; 44pt target. Component-based screens only; no claims about every legacy SwitchNode. |
| `nagram.sliderStyle=2` | `appearance.sliderStyle`; `SliderComponent` | Native TG slider interaction/value callbacks with 8pt rail and cached 3×24 grip. Explicit/custom/min-limited/two-sided geometry stays caller-controlled. Off restores native/legacy choice. Android's 6pt rail cutout and exact palette remain a scoped visual difference. |
| `nagram.centerActionBarTitleType=1` | `appearance.centerActionBarTitleType`; ChatListTitleComponent and ExteralessAppearanceTitleView | 0 off, 1 both, 2 settings, 3 chat list, gated by the original center-title boolean. Native action-safe title-view API controls actual appearance/menu pages. Android 2/3→1 startup migration is recorded; iOS keeps an explicit selection. |
| `icons.useSystemIconShape=false` | `appearance.useSystemIconShape`; ExteralessAppIconLogoView in real App Icon screen | Circle vs continuous rounded-square preview, also toggled by long press/accessibility action. Does not claim access to SpringBoard's private exact icon mask. Native alternate-icon selection still uses its real UIApplication completion. |
| `nagram.backAnimationStyle` declaration 0; fresh effective **1** | `appearance.backAnimationStyle`; NavigationTransitionCoordinator | Original IDs 0 Classic / 1 Spring / 2 Predictive / 3 Slide. Native tap/release/reverse curves; paired-screen geometry for 3. Finger tracking, flat modals and profile expansions keep native contracts. Android shrinking-card predictive rendering adapts to a damped iOS release; no exact-motion claim. |
| `nagram.springAnimationCrossfade=true` | `appearance.springAnimationCrossfade`; NavigationBarPlatterTransitionView | Latched with Spring mode at transition start. Both live and sampled capsule-content opacity use one policy; off switches at midpoint. Covers native capsule buttons/title pills, not arbitrary UIKit chrome. |
| `neko.hideAllTab=false` | `appearance.hideAllTab`; modern ChatListControllerNode and legacy ChatListFilterTabContainerNode | Hides the All chip while a custom folder is selected. Keeps All visible during native All selection, reordering and transitions; no folder deletion or changed server order. This recovery behavior is an explicit iOS adaptation. |
| `nagram.hideDividers=false` | canonical `appearance.dividerStyle`; list style + cheap presentation palette | Android `AppearanceConfig.migrateLegacyKeys` synchronizes this legacy boolean with dividerStyle=Hidden. One iOS control; hidden clears native list/context-menu separator colors on a fresh immutable theme copy. Reset reuses the native palette. |
| `neko.tabsTitleType=0` | `appearance.tabsTitleType`; modern/legacy tabs and ChatListControllerNode header | Both real renderers now use the same UTF-16-aware title projection. Icons-only mode derives the selected-folder header from the actual filter, retaining edit/network/inline title precedence. Full VoiceOver names and selected state belong to the interactive copy, not the lens duplicate. |

The previous 48 definitions plus eight new keys are active. The three settings
section definitions below are deliberately separate until their shared hook lands.

## Coordinator hook: three real native Settings controls

`appearance-owner-common.patch` contains the narrow integration:

1. In `PeerInfoSettingsItems.swift`, only the final return of
   `settingsItems(data:context:presentationData:interaction:isExpanded:)` becomes
   `exteralessAppearanceSettingsItems(...)`.
2. At the same time append
   `AppearanceAdditionalFeatures.settingsSectionDefinitions` to
   `AppearanceFeatures.definitions`.

The callee is implemented in the appearance-owned new
`PeerInfoScreen/Sources/ExteralessAppearanceSettingsItems.swift`. It uses actual
`SettingsSection` identity and existing native item/action types:

- `nagram.hideHelpSection=true` → `appearance.hideHelpSection`: drops `.support`.
- `nagram.hidePremiumSection=false` → `appearance.hidePremiumSection`: drops
  `.payment` (Premium/Stars/TON/Business/Gift, as Android does), preserving `.wallet`.
- `nagram.showStickersRowToplevel=true` → `appearance.showStickersRowToplevel`:
  inserts a stable-ID row after Appearance, once global settings are ready. It calls
  the already implemented `interaction.openSettings(.stickers)` path and does not
  duplicate the sticker engine/controller.

No shared PeerInfo builder was overwritten by this owner. Until coordinator
integration these three keys are not shown as inactive controls; receipts remain
partial with the exact callee/hunk evidence.

## Associated state and source-unused fields — exact 18-ID completion

The control/alias rows above cover four of the 18 IDs: font fallback,
spring crossfade, hide All and hideDividers; the shared rows add three.
The remaining eleven are disposed individually here:

| Original ID | Original role / source | Native disposition |
|---|---|---|
| `draweraccountpickerview.expanded` | DrawerAccountPickerView reads `accountsShown=true`, changes expansion height and saves it | Account switching uses the actual Settings account list (`PeerInfoSettingsItems`, accounts section) reachable from the permanent menu. That list is shown when opened; there is no second persisted drawer-account expansion flag. Native presentation adaptation, not an absent-account no-op. |
| `drawercontainer.lastDayTheme` | DrawerContainer.toggleTheme reads `themeconfig.lastDayTheme`, default Blue, validates day kind | Native selected theme/reference is persisted in PresentationThemeSettings.theme and edited by the real theme settings action. Android theme names are not copied as fake iOS references; drawer quick-toggle choreography is not asserted equivalent. |
| `drawercontainer.lastDarkTheme` | Same function reads lastDarkTheme=Dark Blue and validates night kind | Native automatic/night reference is PresentationThemeSettings.automaticThemeSwitchSetting.theme, consumed by updatedPresentationData and the real night-mode screen. |
| `iconpickerview.fabX` | IconPickerView.restoreFabPosition/saveConfig stores/clamps overlay x, default −1 | Native named-resource editor and UIDocumentPicker own placement; selected pack/resource is pinned before presentation. No floating inspector exists whose x could consume an imported Android pixel coordinate. Editor capability is partial to the mapped resource set. |
| `iconpickerview.fabY` | Same for overlay y, default −1 | Same native picker/list presentation, no inert y preference. This is a presentation adaptation, not a claim that draggable UIKit geometry is impossible. |
| `mainmenuhelper.channel_intro` | MainMenuHelper.presentChannelCreate reads/writes first-use `channel_intro=false` | Main Menu now uses the real PermissionController Channel intro → createChannelController flow, like native Compose. iOS shows the intro per entry; it does not persist a second Android first-run marker. |
| `nagram.customTitleUserName` | Default false; AppearanceConfig.migrateCustomTitle consumes true → titleText=2, then clears it | Canonical native appearance.titleText=2 already renders the account name. No independent legacy control. Android import/migration plumbing remains the import owner's boundary. |
| `nagram.folderNameAsTitle` | Default false; NaConfig field is referenced only by its old settings row | Source-unused raw boolean. The distinct live AppearanceConfig.folderNameAsTitle() derives from tabsTitleType==ICON; its native counterpart is now in ChatListControllerNode. No duplicate boolean is registered. |
| `nagram.strokeOnViews` | Declaration true; absent-key initialization stores performanceClass != LOW (false on LOW). ConfigCell row but no client renderer read found | Source-unused client field in the pinned tree, not proof of an unavailable drawing API. No inert native control/storage added. This classification is independent of SDK compatibility getters. |
| `nekodelegatefragment.view_animations` | Read of shared Android mainconfig `view_animations=true` selecting RecyclerView animator | Native grouped-list reload/presentation and system Reduce Motion govern this layer. No second helper-local setting; UIKit list presentation replaces RecyclerView animator state. |
| `regexfiltereditactivity.view_animations` | Another read of the **same** global slot, controlling immediate vs post-transition keyboard focus | Native regex editor uses actual ExteralessSettingsInput/UIKit focus. Android onResume/200ms transition focus scheduling is not duplicated; editor interaction remains real. No separate synthetic animation flag. |

`source-unused` above means no renderer consumer in the inspected pinned client
source; it does not make a claim about external plugin code. These are original
client field/state receipts, not the separate 44 SDK compatibility-storage getters.

## Android resource-base limits

The supplied `third_party/exteraless-android/TMessagesProj/src/main` contains
`java`, `kotlin`, `python`; it has no `assets` or `res` resource base. In source,
AppearanceConfig.monetAssetSuffix selects different token assets (`""`/`"_gram"`),
and TypefaceHelper opens Android font assets / probes Android system families.
Those Telemone/Classic asset palettes and bundled font bytes are not present here.
Native themes/colors and system fonts are real available alternatives, but not
evidence of exact `appearance.monetStyle` / `neko.typeface` selection parity. Their
receipt states remain scoped adaptations, not blanket unsupported UI APIs.

## Adjacent import-owner correction

`CloudLegacySettingsArchive.swift` still explicitly classifies
`icons.useSystemIconShape` as Android-only. The new native logo control makes that
blanket disposition stale. Cloud/import owner should remove that specific exclusion
and map the boolean to `appearance.useSystemIconShape`; legacy switch/slider slot 1
normalizes to 2 per AppearanceConfig.migrateModernStyles. No Cloud/SDK files were
edited by Appearance.

## Tests and remaining acceptance

- Five new `AppearanceOwnerCompletionTests`: explicit choices survive actual
  register/write/reopen/reset/reload; scope values, switch endpoint/drag geometry,
  slider exclusions, All recovery, native spring default and shared opacity policy.
- `AppearanceSwitchTests`: real native/vector backend switch and accessibility
  value callback with disabled-state rejection, using real typed definitions.
- Presentation revision tests also cover separator suppression without mutating
  the native palette and restoration of its original color objects.
- All are authored source fixtures; no Swift/native run is claimed on Windows.
- `appearance-build-handoff.patch` supplies four missing Core edges and the actual
  Switch XCTest target on the existing native runner/host. The AP test targets
  have already been added by the coordinator; see `appearance-remediation.md`.
- Required frames: switch 0/2/3 off/on/drag/cancel/RTL/VoiceOver; slider native/M3 and
  custom geometry; title scopes and long titles; logo toggle and launcher-icon
  failure; folder mode/header/VoiceOver and All-chip recovery/reordering; all four motion modes and crossfade
  release/cancel/caught push. AP frame scenarios remain mandatory.

Final original-ID fragment and read-only check results are updated in
`appearance-parity.json` / `appearance-remediation.md` at the final checkpoint.
