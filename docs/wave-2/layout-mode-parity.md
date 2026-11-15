# Layout mode — `neko.tabletMode` native source handoff

**Root/Core/SDK binding is connected in coordinator source. PNP-01 keyboard
adoption is remediated in source; native execution/frames remain pending.**
Raw **0 Auto / 1 Tablet / 2 Phone**, default/reset **0**, use the real
key **`appearance.tabletMode`**. This controls application-root navigation panes
and navigation-managed modal geometry. It is not full Android hardware/tablet
semantics and is not `ported=true`.

Coordinator joined the Layout and Font registration/SDK/native-test deltas in the
published source cohort (user reference `4476f853`). This PNP-01 change is confined
to NavigationController, NavigationContainer, the content-layout helper and its
native tests. Core policies, field formatting, root registration and the accepted
avatar/ASC01 work are outside this edit.

## Original source

Root `A = third_party/exteraless-android/TMessagesProj/src/main`:

- `A/java/tw/nekomimi/nekogram/NekoConfig.java:39–40,89` declares Auto=0,
  Enable=1 and integer `TabletMode`, default 0.
- `A/java/org/telegram/messenger/AndroidUtilities.java:3009–3043` uses the raw
  selection in `isTabletForce`: nonzero is tablet only for 1; Auto uses the real
  resource flag. `isTabletInternal` caches it; `resetTabletFlag` clears the cache.
  `:3078–3079` sizes the left pane as inset + max(320dp, 35% of usable width).
- `A/java/tw/nekomimi/nekogram/settings/NekoGeneralSettingsActivity.java:218–222`
  gives Auto/On/Off in 0/1/2 order; `:322–323` shows a restart hint. That old row is
  removed from this particular page at `:296`; the live App Navigation page still
  writes the same raw integer (`OpenExteraAppNavigationActivity.java:322–327`).
- `A/java/org/telegram/ui/LaunchActivity.java:7529–7538` resets/recomposes on
  configuration changes. This is broader than the iOS content adapter.
- `A/java/com/exteragram/messenger/ExteraConfig.java:517–524` forwards
  `getTabletMode()` / `setTabletMode(int)` directly to this Neko ConfigItem.
  `EtgBackup.java:407` also constrains the portable selection to 0…2.

## Implementation and scope

### Pure policy / persistence

`swift/ExteralessCore/Sources/ExteralessCore/AppearanceLayoutModePolicy.swift`
contains the one typed definition, raw-value enum and finite viewport policy.
It is compiled independently of registering its definition.

- Auto returns a stock decision. Display passes no override to the existing
  `makeNavigationLayout`, retaining `.single` / `.automaticMasterDetail` and
  stock modal rules.
- Phone selects actual `.single`, even when system width class is regular.
  Adaptive `.modalInLargeLayout` pages join that stack; explicit modals use the
  full-window presentation.
- Tablet chooses actual master/detail when a **real `.master` controller** exists,
  usable master/detail widths are at least **320 / 360pt**, and at least **180pt**
  remain visible above the keyboard. The 35% preference is bounded by both lanes.
  A real vertical fold keeps its divider only when both sides fit; it is not moved
  to invent usable space. A minimized stack keeps the forced layout single.
- Otherwise Tablet retains raw **1**, using a single-pane fallback. It does not
  rewrite the stored preference to 0 or synthesize a zero-valued getter.
- Tablet groups `.modalInLargeLayout` as a modal when usable physical width and
  height are at least **600pt**. Sheet geometry additionally needs 320pt of content
  plus 24pt margins per edge above the keyboard. Oversized preferred sizes are
  bounded. If the keyboard consumes that space, the same modal becomes full-screen;
  keyboard movement alone does not demote it into the root stack.
- Active divisions disable centered sheets. Safe/status/intrinsic insets and
  reserved-corner side lanes constrain geometry. Small windows never get a forced
  negative-width split or oversized centered sheet.

`AppearanceLayoutModePolicyTests.swift` has four offline tests: actual typed-store
register/write/reopen/reset and invalid-value rejection; pane/frame invariants
over viewport/keyboard combinations; divider/master/minimized constraints; bounded
preferred sheet sizes and malformed numeric input. Raw choice survives fallback.

### Native consumer and live handoff

