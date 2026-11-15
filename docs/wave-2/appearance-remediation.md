# Appearance review remediation — AP-01…AP-11

Tracking fixes to the read-only independent review `reviews/appearance.md`.
The 280-Core initial green base predates these regression fixtures. Windows has
no Swift/Xcode toolchain; source checks will be recorded separately from native
execution and frame acceptance. No account/network fixture, CI, commit or push.

Authorized shared edit: the single Appearance ready callback inside
`ExteralessClientRuntime.accountPresentationDidBecomeReady(context:)`. Root tab
composition, AppDelegate, PrivacyExtras readiness and Identity-owned formatting/
video eligibility remain composed through their existing APIs.

## AP closure matrix — source fixed, native execution/frames pending

Paths use `S = telegram-ios/submodules`, `U = S/TelegramUI`,
`C = swift/ExteralessCore`.

| Finding | Source closure | Regression fixture |
|---|---|---|
| AP-01 | `AppearanceFeatures.ignoreUnreadCount` defaults to **1**; `AppearanceFolderPolicy.defaultUnreadMode` supplies 1 to the actual `chatListFilterItems` fallback. Explicit 0 is not migrated. | `C/Tests/ExteralessCoreTests/AppearanceRemediationTests.swift`: real ClientSettings fresh/unregistered → register → explicit All → reopen → reset → reload; 30/7 aggregates. |
| AP-02 | `ExteralessTabNavigation.exteralessIsSettingsRootTab` tests **PeerInfoScreen.Type**, the protocol actually implemented by PeerInfoScreenImpl. Both root rebuild callsites use that filter. The existing Feed replacement call is retained. | `U/Tests/Appearance/AppearanceRootTabsTests.swift`: actual PeerInfoScreenImpl/ContactsController metatypes; retained Feed/Calls identity and Chats-selection fallback. Full root-controller frames remain required. |
| AP-03 | The authorized single call `appearance?.rootDidBecomeReady(context:)` runs inside `accountPresentationDidBecomeReady`, after its current-context guard and before PrivacyExtras publication. `AppearanceRootApplication` repeats same-account applies and rejects old/detached accounts. It does not use `update(context:)`'s early-return path. | Core remediation fixture drives callbacks-before-mount and mount-before-callbacks, account replacement, stale ready and clear with the production attachment dispatcher. |
| AP-04 | `PeerInfoAvatarTransformContainerNode` deliberately still loads `.none`/`storeUnrounded:true`. The owner resolves one style/fraction and applies it to final content/video/markup clipping and StoryPresentationParams; the existing expansion loan reads the same `cornerFraction`. `PeerInfoHeaderNode` resolves before collapsed clipping; square collapse still finishes when radius is already zero. | `S/AvatarNode/Tests/AppearanceAvatarRenderingTests.swift`: real final-clip API, source-size fraction at 38/60/100/200pt, round/forum/singleRadius, 28→14→0→28; original UIImage bytes retained. |
| AP-05 | ChatList video's layout reads **avatarNode.resolvedClipStyle**, after the actual raster/V2 setter, rather than width/2. V2 resize, explicit bubble mask and video frame use the same already-resolved shape. Cached video is updated after the photo setter and on layout/visibility changes; first asynchronous image delivery has a captured nonzero display size. Composes with current Identity/energy eligibility. | Same native fixture checks shared final image/video layer radius and rejects second rounding (60pt source → 38pt output gives 9.5pt, not 10). Video decoding/first frame awaits native offline harness. |
| AP-06 | All AvatarNode setter paths invalidate the story component even with identical stats/frame. Actual custom-letter/V2 shape is exposed; forceRoundedRect respects singleRadius and explicit owner fraction. Navigation passes the rounded flag explicitly. Normal/definite/indefinite rings use one `contourPath`; noncircular loading moves dash phase, not the contour. | Native Avatar fixture changes same letters/stats/frame, toggles forced-forum/singleRadius, and inspects real ComponentView loading masks through both modes and cancellation. |
| AP-07 | `AppearanceProfileAvatarGeometry` supplies effective offset, center, scale, header height, clipping frame and content translation to the actual profile hierarchy. Off pins the whole expanded viewport. Positive landscape translation stays inside a clip starting at/before y=0. | Core remediation fixture projects the actual parent chain for 390×488, 844×390, 1024×1280 at 0/50/100pt; checks photo **and clipping** coverage, return, toggle and reset. |
| AP-08 | Tint view/mask, outline and older-iOS blur/mask get the same sampled bounds/position/path timing for uniform and four-corner shapes. Ordinary updates use ComponentTransition. `cancelShapeAnimations` includes masks and bounds.size; expansion catch/end and platter removal invoke it. | Extended real `NavigationExpansionTransition/Tests/GlassShapeKeyframesTests.swift`: real Appearance definitions/store, modern/legacy, modes/opaque, every sample/timing/path, asymmetric corners, ordinary path animation, cancel and Glare restore. |
| AP-09 | Appearance/Identity revision is removed from the theme-loading mapToSignal input. `exteralessAppearancePresentationData` combines one native subscription with revisions on main, creates a new immutable theme/cache identity and recomputes date-format snapshots. Revisions do not re-read/decode an unchanged theme. Existing native-theme replacement/disposal remains in the signal chain; no detached publication tasks. | `S/TelegramPresentationData/Tests/AppearancePresentationRevisionTests.swift`: one native subscription, successive revisions, latest native theme, fresh cache/shared immutable palettes, main-thread delivery and disposal. |
| AP-10 | Both older Gregorian known-presence branches compose date **and** `stringForMessageTimestamp`, including seconds. The existing Persian early return is retained. | `S/TelegramStringFormatting/Tests/AppearancePresenceTests.swift`: today/yesterday/two-days/other-year, 12/24h, seconds on/off/reset, expanded, Persian fast path and privacy buckets through real public native functions. |
| AP-11 | Both yesterday activity/story calls pass actual `tm_sec` when Show Seconds is enabled. Short relative hours stay relative. | Same presence fixture calls both public activity functions; checks `:47` and its removal when false. |

