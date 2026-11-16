# Native TelegramCore fixture compiler corrections

2026-11-16. Applied the reported XCTest source corrections from run
`43812503558`, revision `93dcb653d408e45fe1327ee2ee945952520548b4`.
All five owned files matched that revision byte-for-byte before editing.
**Native iOS compilation and execution are pending.** This Windows host has no
`swiftc`; the checks below establish source preservation, not native acceptance.

## Compiler evidence

- `C:\Users\sasha\AppData\Local\Temp\opencode\uikit-93dcb653-full.log`
  SHA-256: `cd57dfbae4c26acf309d4d3d1dd75a9f85e267ed6fe92a07cc346bb7aa678995`.
- `build/artifacts/client-ui-43812503558/native-tests/compile/console.log`
  SHA-256: `1f2acdd3a353164aa4f540366bb9b754f6aac358baa7c7d7dd5f169a816d2a49`.
  Relevant diagnostics are at lines 181, 588, 703, 728, 736, 795, 804, 813 and 823.

## Exact corrections and retained semantics

Paths below are relative to `telegram-ios/submodules/TelegramCore/Tests/`.
Diagnostic locations refer to the original sources.

| Source / diagnostic | Applied correction | Why the fixture still tests the same behavior |
| --- | --- | --- |
| `ExteralessTLReviewTests.swift:4` — ambiguous TelegramApi import access | Spell `internal import TelegramApi`, matching the other native-core test sources. | This is the file's sole change. Actual generated requests/parsers, native secret-update replay, enqueue transactions, counters and TL data are identical. |
| `ExteralessDialogReviewTests.swift:320` — stored mutable `GlobalNotificationSettings.defaultSettings` | Start with a local `GlobalNotificationSettingsSet.defaultSettings`, update its `channels.enabled`, then construct an immutable `GlobalNotificationSettings(toBeSynchronized: nil, remote: remote)`. | `SyncCore_GlobalNotificationSettings.swift:48–49` computes a fresh settings set; `:86` shows the original default's exact nil/remote initialization, and `:142–145` supplies the existing constructor. Private/group notifications and every other default retain the same values. The channel/global-mute matrix, preferences write, unread recomputation and peer-mute update retain their order. |
| `ExteralessRetentionTests.swift:280` — throwing body passed to nonthrowing transaction | Return `Result<Bool, Error>` from the native transaction; call `result.get()` in the throwing test's final `XCTAssertTrue`. | The existing unknown-field cache write, `XCTAssertThrowsError` on the real index loader and byte-exact cache readback all remain inside the same transaction, in the same order. The catching `Result` body contains the throwing work; unexpected errors reach the test through `get()`. This matches the neighboring retention fixtures. |
| `ExteralessStickerReviewTests.swift:100` — throwing dispatch callback | Capture the actual settings-write `Result` in an existing `Atomic` container; unwrap it and assert `XCTAssertNoThrow(try writeResult.get())` after the existing waits and queue drain. Dispatch through `Queue(queue: DispatchQueue.global()).justDispatch`. | `SwiftSignalKit/Source/Queue.swift:32–35,76–77` retains the supplied global queue and calls its native `async` directly. Writer A remains asynchronous on that same global queue; writer B still commits while the old read is paused. Completion is signaled after storing the result. No result lock is held during `store.set`, and all original semaphore barriers/deadlines and monotonic-delivery assertions remain. |
| `ExteralessStickerReviewTests.swift:170` — throwing signal subscriber | Capture `Result { try store.reset(...) }` in `Atomic`; unwrap and assert the no-throw outcome after the existing completion wait and queue drain. | Reset still executes inside the real policy subscriber while `delivering` is true, so reentrant delivery still fails. The exact `[false, true]` delivery expectation remains. A missing write result fails `XCTUnwrap`; a thrown reset fails the retained no-throw assertion. |
| `NetworkCredentialLogTests.swift:60,110,113,115` — optional `MTRpcError` | Mark the two affected test methods `throws`; construct their 403/420 errors with `try XCTUnwrap(MTRpcError(...))` before the existing consumers/callbacks. | Both real native error objects are required. Their original descriptions, 7-second flood wait, retry context, reference-identity assertion and completion formatting checks remain. No optional fallback or replacement error is introduced. Both logger-redaction flags and the generated-auth producer remain covered. |