`telegram-ios/submodules/Display/Source/Navigation/NavigationContentLayout.swift`
maps the **incoming ContainerViewLayout** to that policy. Geometry uses the
current container/window layout, not `UIScreen.main`, UIDevice or fabricated
traits. `deviceMetrics`, `metrics.widthClass/heightClass`, orientation and
`metrics.windowSize` are carried unchanged to native children; pane/sheet safe
areas and keyboard intersection are derived by the existing containers.

Only `NavigationContentLayoutRole.applicationRoot` accepts
`NavigationController.updateContentLayoutMode(_:)`. Auxiliary navigation
controllers remain unmanaged. The root's actual tab controller already has
`navigationPresentation = .master`; no class-name heuristic assigns that role.

The native `makeNavigationLayout` uses its existing `.single` and
`.automaticMasterDetail` branches. `NavigationSplitContainer` consumes the
bounded master width; its scroll-to-top targets use that same width.
`NavigationModalContainer` consumes the bounded sheet frame or full-screen
fallback without changing hardware/trait metadata.

Live mode or container-ownership changes retire the previous native containers
before reparenting the **same `_viewControllers` objects**, in the same model
order. The mode API does not call setViewControllers or recreate a chat:

- Uncommitted edge/expansion gestures are cancelled through the native transition
  path; running transitions land, clocks/keyframes/borrowed glass are released.
- Retired ready subscriptions, removal callbacks and modal gesture callbacks
  cannot reparent/pop a controller after handoff. Model removals already committed
  by navigation stay removed; a presentation-only modal dismissal that has not
  removed its model entry is cancelled by a layout handoff.
- Keyboard horizontal animation is superseded at its real manager. Retained
  controllers take a generation-scoped adoption token instead of fresh-push
  keyboard suppression. A real responder/selection is restored only for the same
  surviving controller/window, followed immediately by current-layout reconciliation.
- Normal pushes/pops whose retained controllers stay in the same containers keep
  their normal timelines. Reentrant mode requests coalesce on main and apply the
  latest raw value, while the previous-layout record keeps the mode actually used.

The new UI-owned `ExteralessAppearanceLayoutModeBinding.swift` observes the real
ClientSettings key, weakly references the root and cancels its observation on
deinit. The root constructor binding applies cached state before first layout;
the existing settings worker has already registered the Appearance assembly at
that point. Other Appearance/Feed/Identity lifetime bindings remain independent.

## Original coordinator deltas — joined

These files record the original integration hunks. The current source has the
root binding, definitions, SDK keys and native targets; they are not pending PNP-01
work:

1. **`layout-mode-registration.patch`**: append
   `AppearanceLayoutModePolicy.definitions` to AppearanceFeatures. It changes the
    original 59-key assembly to 60; subsequent Font/Monet joins are separate cohorts.
2. **`layout-mode-root.patch`**: opt the actual TelegramRootController into
   `.applicationRoot` and retain its new binding immediately after `super.init`.
   Existing worker registration and AppDelegate root creation already supply the
   required preparation/first-layout ordering.
3. **`layout-mode-native-tests.patch`**: direct test dependencies and the bounded
   `//submodules/Display:ExteralessLayoutModeTests` target using the coordinator's
   shared native runner/host on the Mac/Xcode 27.1 graph. Source/test globs already
   cover the new Core and Display production files.
4. **`layout-mode-sdk.patch`**: teach the real Config generator the new, explicitly
   registered declaration group; remove this feature's obsolete blocked
   disposition; extend the existing Config binding fixture with 0/1/2 read/write
    and missing-registration failure. The current generated bindings contain
    `appearance.tabletMode` and `appearance.useSystemFonts` with real registration
    evidence. The Layout and Font native targets are also declared by the build owner.

Shared Root/ClientRuntime/AppDelegate, existing Appearance registration, BUILD,
SDK generator/manifest/tests and primary inventories were not edited by this PNP
remediation. The legacy tablet-mode read/write routes use the actual integer key.

## Native fixtures and required proof

`telegram-ios/submodules/Display/Tests/AppearanceLayoutModeTests.swift` contains
eight native cases, using real Display objects and the real `makeNavigationLayout`:

1. Auto vs stock maker, `.single` on regular width, explicit root-role isolation,
   and ordinary pushes retaining container ownership.
2. Compact portrait, compact landscape, split windows and keyboard cutoffs with
   actual `.master` / detail / `.modalInLargeLayout` classifications.
