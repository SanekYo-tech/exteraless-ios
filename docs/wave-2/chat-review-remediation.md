# Chat review remediation — CMC-02 / 05 / 11 / 13 / 15

2026-11-15. Source patch and bounded native fixtures; **not a native/XCTest/visual
pass**. `reviews/chat-media-composer.md` is read-only. The coordinator-reported
`38d71afe` Chat/Core slice and `4431b7dc` Core run predate these native fixes.
No CI, commits, live accounts, external plugins or network requests were run here.

## CMC-02 — typed local admission and operation-owned cleanup

- `TelegramCore/Sources/PendingMessages/EnqueueMessageAdmission.swift` defines one
  result slot per input, including plugin CANCEL, bot denial, retained-reply failure,
  precommit cancellation and native local-enqueue failure. Partial batches retain
  their real IDs and rejection reasons.
- `enqueueMessages` and `enqueueMessagesFromPlugin` are thin `.messageIds` adapters
  over the typed implementation. The old result-slot helper delegates to the same
  slot restoration. Hook interception, media preparation and enqueue are not duplicated.
- The coordinator's **TLN-05 permit is retained** through both private helpers.
  `beginCommit` is first inside the existing send transaction, before privacy and
  deleted-reply rewriting. Ephemeral work and NativeServices publication remain
  postcommit. No second send transaction was added.
- `ExteralessChatSendOperation` owns cleanup, the captured draft revision and its
  correlation set. A history callback, including nil-correlation Reduce Motion,
  cannot authorize pending/rejected cleanup. Final rejection cancels only owned
  pending transitions/layout registration. Full local admission clears once only
  while the original revision matches; partial admission keeps the draft.
- Real text/forward, bot command, inline/GIF, photo/file, rich attachment, pasted-media
  and recording producers pass that operation to `exteralessSubmitChatBatch`.
  Scroll/donation and schedule navigation follow accepted local IDs. Send completion
  callbacks no longer run before admission or on the first member of a partial album.
- Caption clearing and rich-draft cache removal are deferred to that admitted cleanup.
  Rich attachments also capture their separate sync revision. Immediate voice sends
  retain a native audio draft; trimmed voice sends copy a staging resource instead of
  moving the draft's only resource before admission.

The small custom-content protocol/adapters in `chat-review-integration.patch` carry
real admission from Quick Reply and Welcome producers as well. Business-link editing
uses its actual successful mutation callback, never a fabricated MessageId.

## CMC-05 — one sound decision across producers

`ExteralessChatSendOptions` is the native producer boundary: explicit nil preserves
an existing decision; otherwise the native chat/global defaults are resolved once.
Explicit false survives the media transform followed by `sendMessages`.

- Ordinary inline-GIF taps pass nil; explicit silent stays true. The GIF-specific
  `ChatControllerInteraction` optional-field hunk is in the integration packet.
- Round/voice completion passes its optional override intact rather than collapsing
  nil into stored false.
- Schedule UI starts with the effective native/global default or an existing explicit
  decision. Complete result values (sound, time, repeatPeriod) reach rich/inline/media
  sends. Already-scheduled values do not open a second schedule picker.
- Native media, rich attributes, entities, replies, grouping and other message fields
  are carried as their original typed values throughout these transformations.

## CMC-11 — continuous call lifetime, including replacement

`ExteralessChatCallFlow` is the actual injected call producer. It retains one sticky
account/foreground scope from entry through initial peer read, initial prompt,
existing-call peer read and replacement OK. A false scope event permanently retires
the operation; A → B → A cannot revive it. Every prompt has its own consumed identity,
including dismissal callbacks. Repeated OK and repeated start do not repeat the effect.

The adapter in `ExteralessChatCallConfirmation.swift` keeps native peer names,
existing-call messages, call-manager semantics and navigate-to-current-call behavior.
Its AccountContext entry hunk is in `chat-review-integration.patch`.

## CMC-13 — immutable Edit A and typed pending admission

The `ChatControllerLoadDisplayNode.editMessage` body captures edit/input/media/preview,
account and revision **before both reads**. `exteralessSubmitChatEdit` rechecks the
operation at each read, rejects missing/changed sources and passes only the captured
request to pending installation. There are no live B media/preview reads in preparation.

`PendingUpdateMessageManager.addWithAdmission` (ready shared hunk) checks source
existence/version, then atomically claims `PendingMessageUpdateAdmissionToken` immediately
before its existing `impl.add`. Cancellation before claim installs nothing; the old
void `add` delegates to this implementation. Cleanup requires admitted/unchanged A
and the same current revision; missing A and late A never close B.

CMC-07 overlap is integrated with the Rich Composer owner:
`exteralessComposerMarkdown(..., respectDisableMarkdown: false)` is used for Edit,
while its native rich content remains structural. Date/selection/paste sections remain
with that owner's implementation.

## CMC-15 — complete command exclusion

`exteralessPrepareOutgoingChatText` tests `!text.hasPrefix("/")` before Pangu. The
entire command, arguments and styled/entity ranges bypass spacing, with or without
a BotCommand entity. Rich/secret/URL/code exclusions and ordinary prose spacing remain.