### Fixture boundaries and build-owner work

Twenty-two additional methods are authored since the initial source base: four
Core remediation, five Core completion, three Avatar, three Presence, two
Presentation revision, two root/type-composition, two added to the Glass suite and
one real Switch backend/accessibility test. They have **not been executed here**.
They create only local temporary settings files and native value/view objects;
there is no Account, logged-in session, network request or synthetic replacement
framework declaration. Glass/Avatar accept a real injected ClientSettings store;
production defaults still use `.shared`.

The coordinator has now declared these real native test targets:

- `//submodules/AvatarNode:ExteralessAppearanceAvatarTests`
- `//submodules/TelegramStringFormatting:ExteralessAppearancePresenceTests`
- `//submodules/TelegramPresentationData:ExteralessAppearancePresentationTests`
- `//submodules/TelegramUI:ExteralessAppearanceRootTests`
- `//submodules/TelegramUI/Components/NavigationExpansionTransition:ExteralessGlassTests`

`appearance-build-handoff.patch` supplies the remaining Core edges for
SwitchComponent, SliderComponent, NavigationBarComponent and
ChatListFilterTabContainerNode plus Switch's real test source/target ownership.
Core's normal source/test globs include all 13 Appearance sources/five test files.

Use the coordinator's **Mac/Xcode 27.1** graph and available pinned simulator
runner; the old 26.5 runner strings are not a claim of a usable local runtime.
Build first, bound subsequent XCTest execution. BUILD/MODULE files were not edited
by this remediation role.

### Checks completed at the AP source checkpoint

- Owned remediation `git diff --check`: passed.
- Whole-checkout `PostboxImportCheck.py`: passed at this checkpoint.
- Swift/XCTest/native/frame verdict: pending. The earlier 280-Core green base is
  not evidence for these fixtures or final consumer changes.

### Required frames after tests

1. AP-02/03: real ready root, both callback orderings, persisted hiding, Feed/Calls
   callbacks, account replacement; the **first resting frame** obeys preferences.
2. AP-04…06: normal/forum photo, placeholder and video; 28→14→0→28 and singleRadius;
   unchanged story data/frame, loading/cancel and chat↔profile expansion. No old
   circular crop, detached video corners or rotating square outline.
3. AP-07: expanded pull 0/50/100pt in portrait/landscape, live toggle and reset.
   Off pins a fully covered viewport; on preserves portrait stock coverage and
   covers the landscape clipping viewport. Check positive scroll/collapse too.
4. AP-08: Solid/Hidden/opaque/Glare, modern and forced legacy, uniform and Duo
   asymmetric radii; grow/shrink, ordinary transition, catch, cancel and restore.
   Effect, fill, stroke and mask must follow the same samples/phase.