All corrections use existing APIs; no production API hunk is required.

## Bounded local verification

- Compared complete XCTest class/method inventories against `93dcb653` using the
  existing `native_test_plan.fixture_classes` scanner: **41 named methods** retained
  across TL (10), Dialog (9), Retention (11), Sticker recents (3), Sticker policy (4)
  and credential logging (4).
- Compared all **281 `XCTAssert*`/`XCTFail` calls by kind**, fixture string/numeric
  literals, semaphore/wait/drain order and deadlines. Reviewed the moved no-throw
  assertions against their actual captured write results. The numeric audit excludes
  Swift shorthand closure parameters such as `$0`; its initial textual version
  incorrectly counted the new result-read parameters as scenario numbers.
- The seven exact RPC name/constructor pairs remain:
  `bots.invokeWebViewCustomMethod/0x087fc5e7`, `auth.sendCode/0xa677244f`,
  `auth.exportLoginToken/0xb7e085fe`, `auth.importBotAuthorization/0x67a3ff2c`,
  `auth.importWebTokenAuthorization/0x2db873a9`, `auth.initPasskeyLogin/0x518ad0b7`,
  `auth.initFirebasePnvLogin/0x644f15c0`.
- No isolation-suppression, unchecked-Sendable or skip annotations were added.
  Native `Postbox.transaction` and `Signal.start` nonthrowing signatures, the queue
  forwarding implementation, notification constructors and MTRpcError header were
  inspected directly.
- `python -B -m unittest tools.ci.tests.test_native_fixture_classes`: **4 passed**,
  0.004 seconds. The final five-file source audit, hashes and scoped
  `git -c core.autocrlf=false diff --check` passed in 0.470 seconds.
  Source checks stayed below the 30-second budget.

The edit scope is the five assigned test files plus this note. Production sources,
BUILD files and workflows were not edited. No CI, commit, network, account or plugin
operation ran.

## Exact source SHA-256

Hashes cover raw working-tree bytes, including line endings. Prefix:
`telegram-ios/submodules/TelegramCore/Tests/`.

| Source | Before | After |
| --- | --- | --- |
| `ExteralessTLReviewTests.swift` | `4661dbad81af66436b10b93e860f1d63c484a264a32accf957872f3cd8b716db` | `9967717c0da00ac6cb8f87e49c362d6b2b98b082cb907429f616c33746161526` |
| `ExteralessDialogReviewTests.swift` | `f50f28d41c043a9450c1fffd3a81ccb094373bc7a51bf5394155655f5b1bb404` | `115705a28354b92ecc08e0160420e390dea8f93d20efe2b1961b5b16a35d7f88` |
| `ExteralessRetentionTests.swift` | `a205007cc5f82d14284210bdd15f45f151b06e65b3cfda4b96a1bfbe999b7bf5` | `763c03e6413db9f7a0db40468f4f2e8183135beae91034f80a27bbd76b25c502` |
| `ExteralessStickerReviewTests.swift` | `a8f0b4b64901b92d5031d3fcf51dd288e3102ce69b8d1e057d83cbb58eb096ee` | `8b83dc4af83de9962734ae36a17f0f0ea70cc791ecb9e9d72314b1ac8b84bb59` |
| `NetworkCredentialLogTests.swift` | `bbb79bcc6080d3b028ad4b29ea511608a4e02a727386a41712ddf95dbebbff22` | `dcd9a7634b0891af885a39a64f0c84f31a177c97fc099c914ffb17708deffc31` |

The five-source Git diff captured with
`git -c core.autocrlf=false diff --no-ext-diff --binary -- <five assigned paths>`
is **9989 bytes**, SHA-256
`bc99b4ba14fd8e85e87a45b42963da0853ad0f3d85284621a3e8b4e3936f729c`.
These postimages identify the authorized fixture delta for the coordinator's next
native compilation/execution gate.
