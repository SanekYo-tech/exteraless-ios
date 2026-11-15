# Feed remediation — FPP-02–05 / FU-01–03

## Final FU source handoff — FROZEN

**FU-01 / FU-02 / FU-03 source changes are APPLIED and FROZEN for coordinator
acceptance.** No assigned implementation hunk remains pending. Native compilation,
XCTest execution and labelled-frame acceptance remain pending; parity stays partial.

- Core8: [`wave-2/feed-core-frozen.sha256`](wave-2/feed-core-frozen.sha256), unchanged;
  manifest SHA-256 `84d493ade4fce706d3f8583a5b88ecdecc2c59960791a1d1e29352bab52ff975`.
- Native36: [`wave-2/feed-fu-native-frozen.sha256`](wave-2/feed-fu-native-frozen.sha256);
  manifest SHA-256 `a11351633da81d23754b9dea018974b09aa38a08276f4da4aa5612b9738e9c0c`.
  Hashes cover exact working-tree bytes, including shared-file integration, and are
  newline-sensitive. Further source changes require coordinator reconciliation.
- Exhaustive Save callsites and actual factory routing:
  [`wave-2/feed-save-callsites.md`](wave-2/feed-save-callsites.md).
  All **7 inherited-flow facade calls** are wired. The query accounts for all 23
  symbol-call/declaration matches; unrelated stock saves are explicitly listed.
- Final local source preflight: **37 owned + 7 shared Swift files**, **61 prepared
  Feed methods**, original Core8 and CMC09/10 fingerprints preserved. No native pass
  is inferred from those checks. BUILD needs are listed at the end of this handoff.

## UIKit harness API

Debug-only UIKit factory in `ExteralessFeedSmoke.swift`, ready for `feed-render`
(`docs/wave-2/ui-harness.md:394–430`):

```swift
@MainActor
public func makeExteralessFeedSmoke(context: AccountContext, edited: Bool = false)
    -> (controller: UIViewController,
        setEdited: @MainActor (Bool) -> Void,
        dispose: @MainActor () -> Void)?
```

Create **once**, retain the returned handle, attach `handle.controller`, call
`handle.setEdited(true)` for the edit step and `handle.dispose()` for cleanup.
This is the same private controller/production cell renderer as the SwiftUI wrapper.
There is one prevalidated offline permit; expiry is measured from its original
creation, and neither edit nor view attachment renews it. Ordinary live accounts
still fail construction. This factory is not a native run or frame-verification claim.
Calling `setEdited` again with the same value refreshes current native presentation
data without remaking the fixture messages. The private owner passes that same
presentation data into `ChatMessageItemImpl`, including the harness's dark-mode step.

## FROZEN Core slice

**FROZEN** for the coordinator's next Core snapshot: `ChatFeedPolicy.swift`, all five
`Feed*.swift` Core sources, `FeedTests.swift` and `FeedRemediationTests.swift`.
Exact working-tree bytes (newline-sensitive):
[`wave-2/feed-core-frozen.sha256`](wave-2/feed-core-frozen.sha256).
Canonical manifest SHA-256:
`84d493ade4fce706d3f8583a5b88ecdecc2c59960791a1d1e29352bab52ff975`.
No further edits to these eight files are pending in this handoff.

The reported GREEN `dcc13004` / `43698196787` (390 Core / 147 Host / 24 Hooks) is a
previous snapshot, not verification of these new remediation fixtures. This Windows
session has no Swift/Xcode toolchain. No commit, CI dispatch or account/network test ran.

## Finding fixes

Paths below are relative to `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/`
unless qualified. Reviewer report remains unchanged:
[`wave-2/reviews/feed-player-pills.md`](wave-2/reviews/feed-player-pills.md).

### FPP-02 — fresh render/export policy

- New TelegramCore helper
  `TelegramEngine/Messages/ExteralessFeedMessageProjection.swift` observes root message
  IDs, associated reply IDs, current `basicPeer` views, relevant thread-info and story
  views. A change re-renders affected roots through native `Transaction.getMessage`:
  current peers, author/forward metadata, associated replies/media, thread and story
  data come from the same fresh native transaction.
- Dependency comparison retains actual message/view objects and compares current peers;
  `renderToken: UUID` changes independently of message `stableVersion`. Unchanged roots
  retain their token. `Feed/ExteralessFeedMessageCell.swift` uses these tokens, not shallow
  `EngineMessage.==`; `Feed/ExteralessFeedTimeline.swift` also publishes the current peer
  in the channel header projection.