## Bounded fixtures and actual checks

**18 new XCTest methods**, all written but not run in this Windows session:

- `TelegramUI/Tests/Chats/ChatAdmissionProducerTests.swift`: actual shared batch
  ingress with fake enqueue; nil correlation + unrelated history before/after five
  refusal reasons, partial slots, new input/layout owner, accepted cleanup exactly once;
  inherited FU-02 account/source subset and actual commit cutover/revocation.
- `ChatSoundProducerTests.swift`: text/photo/round/GIF/inline/forward/rich native values
  × nil/true/false × native/global defaults through the shared producer boundary;
  second-transform preservation, schedule period and rich/media/entity identity.
- `ChatCallProducerTests.swift`: held first/second reads, account/foreground retirement,
  old replacement OK, ordinary and replacement effects once.
- `ChatEditProducerTests.swift`: held first/second source reads with Edit B, missing or
  changed A, zero stale installation/cleanup.
- `TelegramCore/Tests/EnqueueAdmissionTests.swift`: sparse typed slots, held pending-edit
  source check + cancellation, commit claim and post-claim disposal.
- Added whole-command/style/no-entity/control cases to `ExteralessOutgoingChatTextTests`.

These fixtures use the production injectable functions, local values and controlled
signals. They do not construct a live Account, execute request hooks, send/delete
messages or certify UIKit frames. Their loops are finite; no fixture waits on a
network or account response. Run native XCTest serially (`-parallel-testing-enabled NO`),
with a 30 s fixture limit, after the shared graph is composed.

Checks performed: Postbox import audit and owned-source `git diff --check` passed;
Final UTF-8/NUL/delimiter sanity passed for 19 source/test files. The shared packet dry-applied
in memory: **6 files / 13 hunks**, with balanced projected source. Typed-enqueue source
audit confirms thin legacy adapters, one send transaction, TL permit ordering,
distinct reasons and preserved postcommit publication. These are source checks.

## Coordinator / build handoff

1. Apply **`chat-review-integration.patch`**: GIF optional field, pending-update typed
   admission, AccountContext call entry, custom-content admission protocol and its two
   real adapters. Source/API details are in `chat-admission-contract.md`.
2. Include new TelegramCore helper files and UI `ExteralessChat*Admission`,
   `ExteralessChatSendOptions`, `ExteralessChatCallFlow`, `ExteralessChatExportEnqueue`
   files through the normal globs.
   Wire `TelegramUI/Tests/Chats/*.swift` and `TelegramCore/Tests/EnqueueAdmissionTests.swift`
   into the existing native test targets with testable UI/Core + Postbox/SwiftSignalKit.
3. Run the new native fixtures and full native typecheck; then exercise Reduce Motion
   rejection + unrelated history, partial albums, new input while enqueue is held,
   round/schedule sound choices, Edit A → B, and both call prompts across account/background
   transitions. No closure/visual pass is claimed until those checks are actually performed.

## Final Forward/FU-02 source stitch

Ran the read-only `chat_media_shared_patch.py --part forward` emitter successfully
against the current source. Applied its boundaries as narrow callback wrappers in
`ChatControllerForwardMessages.swift`, preserving the native bodies and all callback
arguments instead of replacing/reindenting the whole file.

- Optional `exportAccess` reaches recording-discard continuation, multiple/single
  destination selection, payment, schedule, final enqueue and destination draft writes.
- The inherited permit is handed to both reused/same-chat and newly created destination
  controllers. Deferred readiness/navigation and draft completion remain gated.
- Actual draft projection uses `permit.perform` inside the native update closure.
- `ExteralessChatExportEnqueue` carries the **same** permit into the existing
  `ExteralessTLEnqueueCommit` gate. This also covers Send after destination handoff:
  the send operation retains its controller's FU-02 reference and cancels only its
  own cleanup on revocation. A claim retains native postcommit completion after UI disposal.
- `.whenOnline` no longer manufactures audible false; explicit sound and complete
  schedule results survive. Forward comment still uses the Rich owner's
  `exteralessComposerForwardComment` (`respectDisableMarkdown: false`).

Gallery and media-test packets remain with their assigned owners. No FU-02 runtime
or native legal-parameter acceptance claim is inferred from this source stitch.

## CMC-05 P2 follow-up — complete media Schedule DTO (FROZEN for re-review)

2026-11-15. This follow-up addresses the residual producer counterexample in
`reviews/chat-source-closure.md:31–50`. The earlier CMC-05 section and helper-only
matrix did not establish closure for the ordinary media Schedule bridge. The
independent review is read-only; this is the author's source remediation, pending
independent re-review and native execution. The remaining CMC-03 P1 draft boundary
is assigned to Media.

### Exact five production files / frozen regions

All paths below are relative to `telegram-ios/submodules/`:

1. **`AccountContext/Sources/AccountContext.swift`** —
   `ChatSendMessageActionSheetControllerSendParameters.Schedule`, its optional
   `schedule` field and `withUpdatedSchedule`. The value contains **time,
   repeatPeriod, silentPosting**. A returned result replaces the whole previous
   schedule, including a nil repeatPeriod, and sets `notificationOverride` to the
   explicit choice, including false. Existing initializers remain source-compatible.
