# CMC-03/04 (P1), CMC-09/10 (P2) — scoped remediation

2026-11-15. Source changes and eight native fixtures prepared. **Integration is
pending the shared Gallery/Forward hunks below; no native build/test or UI-proof
claim.** The independent review in `reviews/chat-media-composer.md` is read-only.

## Applied scoped sources

Paths in this section are under `telegram-ios/submodules/`.

- `TelegramUI/Sources/ExteralessClient/Chats/ExteralessSelectionActions.swift`:
  saved More callbacks run `ExteralessSelectionActionSession` again. Native action
  eligibility and current selected messages are reread before Copy, Forward and
  Combine, including the Replace draft confirmation. Reply/Edit/Select between
  also resolve their current eligibility. Rich Copy retains the native rich
  pasteboard representation; multi-rich Combine remains excluded.
- `…/ExteralessChatExportAccess.swift`: one original `ExteralessContentExportPermit`,
  immutable message IDs/content baseline, full stable ID/version/thread and encoded
  native attributes/effective-media comparison. Rich attributes use native page
  equality, so dictionary iteration order does not look like a content edit; the
  mutable `fullInstantPage` reference is frozen only in the comparison baseline.
  `EngineMessage ==` alone is not
  sufficient. Each admission reads Core scopes, then validates them again before
  the effect on main. The final native acquisition couples message/media and cached
  flags in one transaction; account identity is sampled again afterward. Account/
  foreground and source/presentation changes revoke permanently; A → B → A does
  not renew a captured callback. A zero-size window-lifetime observer also catches
  removal/reinsertion of the same Chat view. Authorized native picker coverage and
  its accepted dismissal have explicit ownership transitions.
- The existing Core `resolveExteralessAIScope`, `validateExteralessAIScope` and
  `exteralessAIScopeValidity` supply the **effective associated peer and both**
  `CachedUserFlags.copyProtectionEnabled` / `.myCopyProtectionEnabled`. The Feed
  projection is channel-scoped and is deliberately not used for private chats.
  No separate private-chat predicate was invented from old Peer/Message flags.
- `…/ExteralessMessageMediaActions.swift` and `ExteralessImageActionOperation.swift`:
  exact native reference supplied by the caller; fresh admission before fetch,
  after held fetch/decode, before clipboard/sticker export, QR Copy/Open and
  profile confirmation, after the profile peer read, and after controller-ready
  waits immediately before `updateProfilePhoto`. Image/video I/O and final native
  effects are injectable boundaries of the shipping operation.
- `…/ExteralessGalleryChatActions.swift`: the action sheet and destination picker
  use that same access/permit. The image/video affordance is derived from the
  selected reference, not `effectiveMedia.contains`. Forward keeps the full native
  message ID/options rather than flattening a rich message.
- `GalleryUI/Sources/ExteralessGalleryMessageActions.swift`: request types include
  `ExteralessGalleryMediaSelection` (native reference, subject and generation),
  optional playback sample, inherited permit and live item validity. A named miss
  returns nil and is presented as “The selected attachment is unavailable.”
- `GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift`: only image-action
  live-time/player-identity accessors added. The accessor reads native
  `MediaPlayerStatus`; paused 20 s / 8.25 s remains **8.25**, playing status is
  extrapolated using its native generation timestamp/base rate. Missing/invalid
  status fails. Image generation receives this Double with zero time tolerances;
  share-link `Int32` and the ten-minute policy are independent.

Existing policy distinctions remain explicit: native text Copy can be available
in a secret chat; the media actions still exclude secret-chat/secret media,
paid content and ads. The Chat action explicitly named “Copy first video frame”
uses zero; Gallery “Copy current frame” never substitutes zero for missing status.

## FU-02 permit API handshake

Use the Feed owner's actual `AccountContext/ExteralessContentExportPermit.swift`:

```swift
permit.perform(accountId:messageIds:operation:body)
permit.guardSignal(accountId:messageIds:operation:source)
permit.own(controller, presented: false, from: source)
permit.retainOwner(owner, on: controller)
permit.presentWhenReady(controller, accountId:…, from:…, requiresExport: true, …)
```

`ExteralessChatExportAccess.own` now calls **`retainOwner`**, so native detached/root
descendants inherit the live source validator through `own(from:)` and
`presentWhenReady`. Controllers are held weakly by the validator. If a request has
a Feed permit, the access uses that identical instance; a replacement permit is
not minted. `handoff` transfers presentation ownership at an accepted destination,
not the message/version/protection baseline. `commitSelection` permits only the
native Forward operation's intentional selection cleanup after destination
acceptance. Explicit cancellation ends the operation; protection/account/source
revocation also revokes the common permit.

The current Feed-owned footer already exposes:

```swift
exteralessNativeSharePressed(providedPermit:…, prepareShare:…)
presentRootShare(controller, permit:…, prepareShare:…)
```