- Public APIs:
  `exteralessFeedFreshMessages(engine:ids:)` (one local transaction) and
  `exteralessFeedMessageProjections(engine:ids:)` (bounded observation).
  Projection `allowsMedia(contentSettings:)` / `allowsExport(contentSettings:)` checks
  current membership/group, peer restrictions, message restrictions and copy protection.
- Actual Copy, selected-text Copy, Share and Gallery use
  `Feed/ExteralessFeedFreshActions.swift` + `ExteralessFeedActions.swift:feedWithFreshMessages`.
  Fresh IDs, immutable context, account validity, visible presenter, membership/config
  and window generation are checked **after** delivery. Copy uses fresh content;
  selected text additionally requires an unchanged text/version/rich body.
- Gallery gets fresh protected policy and a fresh projection stream. An owned Gallery /
  Share presentation is dismissed if protection or membership becomes incompatible;
  delayed presentation callbacks check their original generation. Missing/incomplete
  metadata is surfaced as unavailable/refresh, not deleted history or successful export.

### FPP-03 — actual root-overlay occlusions

- Stable public contract and publisher examples:
  [`wave-2/feed-occlusion.md`](wave-2/feed-occlusion.md).
- Added `AccountContext/Sources/ExteralessContentOcclusions.swift`: main-actor,
  owner-UUID publications scoped by immutable account ID and identical weak UIWindow;
  cached subscription, owner-only clear, window-coordinate rectangles and reentrant
  delivery. It has no message/player effects.
- Feed now subscribes to this registry, converts actual rectangles into table space,
  preserves native keyboard/tab/navigation/Duo band insets, and adds actual top/bottom
  occupied bands (including up to 24pt edge padding). Native keyboard geometry is also
  excluded. Multiple overlapping publishers are not double-counted.
- `FeedContentGeometry` is Foundation-only. Receipts use the on-screen bubble/album
  rectangle after occlusion checks. A tall post still intersecting a bar is rejected;
  reducing the viewport cannot accidentally make it qualify. Fully hidden cells also
  leave the visible metadata set.
- Player author has supplied matching calls in
  `Player/ExteralessPlayerOcclusionPublisher.swift` (`publish` / `clear`), instantiated
  by `Player/ExteralessPlayerIntegration.swift`. That publisher handles current/window
  and unsettled old/new geometry. Those files were read for the handshake, not edited
  by this remediation. Native cross-subsystem compile/frames remain pending.

### FPP-04 — independent poll / pending-webpage lease

- New TelegramCore `ExteralessFeedVisibleMetadataLease` feeds at most **32 actually
  visible composite IDs** into one `AccountViewTracker.wrappedMessageHistorySignal`
  metadata-only view (`.customChatContents`, no holes/read state).
- The existing native `updatePolls` / `updatePendingWebpages` reference counts, poll
  deadlines and pending-webpage resolution own the producers. No second polling RPC
  loop or all-account history views were added.
- UI `Feed/ExteralessFeedVisibleMetadata.swift` retains one lease independently of
  completed/disposed one-shot page requests. A visible-set/membership change updates it;
  IDs remaining visible retain their native producer ownership. Hide, background,
  account invalidation and disposal release it. Native projection updates target the
  original peer/namespace/message ID.

### FPP-05 — header before synchronous foreground

- `Feed/ExteralessFeedHeaderLifecycle.swift` retains one current header and explicit,
  idempotent visible start/stop transitions.
- `ExteralessFeedScreen.viewWillAppear` prepares and attaches that header **before**
  subscribing to cached foreground/active signals. `startFeed` starts that same object;
  appearance after a pause resumes it without waiting for another foreground edge.

## Additional review-150 fixes

- `FeedPresentationPolicy.retention` now uses a **global 500 + 4×29 = 616** retained
  message budget, independent of channel count. Source state keeps only a replay frontier
  and a real optional before-cursor for evicted content. Four requests / 20 messages /
  ten-second round remain; in-flight page arrays are separately bounded by those limits.
- Advancing a window consumes actual IDs, maintains a composite upper bound and bounded
  album-tail exceptions, and reloads evicted sources when their frontier can affect the
  next window. No fabricated IDs, skipped cursor ranges or false end on eviction.