3. Real NavigationController 2→1→0→2 recomposition: controller identities, retained
   draft marker, top chat, pop/back stack and actual delivered layout metadata.
4. A real old NavigationContainer with a held back gesture, then handoff; late
   gesture/removal/ready callbacks cannot replace the new stack or steal its node.
5. Real NavigationModalContainer frames with an oversized preferred size and
   keyboard; small-window full-screen fallback and retired-drag rejection.
6. Actual UITextField and UITextView first responder/selection, inset 500,
   Auto→Phone→Tablet→Auto, including a real resign/become cycle; every adoption
   delivery is checked immediately, before another event or layout notification.
7. Delayed readiness, pending Phone→Tablet→Phone, and an owned UIWindow resize;
   publishing ready must finish with the current viewport/inset and restored
   selection before `Promise.set` returns. Old owner callbacks cannot pop it.
8. A genuinely fresh push retains its native nil-keyboard initialization; a popped
   pending controller's old ready cannot mount it or take input focus.

No Account, live UI, live service, simulator action or CI is used by this source
session. Swift/UIKit execution is unavailable on this Windows host. The new tests
are authored, **not passed results**. On Mac, build first and bound the new Core
and native fixture execution to **≤30 seconds**; Bazel's `short` classification
alone is not a 30-second bound. The former Core green does not cover these files.

## Expected frames matrix — recorded acceptance pending

Examples below use the fixture's real inputs: safe left/top/right/bottom
**20/24/32/20pt**, no active division, a proper master controller, no minimized
stack. Values are model expectations, not frame measurements.

| Window / keyboard | Auto | Tablet | Phone |
|---|---|---|---|
| 390×844 compact / none | Stock single | Single fallback; raw 1 retained; full-screen modal | Single/full-screen modal |
| 844×390 compact / none | Stock single | 340pt master + 504pt detail; no centered sheet | Full-width single |
| 620×1024 split window / none | Native width-class decision | Single fallback (568pt usable); no centered sheet | Full-width single |
| 1024×1366 regular / 500pt keyboard | Stock split/modal policy | 360pt master + 664pt detail; default sheet (236,85,540,720), entirely above keyboard | Full-width single, actual keyboard inset |
| 844×390 / 240pt keyboard | Stock decision | Single fallback (126pt visible height) | Single |
| Large window / active vertical fold | Stock hinge behavior | Original divider only if both safe lanes fit; no centered sheet | Single carrying real division metadata |

Record each 0→1→2→0 sequence with an open chat, nested back stack and a sheet;
repeat during a held/cancelled back gesture, pending ready, rotation/window resize,
keyboard show/hide, asymmetric corners, large text and VoiceOver. Expect the same
chat/editor/list state and back order; no old callback removes the new top, no
duplicate controller, negative pane width, hidden Close action or sheet beneath
the keyboard. Returning to Auto uses the native layout/mode rules. For a minimized
stack, forced Tablet waits in its single-pane fallback.

Acceptance uses the established `simctl io recordVideo`, ffprobe PTS and labelled
frame/track sheets. Pure/native fixture assertions do not establish these frames
or Android-wide hardware semantics.

## Original read-only source checkpoint — historical

- **PASS:** real isolated `merge_parity`: 78 IDs + appicons, **308** resolving
  references; 59 active keys plus the explicitly held `appearance.tabletMode`
  registration delta. Feature status remains partial, `ported=false`.
- **PASS:** all four handoff patches in `git apply --check` against current
  preimages; no shared insertion or registration was applied by this owner.
- **PASS:** scoped Display navigation `git diff --check`, new-file whitespace,
  and the existing four-avatar/18-Core raw frozen manifests unchanged.
- **PASS, conditional projection only:** the real `sdk_config_manifest.build()`
  with the exact registration/scanner additions applied **in memory** resolves
  `neko.tabletMode` to native integer `appearance.tabletMode`, and both exact
  `compat.ExteraConfig.getTabletMode()` / `setTabletMode(int)` routes to read/write.
  No generated file was written; this checks future lookup/metadata, not applied
  registration, SDK execution or UI behavior.
- Ten implementation/test source pins are in `layout-mode-source.sha256` for the
  coordinator's new proof cohort. These do not replace the previous frozen pins.
- Four Core and five native tests are authored; Swift/XCTest execution, native
  build and recorded frames remain **pending**. No CI/commit/live UI/simulator
  action was initiated.