5. AP-09: a real local/cloud file-backed theme with rapid appearance/Identity
   changes and account replacement. Confirm no theme file/decode task is restarted
   by a cheap revision and no disposed lifetime is published.

Record with `simctl io recordVideo`; use ffprobe PTS and labelled frame/track
sheets per AGENTS.md. Model calculations above are not frame measurements.

## Identity shared seam — applied

Applied only the three assigned sections from
`docs/wave-2/identity-shared-remaining.patch`, as targeted edits over AP geometry:

- `ChatListItem.swift`: all 32 nonblank addition-line markers (27 supplied diff hunks). Account-scoped list/author/
  accessibility/topic titles, projected emoji/Premium badges, activity-band image
  and presence visibility, and the video-eligibility gate. AP final clip, resolved
  dimensions, thumbnail and sender-avatar geometry remain in place.
- `AvatarNode.swift`: all five addition-line markers (one supplied diff hunk). Context/account projection
  supplies letters and name colors to cache identity and draw parameters. The
  injected appearance policy, V2→legacy cleanup, `.none` handling and story shape
  invalidation were retained instead of applying the patch's old context body.
- `PeerAvatar.swift`: all five addition-line markers (three supplied diff hunks). Account wrapper passes the
  projection to fallback initials/colors; requested native `font`, clipping and
  unrounded-image forwarding remain intact.

Read-only comparison against the supplied added lines passed for all three
sections. Helper APIs are present; native compilation is still pending. Runtime,
ChatController and ChatListController sections of that shared patch belong to
App/Chat/Feed and were not applied by this role.

## FROZEN Core checkpoint for the next coordinator CI

The four early AP pins below remain unchanged. The final **18-file Appearance Core
snapshot is FROZEN** in `appearance-core-frozen.sha256`, including the completed
additional policies/tests and current 56-key definition assembly. This is source
readiness, not a new test pass. The single definition append in
`appearance-owner-common.patch` is a pending coordinator integration delta: if
applied with its native hook, refresh the affected pin before attributing a CI run
to that newer snapshot. Raw SHA-256 for the original AP checkpoint:

| File under `swift/ExteralessCore/` | SHA-256 |
|---|---|
| `Sources/ExteralessCore/AppearanceRootApplication.swift` | `15ba4595be78cde6448a7cb9dd0e80f077695a4057dc3021719c8b1933a10a15` |
| `Sources/ExteralessCore/AppearanceProfileAvatarGeometry.swift` | `4f05da4fda33c76131d3f0a278578c1f8b857a3f71ff082b366dec148beee385` |
| `Sources/ExteralessCore/AppearancePolicy.swift` | `d4567162ca380943a69f7c8c420e8149da493c65dd493a37b00d737fc256e053` |
| `Tests/ExteralessCoreTests/AppearanceRemediationTests.swift` | `7a0fc3c6916df7190693e8af22543598d28c4ec4151b39e1ecfbf3dc0861c204` |

## Original-scope completion after AP remediation

All 18 exact missing IDs and five old pending rows from
`docs/parity/wave-2-reconciliation.md` now have individual consumers or source-backed
state/legacy dispositions in `appearance-owner-completion.md` and
`appearance-parity.json`. The fragment covers **78 original IDs + module.appicons**,
with **15 implemented / 58 partial / 3 compat-storage / 2 unsupported**, all
`ported=false`. Every one of the **56 active keys** has a consumer receipt.

Three partial native Settings controls still require the coordinator's paired
builder/registration hook (`appearance-owner-common.patch`). Other explicit visual
scope differences remain in the per-ID receipt. Global SDK compatibility-storage
getters are a separate scope.

The latest shared runtime now has `ExteralessClientSettingsWorker.prepare`: serial
configure/register/reload, followed by generation-checked main publication. The
old bootstrap-on-main handoff blocker is superseded in source; native proof is
still pending. Root deeplink guards and Tools' predictive-intensity delegation
are already installed.

## Final read-only source checkpoint