- The account channel registry still retains necessary O(channel-count) peer/cursor
  metadata. Message bodies/media and retained message observation no longer multiply
  by 29 for every channel.
- New Core `FeedSettingsStore` reads one `ClientSettingsSnapshot` and writes all four
  membership/read-dependency maps through **one `applyPublic(..., expected:)` CAS**.
  Both channel settings and avatar exclude/undo use it. Concurrent changes fail rather
  than publishing a half-updated known/add-new/archive/exclusion state.

## Identity shared-section addendum

Applied only the `ChatListController.swift` section of
`wave-2/identity-shared-remaining.patch`: `previousDateTimeFormat` is now part of
presentation invalidation (`ChatListUI/Sources/ChatListController.swift:472–477`).
That section contains the date-format invalidation hunk. The current account-scoped
title remains at `exteralessChatListTitle(accountId:...)`; Feed factory entry and
Appearance's account-aware main-menu/recomposition paths remain present.
The other five patch sections belong to their assigned owners.

## Offline fixtures and native window prototype

New fixtures: **6 Foundation + 7 native**, in addition to the previous 20 feed methods.
They are prepared, **not executed here**.

- `swift/ExteralessCore/Tests/ExteralessCoreTests/FeedRemediationTests.swift`: 64/52pt
  bars, top bar, keyboard/Duo clipping, overlapping rectangles, obscured tall albums,
  global retention/replay frontiers, one atomic membership notification, cross-account CAS.
- `TelegramUI/Tests/FeedTests/FeedRemediationNativeTests.swift`: unchanged message
  version with peer protection flip/reversal and changed reply metadata; fresh-action
  denial and late account/scope rejection; owner/account/window isolation and reentrancy;
  finite page completion with delayed poll/webpage events and a surviving metadata lease;
  cached synchronous foreground header startup; 800 tiny messages through globally bounded
  initial/older windows without duplicates or skipped evicted sources.
- Native fixtures construct **no Account, Network or TelegramEngine**, and use no real
  clipboard export, receipts, votes, sends or external plugins. Existing expectation
  budgets plus the new bounded pagination fixture total 17 seconds; no indefinite waits.
- `Feed/ExteralessFeedOcclusionPrototype.swift`: prepared debug SwiftUI/window prototype
  with a private registry, synthetic post/album rectangles and top/bottom/compact/keyboard
  controls. It requires no account and only displays eligibility. Use it for geometry
  recording, not as proof of real bubble/player rendering.

Coordinator checks after staging the FROZEN Core slice:

```text
swift test --package-path swift/ExteralessCore --jobs 1 --filter 'Feed(Tests|RemediationTests)'
```

Compile native Feed + AccountContext + Player publisher together, then run
`FeedNativeOrchestrationTests` / `FeedRemediationNativeTests` in their native fixture
target. BUILD/common-root edits remain coordinator-owned.

### Expected frames, before recording

1. Top/bottom mini, 64→52pt compact and keyboard transitions: content can scroll clear
   of the occupied band; a covered small post or tall album stays ineligible until
   moved clear. Phone/Duo side bands use the same window-coordinate conversion.
2. Protection flip with unchanged message version updates the already loaded cell;
   current Copy/Share is denied and Gallery uses protected policy. Reply metadata
   changes without replacing the parent message number.
3. A visible poll/pending preview updates after its initial page completed, with no
   pagination restart. Hidden/account-retired feed releases that metadata lease.
4. First opening and reopening with already-cached foreground starts the current pill
   header once. No persistent Waiting-for-reading caused by a missed foreground edge.

Record/evaluate timestamped frames according to `telegram-ios/AGENTS.md`. No frames,
Swift typecheck, XCTest run or current-snapshot CI pass is claimed by this handoff.

## Local evidence

- Postbox import/access guard passed after the native projection/occlusion/metadata changes.
- Final Feed source sanity passed UTF-8/NUL/whitespace/delimiters for **31 Swift files**,
  including the prototype and FROZEN `ChatFeedPolicy`; **33 test methods** are prepared.
  This is not a compiler or test-execution result.
- Owned-path `git diff --check` passed. Reviewer source was not modified.
- All **8 FROZEN hashes** still match the published manifest. The approved Identity
  invalidation hunk and existing scoped Feed/title/Appearance hooks were checked in source.
- Real parity merger accepted **7 original feature IDs + module.feed** and all **36**
  source path/line references. The main parity inventory was not written by the check.