## PNP-01 — retained keyboard/focus adoption

Independent report: `reviews/portable-navigation-performance.md`, PNP-01.
Its source-closure findings for root roles/ownership are retained. The report was
read-only; its raw SHA-256 at this remediation is
`1640b95c7a3a96d591339a2f7c50df2be5785364181a777b5a2d3f763d52525e`.

### Counterexample and source closure

Previously a retained detail with root `inputHeight=500` entered the new container
as a fresh push. Pending preparation and `makeChild` erased the inset; regular-width
promotion then set local `ignoreInputHeight`, so even the final layout was nil.
Restoring `becomeFirstResponder` alone did not repair that delivery.

The current path:

- NavigationController creates one-use adoption tokens for controllers retained
  from the previous native owner map. Hidden, unconsumed tokens are discarded at
  the end of handoff, so an ordinary later push/pop cannot inherit the exception.
- Pending preparation, `makeChild` and ready promotion all distinguish adoption
  from fresh push. Adoption passes the **current supplied pane layout**, never a
  cached 500 constant or an old pane size, and skips fresh-push `ignoreInputHeight`.
- A pending child owns its token through delayed ready. Initial focus permission
  is carried only for the captured responder owner; the normal post-handoff focus
  policy takes over after attachment. Retired/wrong-generation/removed-controller
  readiness cannot publish an adoption.
- The input snapshot keeps weak references to the actual controller, responder
  and window, plus UITextInput document length/selection offsets. No text is copied.
  A different active responder supersedes it; restoration does not cross windows
  or overwrite selection after the document length has changed.
- Attachment completion runs after the container's last `applyLayout`. Root
  reconciliation restores responder/selection, then immediately reruns layout
  against its latest `validLayout`, including when the responder stayed active.
  Reentrant layout/mode requests are guarded/coalesced; no keyboard notification
  is needed to obtain the final current inset.
- A real model-stack edit clears pending focus restoration. Existing cancellation,
  callback retirement and controller identities remain the ownership mechanism.

### Focused native fixtures — authored, not executed here

- `testPNP01TextInputAdoptionKeeps500AndSelectionImmediately`
- `testPNP01DelayedReadyAdoptsCurrentViewportBeforeReadyReturns`
- `testPNP01FreshPushAndSupersededReadyKeepTheirNativeOwnership`

Both concrete UITextInput classes are hosted in a test-owned UIWindow, with an
owned 500pt input view. The fixture supplies the regular layout input using that
window's **actual bounds and scene orientation**. It does not override UIKit trait
collections or device idiom; production forwards the received native metadata.
Assertions use real `isFirstResponder` and `selectedTextRange`, not overrides of
those getters. The fixture restores its previous key window during teardown.

The delayed case changes real fixture-window bounds while ready is false, then
checks final delivered geometry/inset, selection, stack identity and retired
callbacks synchronously when ready is published. There is no post-ready test-side
layout repair, sleep, polling loop or substitute keyboard notification.

Use the existing `//submodules/Display:ExteralessLayoutModeTests` target and bound
post-build execution to **≤30 seconds**. No new BUILD/registry hunk is required.
This Windows session runs source checks only: no CI, commit, simulator or user
account. Native build/XCTest execution and recorded-frame acceptance remain
pending; these source changes are not an independent review closure.

### PNP-01 read-only checkpoint

- **PASS:** scoped `git diff --check` for the four permitted source/test files.
- **PASS:** source/API guard checks cover all three fresh-push nil sites, adopted
  ready promotion, generation/identity ownership and current-layout reconciliation.
  Fixture anchors include both real UITextInput classes, selection/focus recovery,
  immediate assertions, pending A→B→A, resize and stale-ready/pop rejection.
- **PASS:** independent report raw hash is retained; six non-PNP files in the
  layout source manifest retain their hashes. The four changed source/test pins
  are refreshed in `layout-mode-source.sha256`.
- Read-only source inspection confirms current Root role/binding, Core Layout/Font
  declarations, generated actual SDK keys, and the existing native test target.
  No Root/App, registration, BUILD, field-format or avatar/ASC01 source was edited.
- Swift/UIKit/XCTest and recorded-frame verdict: **pending**, not inferred from
  source guards or the published pre-fix cohort. No CI/commit/simulator/user-account
  action was performed.