2. **`ChatSendMessageActionUI/Sources/ChatSendMessageContextScreen.swift`** —
   `chatSendMessageScheduleParameters` and the actual Schedule menu action. The
   menu captures effect/caption placement and leaves sound absent until the picker
   returns. AttachmentPanel/AttachmentController pass these same parameters into
   `AttachmentMediaPickerContext.schedule(parameters:)`.
3. **`MediaPickerUI/Sources/MediaPickerScreen.swift`** — typed
   `presentSchedulePickerWithResult` / `requestSchedulePicker`, actual
   `mediaPickerScheduleCompletion`, `mediaPickerSendParameters` in Node.send,
   both gallery callsites and the nested-album picker handoff. The complete result
   travels in send parameters through native asset-signal generation and
   `legacyCompletion`; ordinary taps keep `notificationOverride == nil`.
   The compatibility gallery bridge holds its DTO only during the existing
   synchronous schedule-done → completed callback, then clears it. It is local to
   that gallery invocation, so a later ordinary send cannot inherit a schedule.
4. **`TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift`** —
   `exteralessMediaScheduleCompletion` and `presentMediaPicker`'s typed callback.
   The actual `ChatScheduleTimeScreen.Result` is copied with all three fields.
   Picker seeding receives any existing explicit override; otherwise the existing
   native/global seed is used. Completion forwards the DTO and native navigation
   still uses its returned time.
5. **`TelegramUI/Sources/ChatController.swift`** —
   `prepareMediaEnqueueMessages` and its `commitEnqueueMediaMessages` callsite.
   After real legacy asset preparation/correlation mapping, the conversion passes
   **schedule choice → older notification override → legacy true/nil intent** into
   the existing native transform, together with the full time/period. Effect and
   caption placement retain their existing native attribute projection. Scheduling
   also supplies the time used by transition admission. Paid-postpone, reply/media/
   grouping values continue through the actual native transform and send operation.

These regions plus the new test file are **frozen for review**. Current whole-file
SHA-256 source fingerprints are in `chat-media-schedule-frozen.sha256`; they pin the
working-tree snapshot, not compiled/runtime status. Shared-file changes outside
these regions may require a new whole-file fingerprint during integration.

### Meaningful regression cohort

**`telegram-ios/submodules/TelegramUI/Tests/Chats/ChatMediaScheduleProducerTests.swift`**
adds **4 bounded native XCTest methods**, with at most two 16×16 in-memory media
values per batch and no sleeps, Account construction or media/network requests.

The main matrix calls the same Schedule-menu parameter factory, actual attachment
`ChatScheduleTimeScreen.Result` completion bridge, actual media Schedule completion
and Node.send parameter normalization, then `ChatControllerImpl.prepareMediaEnqueueMessages`
used by production enqueue. It injects the existing `ExteralessChatSendOptions`
sound stage in place of the controller instance, applies that stage again with
changed defaults (the sendMessages re-entry), and reaches `exteralessSubmitChatBatch`
with a fake local enqueue. It does not bypass the former lossy Bool bridge by
injecting sound directly into the final helper.

- false/true × native false/true × global false/true × previous nil/false/true;
  exactly one final notification attribute, unchanged chosen sound and period.
- Ordinary-tap nil/default control, including caption-above-media.
- New result overrides old time/period and a conflicting notification parameter;
  nil repeatPeriod removes a previous repeat rather than reviving it.
- Gallery callback preserves the full DTO for its send, then an ordinary callback
  sees no schedule. Effects, captions/entities, rich/media references, paid/send-as
  attributes, replies, thread, album grouping and correlation are asserted.

### Checks and native build handoff

- Five-file `git diff --check` passed. Read-only UTF-8/NUL and actual DTO/producer/
  enqueue wiring checks passed, including the nested-album and both gallery routes.
- **`chat-media-schedule-build.patch`** dry-applied in memory: **2 files / 2 hunks**.
  Production module dependencies already cover the five-file change. The packet
  adds ChatSendMessageActionUI, MediaPickerUI and ChatScheduleTimeController to the
  existing `ExteralessChatMediaTestsLib`, plus the native-tests.json source mapping.
  The existing `Tests/Chats/*.swift` glob already includes the new fixture.
- No Swift/swiftc/xcrun is installed in this Windows session. These XCTest methods
  have **not run**; the old ComponentsMac snapshot does not execute this UIKit chain.
- Before full-IPA acceptance, Build/coordinator should apply that test packet and
  run `//submodules/TelegramUI:ExteralessChatMediaTests` on the current integrated
  snapshot, serially (`-parallel-testing-enabled NO`), within the **30-second logic
  budget**, followed by the native app typecheck/build. Record the photo Schedule
  false/true controls under native/global silent defaults and verify the final
  native notification/schedule values; source checks do not certify UI frames.

No CI dispatch, commit, live-account use, network request or plugin execution occurred.