- Updated `wave-2/feed-parity.json` retains original feature/module IDs and **partial**,
  zero-ported statuses. Previous entry hunks are now applied by the coordinator, as
  established by the independent review; their old “unapplied” notes are historical.

## FU-02 / CMC shared permit contract

The shared type is `AccountContext.ExteralessContentExportPermit` in
`AccountContext/Sources/ExteralessContentExportPermit.swift`. Media/selection helpers
must reuse a provided instance by identity. Fresh CMC permissions (including both
private-chat flags), exact selected media/item generation and `Double` playback
samples remain the media owner's validator inputs.

```swift
init(accountId: Int64, messageIds: Set<EngineMessage.Id>, exportAllowed: Bool)
func allows(accountId: Int64, messageIds: Set<EngineMessage.Id>? = nil,
            operation: Operation = .exportEffect) -> Bool
@discardableResult
func perform(accountId: Int64, messageIds: Set<EngineMessage.Id>? = nil,
             operation: Operation, current: () -> Bool = { true },
             _ body: () -> Void) -> Bool
func guardSignal<T, E>(accountId: Int64, messageIds: Set<EngineMessage.Id>? = nil,
                       operation: Operation,
                       _ source: @escaping () -> Signal<T, E>) -> Signal<T, E>
func onRevocation(_ handler: @escaping @MainActor () -> Void) -> Disposable
func revoke()

@MainActor @discardableResult
func own(_ controller: UIViewController, presented: Bool = false,
         from source: UIViewController? = nil) -> Bool
@MainActor @discardableResult
func retainOwner(_ owner: AnyObject, on controller: UIViewController) -> Bool
@MainActor
func presentWhenReady(_ controller: ViewController, accountId: Int64,
                      from source: ViewController, requiresExport: Bool = false,
                      additionalReady: Signal<Bool, NoError>? = nil,
                      prepare: ((ViewController) -> Bool)? = nil,
                      present: @escaping (ViewController) -> Void)
```

- `Operation`: `.presentation`, `.exportPreparation`, `.exportEffect`. IDs are
  original composite IDs; an optional subset check never changes the immutable grant.
  Revoke is permanent, thread-safe, and rejects new admissions immediately. UIKit
  cleanup executes on main and dismisses only controllers owned by this permit.
- `UIViewController.exteralessExportPermit` and
  `.exteralessExportPermitReference` are main-actor accessors. Retain the latter before
  asynchronous downloads that may outlive a controller; its `.permit` is thread-safe.
- The media owner's `ExteralessChatExportAccess.own` now calls
  `permit.retainOwner(self, on: controller)` (confirmed by source inspection).
  The access owns its controllers **weakly**.
  `own(from:)` and `presentWhenReady(from:)` copy these validator owners onto detached
  descendants, including Share's UIKit activity controller, without retaining an old
  Gallery or creating another grant. Retaining just the permit loses fresh observation.
  Captured permit references retain these validator owners too, so delayed activity
  item requests keep observation after the parent Share controller disappears.
- `presentWhenReady` binds before loading the view, owns the pending readiness wait,
  and admits on main immediately before the native presenter. Its ten-second deadline
  fails closed. A revoked pending controller is never submitted to the stock presenter's
  two-second ready-timeout fallback. `guardSignal` owns/cancels subscriptions; terminal
  callbacks after further async work still call `perform`. Revocation does not emit
  a successful signal completion. Counters distinguish
  presentation/preparation/effect admissions from merely waiting for a signal.
- Applied Footer bridge:
  `exteralessNativeSharePressed(selection: ExteralessGalleryMediaSelection? = nil,
  providedPermit: ExteralessContentExportPermit? = nil,
  prepareShare: ((ViewController) -> Bool)? = nil)`. The actual request's `nativeShare`
  passes `selection: selection, providedPermit: permit, prepareShare: prepare`
  after its captured `current()` check. An inherited nonnil permit cannot be replaced.
  The permit owns the
  pending controller immediately. `prepareShare` runs **before and after readiness**;
  its retained validator must reject a retired flow. Since CMC's handoff can detach its
  presentation lease, the Footer independently pins the original native item generation,
  item/player identity and account permit throughout the wait. The generation validity
  signal and the post-ready check prevent A → B → A from reviving an old Share.