CMC adds a `selection:` parameter to the first method. `prepareShare` is the
`access.handoffNativeExport(to:)` callback. It must run before the native controller
is presented and after readiness. FU-02 must keep the same permit on every native
Share/save/system-activity descendant and on every deferred final effect. Its
terminal Photos/files/activity/enqueue checks are the FU-02 owner's integration
boundary, not proven by the CMC clipboard/profile spies.

## Shared patch — owner/coordinator application

**Required for compilation:** the request initializer changed, and Selection calls
native `forwardMessages(…, exportAccess:)`. Neither shared consumer was edited here.

1. **Gallery owner:** [`chat-media-gallery-remediation.patch`](chat-media-gallery-remediation.patch)
   is the literal footer patch against the current FU-02 API. It captures native
   selection + player identity, invalidates generation on source change/exit, and
   reads playback live when the action is chosen. CMC Share/Save exports the named
   native medium with its original `MessageReference`. It never widens the permit
   to all rich media or reconstructs a plain message.
2. **Native Forward coordinator:** the `forward` packet adds the optional
   `exportAccess` argument and wraps existing recording-discard continuation,
   single/multiple destinations, payment continuation, schedule, final enqueue and
   destination draft writes. Helpers are `ExteralessForwardExport.swift`; schedule
   keeps the actual native screen/defaults and full result. The emitter reads the
   current native implementation, preserving concurrent comment/sound fixes.
3. **Build owner:** the `tests` packet adds `ExteralessChatMediaTestsLib` /
   `ExteralessChatMediaTests`, direct native dependencies, the IntegrationTests edge
   and the mandatory `native-tests.json` source mapping. Production helpers use
   the existing `Sources/**/*.swift` globs. Postbox's existing TelegramUI package
   visibility already covers the test; no allowlist expansion is needed.

The read-only emitter fails on changed anchors and never writes source files:

```text
python -B docs/wave-2/tests/chat_media_shared_patch.py --verify
python -B docs/wave-2/tests/chat_media_shared_patch.py --part gallery
python -B docs/wave-2/tests/chat_media_shared_patch.py --part forward
python -B docs/wave-2/tests/chat_media_shared_patch.py --part tests
```

Each `--part` emits an ordinary, exact unified git patch to stdout. `--verify`
feeds the full packet directly to `git apply --check --whitespace=error` as UTF-8
bytes, avoiding PowerShell output recoding. Apply each packet once; the literal
Gallery patch and the emitted `gallery` packet are the same change.

## Native fixtures and evidence boundary

New files:

- `TelegramUI/Tests/ChatMedia/ChatMediaNativeFixture.swift`
- `TelegramUI/Tests/ChatMedia/ChatMediaRemediationNativeTests.swift`

Eight methods use a real in-memory Postbox, real Core scope transactions and
cached-data observation, two 2px native resource identities, an actual
`MediaPlayerStatus(duration: 20, timestamp: 8.25)`, the shipping selection callback
session/image operation, and presentation/export spies:

1. Copy/Forward/Combine callbacks with two actually selected messages, both private
   flags independently, same stable version, and a positive reopened action.
2. Same IDs with content/thread replacement, selection change, presentation change,
   actual UIView removal/reinsertion and account A → B → A.
3. Held destination and draft-confirmation callbacks, identical inherited permit.
4. Held fetch/decode, private protection, deletion, replaced medium, account switch
   and explicit cancel: zero final exports.
5. QR Copy/Open, profile confirm and held own-peer read: zero stale exports.
6. Real status accessor → generator spy receives exactly 8.25; absent status fails;
   invalidated item generation prevents the old decode result from publishing.
7. Rich A/B plus video: B reference/resource fetched, video not mistaken for image,
   full rich source preserved; absent/named-missing medium and same-version changed
   resource fail.
8. Actual cached-data observer revokes an owned native presentation without a
   message version change.

No Account/Network, external plugin, actual clipboard/Photos, file decode, profile
upload or RPC is constructed. The only explicit XCTest wait is bounded to 1 s;
fixture transactions/cleanup also have 1 s failure bounds. Run this one class
serially in the existing native runner with its **30 s logic budget**:
`//submodules/TelegramUI:ExteralessChatMediaTests`,
`ChatMediaRemediationNativeTests`, `-parallel-testing-enabled NO`.

| Evidence | Status |
| --- | --- |
| Read-only shared packet / `git apply --check --whitespace=error` | PASS locally, under 30 s |
| Scoped whitespace check | PASS: 10 helper/request/fixture files plus the tracked video accessor (Git reports only its LF/CRLF conversion notice) |
| `python -B build-system/Make/PostboxImportCheck.py` from `telegram-ios/` | PASS |
| Core/native fixture execution | **Not run**: `swift` / `swiftc` / Xcode unavailable on this Windows host |
| Real UIKit menu/destination path and AVAsset frame pixels | **Not run**; separate native acceptance |

For UI acceptance, record the real More → protection toggle → captured action,
the paused 20-second clip at 8.25, and rich A/B selection before/after swipe/edit.
Expected frames: the chosen B remains the visible/exported medium; a revoked
owned prompt closes without another presentation; no stale copy/profile effect.
Only labelled recorded frames can establish visual behavior. No CI or commit was
started by this remediation.
