# Appearance phase 2 — final source handoff

Continuing after the coordinator applied the first appearance hunks. Source-only;
no CI/commit/push, external plugins, network probes or visual-pass claims.

**Current source handoff:** [appearance-remediation.md](appearance-remediation.md)
closes AP-01…AP-11 in source; [appearance-owner-completion.md](appearance-owner-completion.md)
covers the remaining controls/state IDs. The receipt now contains **78 original
IDs + module.appicons**: 15 implemented, 58 partial, 2 unsupported,
3 compatibility-storage; all `ported=false`. All **56 active typed keys** have
native consumer receipts. Three Settings definitions await their shared hook.

Latest supplied initial green base: CI **43693106297**, **b1424e10**,
280 Core + 89 Host + 16 Hooks. It predates the AP/completion fixtures and does not
certify this native source. Native compilation and recorded frames are pending on
the coordinator's Mac/Xcode 27.1 graph.

Reserved appearance seams in this subwave (chat owner is restricted to input/media
by the coordinator's steering):

- `ChatListUI/ChatListController.swift`: menu/download header and floating compose.
- `ChatListUI/Node/ChatListItem.swift`: sender avatars, media-preview and bot-button gates.
- `ChatListUI/ChatListControllerNode.swift`: idle-search and story-strip gates.
- `ChatListHeaderComponent/ChatListTitleComponent.swift`, `ChatListTitleView`: title layout.
- `PeerInfoScreen/PeerInfoHeaderNode.swift`: avatar-background blur and elastic geometry.
- `ActivityIndicator`, `GlassBackgroundComponent`, `NavigationBarComponent` and
  `TabBarComponent`/`TabBarUI`: unique presentation variants.
- New `AccountContext/ExteralessAppearanceEntry.swift`: cycle-free menu factory.
- New bounded snow renderer and route registry in appearance-owned files.
- `ChatControllerNode.swift`: wallpaper snow and header fade only.
- `Display/NavigationTransitionCoordinator.swift`: latched background parallax;
  the completion pass also adds native tap/release/reverse motion choices.

AppDelegate, ChatController, TelegramRootController and shared CoreSettings UI
remain coordinator-owned. Further hunks and dependency additions are recorded
here as the implementations land. No input/media/chat-message service edits are
planned by this role.

## Root deeplink hunks — already installed

The permanent menu factory is now live in the actual root ChatList header. The
menu itself has a real Settings destination even if the tab or entire bar is
hidden. The root-tab filter's existing callsites automatically pick up the new
Settings filtering; the helper signature is unchanged. AP-02 uses the actual
PeerInfoScreen protocol, and AP-03 reapplies after ready-root installation.

The following reference hunks are already present in `TelegramRootController.swift`:

```diff
@@ public func openContacts()
-        if let index = rootTabController.controllers.firstIndex(where: { $0 is ContactsController }) {
+        if !exteralessRootTabsAreHidden(), let index = rootTabController.controllers.firstIndex(where: { $0 is ContactsController }) {
             rootTabController.selectedIndex = index
         } else {
             self.pushViewController(ContactsController(context: self.context))
         }
@@ public func openSettings(edit: Bool)
-        if let index = rootTabController.controllers.firstIndex(where: { $0 is PeerInfoScreenImpl }) {
+        if !exteralessRootTabsAreHidden(), let index = rootTabController.controllers.firstIndex(where: { $0 is PeerInfoScreenImpl }) {
             rootTabController.selectedIndex = index
+        } else {
+            exteralessOpenSettingsFallback(context: self.context, navigationController: self, edit: edit)
+            return
         }
```

No new imports. Callees are in `ExteralessTabNavigation.swift` and
`ExteralessMainMenuRegistry.swift`. The persistent hiding policy is independent
of native transient search hiding, through
`TabBarControllerImpl.updateExteralessTabBarHidden(_:transition:)`; closing search
cannot unhide a user-hidden bar, and resetting the preference cannot reveal a bar
that search still hides. The native API now honors its requested transition.

## Extensible routes API

`@MainActor ExteralessMainMenuRegistry` exposes:

```swift
public static func register(_ routes: [ExteralessMainMenuRoute]) throws
public static func unregister(ids: Set<Int>)
public static func registerSettingsAction(id: Int, title: String, actionId: String) throws
// ExteralessMainMenuRoute(id:title:isAvailable:action:)
// isAvailable: @MainActor @Sendable (AccountContext) -> Bool
// action: @MainActor @Sendable (AccountContext, ViewController) -> Void
```

Preserved original IDs are no longer discarded when a provider is temporarily
absent. New providers notify presentation and their saved ordering/visibility is
used immediately. `111` (kill app) is explicitly rejected, never a success no-op.
Bots/apps ID `105` opens the real native Apps search pane. This is an iOS routing
adaptation rather than an Android side-menu-bot expansion; a domain can replace
the handler with a more specific native picker through the registry.

Native routes now include profile `18`, browser `101` (real BrowserScreen with a
blank initial page, no unsolicited homepage request), QR `17` (native validated
scanner + inspect/copy/open result, **not** an automatic login approval), recent
chats `108` (native empty-search recent list), wallet `109` (only while actual
`context.walletContext` exists; the native constructor otherwise traps). Feed
`106` and Ghost `107` bind the actual existing `chats.feed` / `privacy.ghost`
settings actions dynamically, with no private controller dependency. Other owners
can override/replace those handlers through the same registry.
Action-registry updates also invalidate the menu, so a provider loaded/unloaded
while it is open changes visible routes without losing persisted positions.

## Connected portable effects

- Mini avatars: `ChatListItem` resolves the peer named by the native preview,
  including resolved saved/forwarded authors, and skips name-only imported authors,
  self/drafts/absent
  names, reserves 22pt for an 18pt avatar, and handles the author row and inline
  forum-author preview. The avatar is parented to the relevant text node so typing
  fades and topic extraction remain coupled; disabling removes it and restores
  layout space. Actual Android span reference: `DialogCell.addSenderAvatar`.
- Center title: actual ChatListTitleComponent/ChatListTitleView, action-safe lane,
  persistent alignment across internal relayouts, long-title/status padding.
- Header status hiding now covers chat-list, chat and profile headers. Emoji and
  Premium status are filtered; verification/fake/scam indications retain native
  behavior.
- Profile blur: real profile actions, scroll-edge and Dynamic Island avatar-cover
  blur APIs, never thumbnail
  decoding. AP-07 makes the elasticity switch govern the complete expanded
  center/scale/header/clip geometry, including landscape viewport coverage.
- Downloads: actual header button calls `activateSearch(filter: .downloads)`.
- Additional native row/header gates preserve original defaults:
  `hideStoriesFromHeader=true`, `hideDialogsSearchField=false`,
  `mediaPreview=true`, `disableBotOpenButton=false`. Story layout/expansion uses
  the same predicate; active search keeps its field and has an independent menu
  fallback; thumbnail/button removal restores the existing row's layout space.
- FAB: native floating 56pt compose action, square radius `ceil(side*16/56)` vs
  circle; native header compose is restored by the original
  `nagram.disableDialogsFloatingButton` option. Search/edit/preview suppress the
  floating action. The controller, not the button, owns safe-area geometry.
  Search cancellation explicitly requests layout after clearing its active state.
- Snow: fixed maximum 8 header / 32 wallpaper Core Animation layers, no display
  links or per-frame allocation. Noninteractive and hidden from accessibility;
  removed off-window, in background, Reduce Motion or Low Power. Chat snow is below
  messages, in ChatControllerNode's real wallpaper. No input/media edits.
- Loading: actual `ActivityIndicator` switches between native, legacy custom and
  bounded Material arc/track. Native fallback now mounts navigation indicators
  correctly and scales only their view, not the whole node. Hidden/off-window
  indicators stop; Reduce Motion makes the Material shape static.
- Glass: Glare preserves stock UIGlass/legacy rendering; Solid and Hidden use
  public UIBlurEffect + uniform stroke or no stroke. No global UIKit appearance
  mutation. Menus use actual LensTransition/ContextController action backgrounds;
  off makes them opaque without replacing actions or pan/dismiss handlers.
- Chat header: follows the actual `ChatHeaderUiHelper` intent — no center glass
  pill, avatar enlarged by 4pt within iOS's 44pt control, extra 30pt top fade.
  Native zero/default values restore prior geometry. Android absolute 42→46 avatar
  dimensions adapt to iOS 38→42 to keep the tap/neighbor frame intact.
- Navigation: floating default, wide native capsule (uncapped width / 8pt sides),
  and real full-width Material surface including home-indicator inset. Material
  selection is bounded to 56×32, y=6 with labels, centered without, per
  MainTabsUiHelper. Tap/drag/context routing is retained; Material uses a native
  chip instead of the liquid-lens rendering path. Wide/Material precedence is pure
  policy, tested independently. Vertical/Duo layout stays in its native strip.
- Drawer: native side panel, swipe/cancel/fling and outside dismissal, fixed
  header and list move in one parent transform. Immersive mode scales a passive
  snapshot, not the live root; no screenshots persist or leave the process.
  Rotation/snapshot appearance remains a required frame check.
- Predictive-back intensity: native adaptation to **latched** stack parallax
  percentage, 100% exactly preserves the prior 0.3 factor. A single screenLayout
  feeds live drag, baked screen/bar/keyboard timelines, release and cancellation.
  It applies to push/back together so a caught push cannot jump to another factor;
  flat modals/profile expansion and commit thresholds remain native.

## Build owner additions

Current precise remaining additions: `appearance-build-handoff.patch` (four
Core dependency edges and real Switch XCTest ownership). The coordinator has
already added the AP Avatar/Presence/Presentation/Root/Glass test targets.
No BUILD/MODULE edits were made by this owner. Original phase-2 dependency list:
Add Core dependency where newly directly imported:

- `//submodules/ActivityIndicator:ActivityIndicator`
- `//submodules/TelegramUI/Components/ChatListHeaderComponent:ChatListHeaderComponent`
- `//submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen:PeerInfoScreen`
- `//submodules/TelegramUI/Components/GlassBackgroundComponent:GlassBackgroundComponent`
- `//submodules/TelegramUI/Components/ContextControllerImpl:ContextControllerImpl`
- `//submodules/TelegramUI/Components/ChatTitleView:ChatTitleView`
- `//submodules/TelegramUI/Components/Chat/ChatAvatarNavigationNode:ChatAvatarNavigationNode`

Display, ChatListUI, TelegramUI, TabBarUI and TabBarComponent already needed Core
from the first wave. LensTransition only uses its existing GlassBackgroundComponent
dependency. AccountContext's new ExteralessAppearanceEntry needs no Core/TelegramUI
dependency. The native menu imports BrowserUI, QrCodeUI and PeerInfoScreen in
TelegramUI; expose existing target dependencies if not already direct.

## Tests and required visual acceptance

New Foundation fixtures: `AppearancePresentationPolicyTests` (9 tests) cover
sender eligibility, finite action-safe lanes, actual FAB ratio and elastic reset,
search-vs-persistent tab visibility sequence, exact Material chip geometry and
variant precedence, parallax no-gap bounds, bounded deterministic snow and system
constraints, drawer cancel/fling/narrow widths, and late-provider menu persistence.
Swift/XCTest execution still requires the coordinator's Mac lane; no visual or
runtime test is claimed on Windows.

Before capture, expected frames:

1. All author/name/mini-avatar nodes remain aligned through list updates, typing
   fades, topic extraction and reset; no text under the 18pt image, no draft/self
   image, no extra line-height jump or lost topic tap.
2. On narrow phones and Duo, permanent menu + Downloads never overlap the title;
   FAB stays above the real bottom inset and away from reserved corners, vanishes
   in search/edit and returns afterward. Header compose returns when FAB is off.
3. Drawer header/list travel together; cancellation returns to rest, fling closes
   once, vertical scrolling never becomes a close gesture. Test interrupting its
   opening animation, rotation, RTL, large text, Reduce Motion and account switch.
4. Glass modes visibly differ on iOS 15 and 26/27. Switching back restores glass,
   content/action hit areas stay stable, nested menus/popup dismiss still work.
5. Material/wide/floating tabs: tap, drag, context extract, labels hidden, live
   unread badge, landscape, search collapse and reset. No duplicate icons, lingering
   lens, gaps around home indicator, or body/header mismatch on hide/unhide.
6. Profile blur/elastic and chat-header variant: expand/collapse, pull, video avatar,
   stories and back-to-chat morph. Titles/actions remain readable; no crop/scale
   discontinuity or glass-pillar fragment after toggles.
7. Snow disappears when backgrounded/off-window/system-limited; remains below
   bubbles and never intercepts touch. Material loading stops when hidden and
   resets to the actual native/custom renderer.
8. Navigation intensity 0/100/200: push, normal/cancelled swipe, caught push,
   keyboard and bars together; no uncovered gap, mismatched sampled timeline or
   altered commit threshold. Profile expansion/flat modals preserve their behavior.

9. Toggle idle search/story strip/inline bot action/media thumbnails on a populated
   list. Removed content leaves no empty height or text cutout. Open Search from
   Main Menu with its optional Recent Chats provider unregistered; cancel returns
   to a working header/FAB. Restore defaults and repeat with a draft and a bot row.

## Final source review and checks

Fixes made during this subwave's review:

- Corrected the Material tab host to the actual `ContextControllerSourceView`
  API (`addSubview`, not a nonexistent `contentView`) and added the missing
  `SettingsUI` import for `SettingsController`.
- Reserved title space for activity/lock/status and bounded hit-testing to the
  action-safe lane. Extremely narrow lanes hide the title instead of overlaying
  controls; leading alignment respects RTL.
- Mini avatars follow the peer actually displayed in the preview. Name-only
  imported authors do not borrow an unrelated sender's image.
- Video-avatar/story contours use the raster cache's resolved corner fraction,
  avoiding a second rounding at navigation size. Explicit unclipped avatars stay
  unclipped. Material-tab search collapse uses 48pt content geometry, and bottom
  material fill stays above swapped child screens.
- Native/custom loading backends are created lazily; hidden material animation
  stops on lifecycle changes. Glass alternatives retain custom surface tint.
- Menu factory holds the account weakly, checks its identity and invalidates
  presentation on attachment. Old drawers/QR completions cannot navigate after an
  account replacement. Stored extension-route IDs survive provider unregistration;
  unavailable rows are informational until their provider returns.

Historical phase-2 read-only checkpoint (superseded by the final check table in
`appearance-remediation.md`):

| Check | Result |
|---|---|
| Real `tools.compat.feature_inventory.merge_parity` with this fragment | **PASS**, 60 original IDs + module |
| Source paths, line bounds and explicit symbol anchors | **PASS**, 203 references |
| Definition/receipt join | **PASS**, 48 unique typed keys, each has a source consumer receipt |
| `PostboxImportCheck.py` | **PASS** for the then-current whole checkout |
| Owned-path `git diff --check` | **PASS** |
| Core import declaration audit | No appearance-owned missing edge; whole checkout has 12 other-owned missing declarations and one unresolved test owner |
| Swift/XCTest, native build, recorded frames | **Not executed for this WIP** |

Import audit command: `python -B tools/runtime/check_bazel_imports.py --module
ExteralessCore` (6713 files / 257 imports in that snapshot; declaration audit,
not Bazel analysis). Build-owner remaining targets: EntityKeyboard,
ChatScheduleTimeController, ChatEntityKeyboardInputNode, TelegramCoreTestsLib,
OpenInExternalAppUI, LocationUI, LocationResources, Emoji and
ChatSendMessageActionUI. FeedNativeOrchestrationTests lacked an explicit source
owner. Other owners are working concurrently, so these are snapshot findings.

## Parity reconciliation for coordinator

`appearance-parity.json` is authoritative for `utils.predictiveBackIntensity` and
its actual key **appearance.predictiveBackIntensity**. Tools now records it under
`delegated_features`; its obsolete pending feature row has already been removed.
The duplicate Appearance `general.crashReports` record has been removed; Tools
owns its real MetricKit/manual-export adaptation.

At the historical phase-2 checkpoint the full unfiltered fragment merge failed on
other-owned conflicts:
`nagram.showTextTranslate` (AI/Chat), and Chat/Feed overlap for
`chats.wideFeedPosts`, `feed.addNewChannels`, `feed.excludedChannels`,
`feed.includeArchived`, `feed.knownChannels`. Reconcile owners/keys rather than
silently dropping either implementation. Current staged reconciliation belongs
to the coordinator; no new combined-merge pass is claimed here.

## Remaining work after stitching

1. Apply `appearance-owner-common.patch` for Help/Premium/Stickers and
   `appearance-build-handoff.patch` for the final dependency/test edges. Root
   deeplinks and the coordinator's serial settings worker are already in source.
2. Build the full native graph, run the bounded Appearance/TextFormat/native
   fixtures, then record the frame scenarios here and in `appearance-remediation.md`.
3. Exact Monet token assets, Android font-family assets, forced device mode,
   line/cache loading variants and the documented native-rendering differences
   remain partial. See the per-ID receipt for their precise scope.
4. All 18 associated-state receipt gaps and all five old pending rows are now
   individually covered in `appearance-owner-completion.md` and the 78-ID fragment.