- The CMC owner supplies request DTO/time accessor; its Gallery packet is now applied
  below. Existing Tools subtitle actions and native share-link
  timing keep their existing semantics. Nil permit follows the stock consumers.

**Gallery packet applied:** `wave-2/chat-media-gallery-remediation.patch` is now in
`ChatItemGalleryFooterContentNode.swift`, including the new request initializer,
item lifetime and exact `selection:` branch. Its pre-application read-only
`git apply --check --whitespace=error` passed. Main-actor ownership calls and the
before/after-ready generation guards were then integrated into the same Footer.
The approved `SaveToCameraRoll.swift` terminal Photos guard and
`ShareControllerNode.swift` timestamp-link/continuation guards are now applied.
All four direct Save calls in `GalleryUI/Sources/Items/ChatImageGalleryItem.swift`
and `UniversalVideoGalleryItem.swift` now carry the original permit/reference,
item/player generation and success receipt. Their approved wiring is applied.
Current source/fixtures are not a native compilation or visual pass.

| Packet / boundary | Actual state |
| --- | --- |
| CMC Gallery request constructor + named rich medium + live Double time | **APPLIED** in the actual Footer action path; the old `timestamp:` initializer call is gone |
| CMC `selection:` native Share branch | **APPLIED**, `.media(reference, nativeShareParameters)` preserves the original message/media reference and the same provided permit |
| FU-02 root Share prepare/ownership | **APPLIED**, before + after readiness with independent native item/player generation checks |
| Tools media/subtitle and native share-link time policies | Existing code retained; frame time now comes from the separate CMC playback accessor |
| Native Forward packet / native test graph | Assigned to Chat lead / build owner; no packet application by this Feed session |
| Terminal Photos / timestamp-link guard | **APPLIED** in the two approved files and actual Share callers |
| Direct Gallery item Save callers | **APPLIED** to all four calls, including HLS quality and paired Live Photo |
| Actual inherited Share factory | **APPLIED**: Feed and nonnil-permit Footer calls explicitly use the existing guarded `makeShareController` factory |

## Follow-up FU-01–03 — current source handoff

### FU-01 · all incomplete frontiers

`Feed/ExteralessFeedTimeline.swift` now includes **every incomplete source frontier**
in the next window's upper bound, even when that source has no eviction/reload.
An unknown frontier prevents consuming the window. Advancement waits for the current
round to finish, preserving its captured cursors. A returned unshown future-range
item rejects the page **before** cursor/complete/merge mutation; retry uses the same
real before-cursor and the UI exposes the newer gap. Consumed IDs and album-tail
exceptions keep their existing rules. The global retention budget is still **616**.

Prepared actual injected-timeline fixtures in `TelegramUI/Tests/FeedTests/FeedFollowupTests.swift`:

- A IDs `1…1000`, timestamps `4000 + id`; B IDs/timestamps `1…20`.
- A plus 40 short channels, four captured in-flight requests, forward and reverse
  response orders. Each case checks exact union, no duplicates, end found and retained
  ≤616, with 256-round/6-second logic bounds and a seven-second XCTest deadline.
- An unexpected future-range item at A's second-window request is rejected; the next
  retry's captured before-cursor remains A `501`, rather than advancing to A `481`.

Supplemental **executed tuple-branch replay**, bounded to 15 seconds/256 rounds:

| Case | IDs reached | Peak retained | Rounds |
| --- | ---: | ---: | ---: |
| Old-window control, A+B | 520 / 1020 | 520 | 50 |
| Updated bounds, A+B | 1020 / 1020 | 520 | 50 |
| Updated bounds, 41 channels / forward | 1800 / 1800 | 616 | 80 |
| Updated bounds, 41 channels / reverse | 1800 / 1800 | 616 | 80 |

This is a JavaScript replay of the reviewed arithmetic/branches, **not execution of
the Swift timeline or its XCTest fixtures**.

### FU-02 · native descendant ownership and final admissions

- `ExteralessFeedActions.swift` creates one permit from the fresh original-ID scope.
  Its observer remains alive across the outer sheet's dismissal and retires the flow
  on incompatible policy/membership, account replacement or backgrounding. Timeline
  scope changes retire it too. Direct Feed presentations recheck their original
  media/export generation after readiness, so leaving and returning cannot revive
  a queued action. Authorized owned descendants can outlive the Feed's visibility.