| Check | Result |
|---|---|
| Real `tools.compat.feature_inventory.merge_parity` | **PASS**: 78 original IDs + appicons; all 18 missing + five former pending IDs present. |
| Source references / active definitions | **PASS**: 290 path/line/symbol references; 56 unique active keys, all with native consumer receipts; unregistered legacy proposals no longer masquerade as active keys. |
| Identity shared-patch comparison | **PASS**: all 42 nonblank addition-line markers across the three assigned files (32 / 5 / 5). AP clipping/geometry and native-font arguments remain composed with those changes. |
| FROZEN Core snapshot | **PASS**: all 18 raw SHA-256 pins; the four early AP pins still match. |
| Scoped `git diff --check` + new-file whitespace | **PASS**; 28 new/owned Swift files also checked directly. |
| Whole-checkout `PostboxImportCheck.py` | **PASS** at this final source checkpoint. |
| `git apply --check` for both handoff patches | **PASS** against the current shared Settings/Core and BUILD preimages. This was a dry run. |
| Core import declaration audit | Appearance still needs four target dependency edges and Switch-test source ownership, supplied in `appearance-build-handoff.patch`. The audit is declaration-only, not a Bazel/native build. |
| Swift/XCTest/native build/recorded frames | **Pending** on the coordinator's Mac/Xcode 27.1 graph. The 22 added test methods are authored source, not executed results. |

Coordinator next: apply the paired Settings hook/registration and the build hunk,
then attribute Core/native runs to the resulting source pins. Cloud/import owner
also has the precise logo-shape/legacy-slot mapping note in
`appearance-owner-completion.md`. Independent AP and additional control frames
remain the acceptance criteria above. No CI, commit or push was initiated here.

## 2026-11-15 follow-up — AF-01…04 avatar backend remediation

This append supersedes the earlier 56-key/pending Settings-hook checkpoint.
`reviews/appearance-followup.md` independently source-closes AP-01…03/07…11 and
tracks the four remaining avatar-family findings as **AF**, separate from AI.
Both independent reports and previous handoff reports remain read-only.

User-supplied Core result: **595 passed**, CI **43711634580 / 9c409eb8**. The
coordinator has joined all three native Settings definitions: **59 active keys**.
Only the authorized `AppearanceFeatures.swift` append changed an old Core pin;
`appearance-core-frozen.sha256` now records
`ec7b61074fae6c89f54e7697f60d7780cd3a1f8e9c658ed78ad6a60155a99225` for that file.
The other 17 pins and Core source/test files are retained. This reported Core run
does not execute the new native avatar fixtures below.

### Source fixes and actual-node fixtures

All four new methods are in the existing
`telegram-ios/submodules/AvatarNode/Tests/AppearanceAvatarRenderingTests.swift`.

| Finding | Current implementation | New native fixture |
|---|---|---|
| AF-01 | Entering V2 suspends the real ASDisplayLayer (cancelling pending draw), clears parent parameters/contents and legacy image source, and enters `.image` state. Cached-image identity includes cache/peer/resource/size/shape; ready state follows the current load. Old queued image/unrounded publications cannot cross the image generation. | `testLegacyRasterAndQueuedImageCannotSurviveV2Reset`: actually draws a square legacy placeholder; queues a child ImageNode result and parent redraw; enters delayed V2, resets to round, changes font and drains old/current completions. Inspects parent contents/draw parameters and rendered corner alpha on the real AvatarNode. |
| AF-02 | V2 setup and resize both use `applyExteralessFinalClip`, including bubble. Old UIView mask is cleared, radius is reset, and one named, size-refreshed CALayer bubble mask supplies the contour. No parallel circular clipping or implicit mask resize tween survives. | `testV2BubbleReplacesCornerBackendAndResizesWithVideoContour`: actual cached AvatarNode, round/roundedRect→bubble→round/none, 60/38/100pt; compares its rendered mask with a decoded local-PNG video-frame plane using the native final-clip API. AVPlayer/decoder execution is not claimed. |
| AF-03 | `peerAvatarCompleteImage` resolves regular/forum/none once and carries the style to both decoded photo and fallback. The bool convenience API delegates to a resolved-style letters compositor that retains caller font and clips its glyphs. Full-size selection and optional blur use the same resolved contour. | `testCompleteImageKeepsForumContourFontAndUnroundedChoice`: real complete-image decoder/compositor, cached PNG versus no representation for regular/forum, 0/14/28, singleRadius both ways, forced empty representation, `.none`, two caller fonts and reset. Compares actual output alpha/pixels; no layer-only substitute. |
| AF-04 | `clearImageSource` increments the generation, disposes the old cache load and invokes actual **ImageNode.clearContents()**. V2→custom letters re-enables the legacy draw with no old child bitmap; legacy→V2 cancels the old ImageNode subscription as well. | `testV2ToLettersDisposesBothImageSourcesAndRejectsLateCompletions`: proves `.single(nil)` is a no-op for the real enableEmpty=false ImageNode, then checks real clear/disposal for `B` and space, pending cache/child results, and letters→new cached peer followed by an old completion. |

