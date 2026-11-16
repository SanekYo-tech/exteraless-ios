# Native AI fixture Swift 6 type repair — 43812503558

**Status: source checks passed; `actualUIKitXCTest` native compilation and execution pending.**

Evidence: `build/artifacts/client-ui-43812503558/native-tests/compile/console.log`,
lines 1845–2098 (`//submodules/TelegramUI:ExteralessAINativeTestsLib`).
Local source-comparison baseline: `93dcb653d408e45fe1327ee2ee945952520548b4`.

## Repairs

- `ExteralessAIFollowupNativeTests.swift`, former lines 192/260: construct each
  real `exteralessAINativeRequest` Signal in the `@MainActor` test, then return it
  from the existing button request callback. `MainActor.assumeIsolated` no longer
  has to return a non-Sendable Signal. The production generator creates the task,
  completion state and generation UUID per subscription; its default lease is
  also subscription-local. The queued-commit case still supplies `scope.lease`.
  The button still starts/disposes the real producer, including selected-provider
  routing, queued Postbox cancellation and terminal/generation handling.
- The same file, former line 416: construct
  `ComponentTransition(animation: .none)`, matching the production preset's
  initializer without reading mutable static `.immediate`.
- `ExteralessAINativeUITests.swift`, former lines 64/68/100/102/104: both
  translation tasks are explicitly `Task<Void, Error>` with `@MainActor` bodies.
  The success case stores the real translated `InstantPage` in the actor-isolated
  `AINativeUIPageResult`, then unwraps it on that actor after awaiting completion.
  The cancellation case consumes the native result inside its actor body and
  retains the failure assertion if the task succeeds. Only completion/error
  crosses the test task boundary. The five-leaf barrier, seven-block assertion,
  peak-concurrency assertion and cancel-before-release ordering are retained.

The existing native translator, Signal producer, UIKit button and Postbox commit
paths remain the exercised implementations. No new API stubs, Sendable escape
hatches, skips or test-ID changes were introduced.

## Local verification

- Bounded Python source check: **0.136 s**, within the 30-second cap. Compared
  against the baseline: all **14 test IDs** (6 follow-up, 8 native UI) and all
  **137 existing assertion/unwrap calls** (98 + 39) retained; one result unwrap
  added. Checked both real producer call sites and the explicit actor/task shapes.
- The four production files inspected below have identical pre/post-edit hashes.
- Scoped `git diff --check` passed.
- This Windows environment has no `swiftc` on PATH. No Swift typecheck, iOS build
  or native XCTest execution was performed. These source checks do not establish
  a native pass; the repaired fixtures still require native compile/run evidence.

## Source SHA-256

Raw working-tree bytes, including line endings; paths are repository-relative.
The first two entries are repaired test sources; the remaining entries are the
read-only production sources used to verify API and lifecycle equivalence.

```text
0d01a91e249bb725352465ad701811f828eabef0a4c66a4dc0696a5eb43a723c  telegram-ios/submodules/TelegramUI/Tests/AI/ExteralessAIFollowupNativeTests.swift
6feef489bcec22d4f091931d93afc3425c5c6b25cc8ba71bfa8e2f9d120a7b07  telegram-ios/submodules/TelegramUI/Tests/AI/ExteralessAINativeUITests.swift
9be6449749bfc7224b4093fd4eff115e3d822b39f7334d11027c9f09428afa92  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeRequest.swift
78ae2bdbb456b8b67a8d7a037c517f601f7098b565a6b4d51012f568ac189df7  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIRichTextTranslator.swift
aaafc3f86c873d34c303da5835d812e976c1b1cf99e017c8d1496a799ed6e997  telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveInstantVideoNode/Sources/ChatMessageInteractiveInstantVideoNode.swift
ffd0854a4a1e2a04168920dfcc644c7d5bb21dadebe4007884ec5121d12a235f  telegram-ios/submodules/ComponentFlow/Source/Base/Transition.swift
```