- `GalleryController.swift` propagates optional ownership to native root/global and
  ready-delayed continuations. `ChatItemGalleryFooterContentNode.presentRootShare`
  is used by the **actual photo/image, media and album Share branches**. The supplied
  **applied** CMC selection branch uses that same function and instance, with its original media
  reference. Tools subtitle and native share-link policies retain their own paths.
- `ShareController.swift` gates native action dispatch, signal subscription, account
  switching and owned presentations. Resource callbacks gate file staging and register
  cleanup only for their UUID-created export directory, under the same admission lock.
- The actual `UIActivityViewController` path uses `ExteralessShareActivityItem` for
  permitted flows. Placeholder/nil-activity preview requests carry no real payload;
  the typed native item request rechecks the permit before releasing an image/text/URL.
  The activity inherits both the permit and validator ownership. Nil-permit callers
  retain the existing native item path.
- The approved terminal helper now carries the same permit through resource completion,
  permission, file/video preparation, the **actual Photos change block**, and its
  completion. The native Share callers provide the permit and retained validator reference.
  `ShareControllerNode` checks timestamp-link writes, payment/peer continuations and
  success/dismissal callbacks. An empty/failing signal is not a Save/Send receipt.
- The four direct item-menu Save calls also forward the captured reference, current
  generation predicate and validity signal. A missing presenter cannot change an inherited
  grant to nil. Node/item/media/player replacement or visibility retirement rejects the
  old operation, including inside the final Photos change block.
- The current shared factory's `makeShareScreen` builds the component ShareScreen.
  All granted Feed/Footer calls now explicitly choose `makeShareController`, whose
  real implementation contains the final guards. Nil Footer calls keep the stock
  factory. The common factory and unrelated stock components were not edited.

Prepared native tests: `FeedExportPermitTests.swift` uses real Display presentation
contexts with a root Share sibling, foreign sibling and delayed controllers, then
checks only the owned flow is removed and no two-second fallback resurrects it.
`FeedActivityExportTests.swift` calls the production `UIActivityItemSource` boundary
without presenting an activity or exporting. These cover validator retention after
the Gallery/Share disappears, original account/message isolation and zero newly
admitted effects after revocation. The Share tests require `@testable ShareController`
in the coordinator-owned native test graph. The additional ready-handoff test uses
the actual `ExteralessGalleryActionLifetime`: A → B → A suppresses the queued Share,
while a current request prepares on both sides of readiness with the identical permit.

### FU-03 · timeline-owned semantic projection cache and compatible node updates

- One `ExteralessFeedProjectionSession` now belongs to each native timeline. It retains
  dependencies, render tokens and comparison baselines for the old/new ID intersection,
  evicts removed roots and clears on account retirement. Cache keys remain bounded to
  the retained window; restarting an observation no longer gives every root a new UUID.
- Native dependencies compare message attributes/media/peers, associated replies,
  thread-info and story contents semantically. Rich attributes use native page equality
  (media compared by key); `fullInstantPage` is frozen only in the comparison baseline,
  so its mutable reference neither hides a real change nor makes dictionary decode
  order look like one. Rendered messages retain their original native payloads.
- `ExteralessFeedMessageCell` uses `ChatMessageItemImpl.updateNode` for the same composite
  post/primary message/account and compatible native renderer kind. Quote expansion,
  poll choices and media state therefore stay on the existing native node. It records
  the **installed** node identity/kind separately from a requested replacement; stale
  layout applies still fail the existing render lease.
- The prepared projection-owner tests run `{A} → {A,B} → {A}`, then peer-only and
  reply-only updates without a parent version edit, removal/readdition, and rich
  same-object/full-page versus semantically equal re-decode cases. Actual native node,
  quote and poll-state checks remain part of the recorded-render acceptance gate.

### Core freeze, checks and remaining native gate

- Coordinator-reported **CoreFeed8 passed** in `43703427760` / `c7ef25ed`; the full
  Core491 run had one Cloud retry failure. That result does not cover these native FU
  changes. No Core file changed for FU-01–03: all eight existing hashes and manifest
  SHA-256 `84d493ade4fce706d3f8583a5b88ecdecc2c59960791a1d1e29352bab52ff975` still match.
- Local Postbox import/access guard passed. Final UTF-8/NUL/delimiter checks passed for
  **37 owned + 7 shared Swift files**; owned-file whitespace passed. There are now
  **61 prepared Feed test methods**. Swift/swiftc and
  Xcode remain unavailable on this Windows host; these checks are not a typecheck.