The injectable `AvatarNodeImageCache` contract has a shipping adapter on
**DirectMediaImageCache**. AccountContext and fake-cache calls enter the same
ContentNode V2 implementation. The complete-image data provider likewise feeds
the same public decoder/compositor used by the Postbox wrapper. Neither fixture
redefines a framework or duplicates a renderer.

Fixtures use two owned **8×8, 74-byte RGB PNGs**, real EnginePeer values, native
AvatarNode/ImageNode and cancellable SwiftSignalKit delivery. They construct no
Account/Postbox/network session and perform no live avatar fetch. Each queue
handoff/drain has a 1-second bound, with no fixture sleeps or timers. Run the
native suite under the requested **≤30-second post-build execution bound**.
These are authored fixtures; this Windows session has not executed UIKit/XCTest.

### IDSF contact initials — new delta applied

Applied all four hunks/five addition-line markers from
`docs/wave-2/identity-followup-avatar-letters.patch` onto the AF backend changes:

- Both context-bearing `setPeer` signatures now accept `overrideLetters`.
- The outer AvatarNode forwards it to ContentNode.
- The already-filtered override wins when supplied; otherwise the latest IDS02
  `.map { exteralessZalgoDisplayText($0) }` remains active.
- That same `displayLetters` array supplies the comparison key and both draw
  parameter branches. Cache/image generations, clipping and caller fonts remain
  in the current AF implementation.

The current contact helper already passes `overrideLetters: customLetters`; its
parameter contract is now satisfied in source. IDSF contact composition and live
presentation invalidation in other files were retained. The earlier initials
patch was not replayed.

### Native target handoff

The existing Avatar test source is already owned by
`//submodules/AvatarNode:ExteralessAppearanceAvatarTests`. Its new direct imports
need these coordinator-owned edges; BUILD was not edited by this role:

```diff
--- a/telegram-ios/submodules/AvatarNode/BUILD
+++ b/telegram-ios/submodules/AvatarNode/BUILD
@@ -41,6 +41,9 @@
     deps = [
         ":AvatarNode",
+        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
+        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
+        "//submodules/TelegramCore:TelegramCore",
         "//submodules/ComponentFlow:ComponentFlow",
         "//submodules/TelegramUI/Components/Stories/AvatarStoryIndicatorComponent:AvatarStoryIndicatorComponent",
         "//third-party/exteraless:ExteralessCore",
     ],
```

The three receipt rows now point to actual keys
`appearance.hideHelpSection`, `appearance.hidePremiumSection`, and
`appearance.showStickersRowToplevel`, with the installed native builder/helper
callsites. Their native execution/frame status remains partial and `ported=false`.
The remaining 75 feature rows were not reclassified by this follow-up.

The four changed avatar source/test files are pinned **FROZEN** in
`appearance-avatar-frozen.sha256`. Native build/fixture execution and recorded
frames remain pending. Before capture: no old parent raster or child photo may
survive a backend change; bubble tails survive round→bubble and resize; photo and
fallback have the same forum contour; late old results cannot replace current
letters/photo. Use the established simctl/ffprobe labelled-frame procedure for
acceptance. Offscreen XCTest pixel assertions are not recorded-frame evidence.

### Follow-up read-only checks

- **PASS:** isolated real `merge_parity`, 78 IDs + appicons, **297** source
  references, **59** actual keyed consumer receipts; all `ported=false`.
- **PASS:** all 18 Core pins after the authorized single-pin refresh; both
  independent reports retain their pre-edit raw hashes.
- **PASS:** new Identity delta's five added-line markers, both parameter
  signatures, forwarding and the filtered comparison/draw keys. V2 installs its
  request-owned disposable before `start()`, preserving a newer subscription if
  synchronous readiness delivery reenters the renderer.
- **PASS:** scoped `git diff --check` and whole-checkout Postbox import check.
- **PASS:** independent PNG signature, IHDR, CRC and zlib checks for both 74-byte
  fixtures; native-test dependency hunk matches the current BUILD in a raw-byte
  `git apply --check` dry run.
- Native compilation, the four new XCTest methods and recorded frames: **pending**.
  No CI, commit, push, Account fixture or live-avatar fetch was initiated here.