- After applying the CMC packet, the actual caller/request labels, named reference,
  live playback accessor, same-permit branch and both readiness guards passed the
  local source handshake. Tracked Gallery/Footer/Share whitespace checks passed.
  The real parity merger accepted seven original feature IDs + `module.feed` and
  **50** source references, all still partial; the main inventory was not written.
- The original review hash remains
  `b1f2bb3ca1826c59430456a25b57880b6d49af196314feddaa552266501fbfa9`.
  Both independent reports were read-only. No CI dispatch, commit, live account,
  Telegram read/send, external plugin or real export was run.

Coordinator: the CMC Footer, terminal files and all four direct item callers are applied.
Compile the frozen native Feed + AccountContext +
GalleryUI + ShareController together. Run the Feed follow-up and CMC fixtures serially.
The harness owner now calls `makeExteralessFeedSmoke` in the actual `feed-render`
scenario; the factory/edit/cleanup API above is unchanged.

Before recording, expected FU frames: (1) A remains the same visible native node with
its quote expanded and multiple-choice poll selection intact while B enters/leaves;
peer/reply changes update A in place; (2) root Share and its pending/activity descendants
close on revocation while an unrelated root overlay remains; no later Save/Copy/export
is admitted; (3) the same smoke controller repaints in dark mode and clears at disposal
or the original 30-second expiry. Capture/evaluate labelled frames per `AGENTS.md`.
Parity remains **partial** until that native execution and frame evidence exist.

## Approved terminal additions — current native contract

`SaveToCameraRoll/Sources/SaveToCameraRoll.swift`:

```swift
public func saveToCameraRoll(
    context: AccountContext,
    userLocation: MediaResourceUserLocation,
    customUserContentType: MediaResourceUserContentType? = nil,
    mediaReference: AnyMediaReference,
    video: AnyMediaReference? = nil,
    exportPermit: ExteralessContentExportPermit? = nil,
    exportReference: ExteralessContentExportPermitReference? = nil,
    exportCurrent: (() -> Bool)? = nil,
    exportValidity: Signal<Bool, NoError>? = nil,
    presentForExport: ((ViewController, Any?) -> Void)? = nil
) -> Signal<Float, NoError>
```

- The reference must contain that identical permit and retains the original validator.
  Message references are checked against the original composite-ID set. `presentForExport`
  routes permission-related native controllers through the caller's owned presenter.
- `exportCurrent` is the thread-safe captured item/player generation predicate;
  `exportValidity` retires the operation when that generation changes. Both are supplied
  by the four direct Gallery calls. Current generation is checked after async hops and
  inside the final Photos commit, even if main-queue validity delivery is delayed.
- One operation owns input/auth/preparation/save cancellation. It claims Photos once,
  rechecks inside `PHPhotoLibrary.performChanges` immediately around `PHAssetCreationRequest`
  / `PHAssetChangeRequest`, and emits **1.0 only after an admitted, successful native
  completion**. Download progress is capped below 1.0. Refusal, empty input, preparation
  failure, a nil video creation request, cancellation and late/duplicate callbacks cannot
  emit that success receipt. Cancellation cleans only its UUID-created temporary directory;
  live-photo export cancellation and late completion cleanup use the same owner.
- Nil keeps the original native Photos map/effect body. Its source was compared with HEAD
  after stripping comments/whitespace and matched; this was not a native execution.
- `fetchMediaData` gained a default-nil `onFailure` callback. Permitted saves use it to
  retire both halves of a paired fetch on a real resource failure; disposal-induced
  callbacks are ignored.

`ShareController.swift` / `ShareControllerNode.swift`:

- Every permitted native send uses `enqueueMessagesWithAdmission(..., tlCommit:)`.
  The existing `ExteralessTLEnqueueCommit` is only a native transaction/cancellation
  adapter: its `canCommit` delegates to the **same inherited export permit**. The
  actual Core `beginCommit` check runs after plugin, bot authorization and media waits.
  No Core enqueue implementation was edited and no privacy/plugin path was bypassed.
- Missing destinations, rejected/partial/empty admission results, pending-message failure
  and completion without an actual result cannot become Share `.done`. Already claimed
  native jobs keep their completion/tracking, while retired subscribers receive no success.
  Provided permits do not fall back to the standalone/opaque export doors.
- Timestamp-link Copy uses the unchanged native Int32 formatting and a terminal sink
  admission. Peer/payment/send callbacks carry the captured Node generation. User cancel
  revokes the flow. Save UI success waits for the Photos receipt; permitted send success
  and intent donation wait for native admission rather than firing when the panel starts.
- External collection produces one terminal outcome. Resource/decode/staging failure,
  missing/expired appearance, failed presentation, activity failure and user cancellation
  retire the owned flow. A `.done` handoff is emitted only after the real activity presenter
  accepts it; closing the source panel is not represented as an actual external export.
  Created export files have explicit completion/deinit cleanup as well as revocation cleanup.
- Revocation now uses the native nonanimated dismissal route. It removes the exact owned
  root controller even when its custom success animate-out is already busy; denied success
  closures are never required to remove a stale root overlay.

Prepared `FeedTerminalExportTests.swift` has **nine** injected-sink methods for image,
video and Live Photo permission/preparation/change-block/completion boundaries; empty/
failure/cancel/duplicate paths; native Core commit admission and post-commit cancellation;
timestamp Copy and reentrant retirement; and bounded external-appearance handoff. There
are no Account/Network, filesystem, Photos, clipboard or transfer effects. The only
explicit wait is one second (a 10 ms injected appearance timeout). The existing native
presentation fixture also covers revocation during an already-busy dismiss animation.

### BUILD needs for the build owner

- Production source globs already include these files. `SaveToCameraRoll` already depends
  on AccountContext/TelegramCore/Display/SwiftSignalKit; ShareController already depends
  on AccountContext/TelegramCore/SaveToCameraRoll. No additional production package edge
  or SDK library is introduced by these terminal additions.
- `TelegramUI:ExteralessFeedTestsLib` currently globs `Tests/FeedTests/*.swift`, so the
  new test source is included automatically. Add its explicit dependencies on
  `//submodules/ShareController`, `//submodules/SaveToCameraRoll`, `//submodules/GalleryUI`,
  `//submodules/Display` and `//submodules/AsyncDisplayKit` (the latter three also serve
  the prepared render/presentation fixtures).
- The native debug test build must enable `@testable` access for TelegramUI,
  GalleryUI, ShareController and SaveToCameraRoll. Keep the native-test source mapping and existing
  `ExteralessFeedTests` runner target current; run serially. No BUILD/CI file was edited
  or dispatched by this session.

Interim terminal preflight (before the final direct-item step): Postbox import/access and tracked whitespace checks passed;
**35 owned + 5 shared Swift files** passed UTF-8/NUL/delimiter checks. There are
**56 prepared Feed methods** (nine new sink fixtures and the busy-dismiss regression
in this terminal step). All eight Core frozen hashes still match. These remain source
checks; native compilation, execution and labelled frames remain pending.

### Final direct-item step and acceptance inputs

`GalleryUI/Sources/ExteralessGallerySaveLifetime.swift` retains the original reference
and snapshots an item/player epoch before the menu's asynchronous reads. Only an actual
attached stock presenter establishes a nil grant. Missing presenters and foreign
presenter references cannot replace an inherited grant; each operation has separate
receipt state while keeping the same reference, permit and original epoch.

The image node invalidates on message/medium/protection change, loss of centrality /
visibility and exit. The video node also invalidates **before player replacement** and
on item replacement. CMC's existing Double/player accessor and exact-selection DTO were
kept unchanged, verified by the fingerprints in the callsite audit. Tools media/subtitle
and unrelated story/avatar/parser paths have no edits from this final step.

`FeedGalleryDirectSaveTests.swift` adds five prepared, accountless cases: retained permit
after a presenter disappears; actual stock classification; A→B→A while permission is
held; the final Photos predicate with validity delivery deliberately held; and a fresh
success receipt for every attempt without renewing the captured epoch. The tests invoke
the production lifetime and saver with injected sinks, never Photos/files/exports.

The coordinator's native target is `//submodules/TelegramUI:ExteralessFeedTests`.
Include the final source mapping and run serially alongside the CMC target owned by
the build coordinator. Expected final frames additionally cover direct photo, local
video, HLS quality and paired-image Save: a source/player change while permission or
preparation waits produces no asset or Saved UI, and an unrelated root overlay remains.
No CI/commit or real transfer was performed. This frozen handoff is source readiness,
not independent closure or native/visual acceptance.
