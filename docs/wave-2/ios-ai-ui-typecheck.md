# iOS AI UI typecheck follow-up — f05473ea

2026-11-16. **Three AI source fixes applied. The coordinator must apply the
one-line shared-runtime deletion below. Actual native Swift/UIKit compilation
remains pending.**

## Input and exact scope

- Failed full-iOS run: **43761767575**, commit
  `f05473ea63ffd568fff92dfa1fd7414fd53c2c12`.
- Local log: `C:\Users\sasha\AppData\Local\Temp\opencode\ipa-f05473ea-failed.log`.
  Raw SHA-256: `44bbe728503d02f3103b75119344ad0ad4a710722195c63e88e752c6532ee749`.
- Inspected working-tree base: `4bcf80a0d7160264accbb6b415facde82cf87928`.
- Edited production files:
  1. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift`
  2. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIResultController.swift`
  3. `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift`
- New handoff: `docs/wave-2/ios-ai-ui-typecheck.md`.

The three owned diagnostics are the missing Markdown helper at integration line
498, concurrently captured weak `self` at result-controller line 215, and
cross-file `Sendable` conformance at runtime line 436 in the failed build.

## Repairs and preserved semantics

### Markdown module

`ExteralessAIIntegration.swift:2` now imports `BrowserUI`. The actual public API
is `markdownStringFromInstantPage(_ instantPage: InstantPage) -> String` in
`telegram-ios/submodules/BrowserUI/Sources/InstantPageToMarkdown.swift:16`.
`BrowserUI/BUILD:9-14` includes that source in module `BrowserUI`.
`telegram-ios/submodules/TelegramUI/BUILD:417` already supplies the direct
`//submodules/BrowserUI:BrowserUI` dependency; the build-tooling owner needs no
additional import edge for this fix.

The original `display.page.map(markdownStringFromInstantPage) ?? display.text`
expression is preserved at line 499. Rich pages still use the canonical Markdown
conversion, including its heading/list/table/code/quote handling; the existing
text branch remains exclusive to absent pages. The change introduces no helper
copy or plaintext replacement for rich pages.

### Weak event delivery

`ExteralessAIResultController.swift:213-217` resolves the callback's weak `self`
once into an immutable strong binding **inside each event callback**, immediately
before `await MainActor.run`. The main-actor closure captures that immutable
binding. Its `requestId == id` and `.running` checks still execute on main after
the hop, before `receive` changes any mutable UI state.

The outer request task and the escaping event callback retain their weak capture
lists. A controller is retained only for an event's delivery, rather than for the
whole provider request. Close, disappearance, invalidation and retry continue to
revoke the request identity; events queued before those transitions are discarded
on arrival. Completion still validates access, checks cancellation/identity/state,
and finishes the lease once before publishing the latest result. Cancellation
still revokes access synchronously before cancelling the task. The synchronous
deinitializers acquire no escaping `self` capture.

### Native adapter conformance and actual threading contract

`ExteralessAINativeAdapter.swift:14-18` keeps the existing `@MainActor` class and
declares `ExteralessAIEngineAdapter` directly on its original declaration. The
shared public protocol is defined in
`telegram-ios/submodules/AccountContext/Sources/ExteralessAIHooks.swift:7-15`:
it is `@MainActor`, inherits `AnyObject, Sendable`, and has six requirements whose
signatures match the adapter's existing public witnesses.

This uses the existing checked global-actor contract, with no new
`@unchecked Sendable`. The adapter's weak integration, generation and operation
dictionary are main-actor state. Its `signal` method at lines 305-313 registers
`isCurrent`, `started` and `ended` callbacks, each explicitly `@MainActor` in
`ExteralessAINativeRequest.swift:8-24`. That bridge executes admission and delivery
inside a main-actor task and rechecks both generation ownership and cancellation.
The facade enters adapter methods via the main queue and
`MainActor.assumeIsolated` (`ExteralessAIHooks.swift:43-61`). Its cross-thread
adapter lease storage is already protected by `NSLock` (lines 17-27).
Cross-thread operation cancellation remains guarded by `NSRecursiveLock` in
`swift/ExteralessCore/Sources/ExteralessCore/AINativePolicy.swift:5-37`.

The source comparison confirms every other production line matches the pinned
base after LF normalization. Request/generation ordering, source/lease checks,
provider selection and credentials, draft insertion, latest-result publication,
and settings/sidebar registration retain their existing implementation.

## COOR: exact shared-runtime patch (not applied here)

Apply this deletion together with the adapter declaration change, before native
compilation; until then the old extension duplicates the new conformance.
The current runtime has the extension at line 445. The patch removes only that
line and leaves the shared Search/Reset bindings outside its hunk.

```diff
diff --git a/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift b/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
--- a/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
+++ b/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
@@ -442,4 +442,3 @@
     }
 }

-extension ExteralessAINativeAdapter: ExteralessAIEngineAdapter {}
```

LF-normalized runtime SHA-256 at the dry run:

- Before: `5041de7b3d2e5d0098ec61773eef3617a63984dd167b946e443e1c5242fd48e8`
- After this deletion only, computed in memory:
  `91dd280e32ba6feb8451a4f88e3f757ac4d3ebb7dbbf13d391bb22ef2b452348`

## Source checks and native status

- Scoped `git diff --check` passed for the three edited production files.
- A read-only Python check compared the complete files against the pinned base:
  exactly one import, one event-capture correction, and one conformance-declaration
  correction. UTF-8/NUL checks passed.
- The same check matched all six actual protocol requirements to existing
  witnesses and verified the helper's public declaration and direct BUILD edge.
- `git apply --check -` accepted the exact coordinator patch above. Runtime bytes
  were identical before and after the dry run.
- The combined source check completed in **0.222 seconds**, under a 30-second
  tool timeout. Local `swift`/`swiftc` were unavailable on PATH.

These are source checks, not a native typecheck or execution pass. The next
coordinator-owned full `//Telegram:Telegram` build must confirm elimination of
all three diagnostics with the runtime deletion applied. Existing
`//submodules/TelegramUI:ExteralessAINativeTests` and native streaming
close/cancel/retry/late-event behavior remain pending. No CI, network, accounts,
foreign plugins or commits were used for this work.

## Source pins

SHA-256 of UTF-8 sources with CRLF normalized to LF, after these edits:

```text
208b621139168b8d0bf2bef4bcbcd6552871f31a12d288d065ec20cb2becd3da  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift
830e7afc912a6fa968d77e05fe4adb3e6d858044935614759d4332d877280335  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIResultController.swift
5fe564404b98453de32041b33120e18f51b82fc592e69e7da9fe8dd303331109  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift
```

Read-only API/threading contracts inspected:

```text
a40a3411f2938ea171c45bcec63fee4bc56589f24080866f7ee8923e8136d45a  telegram-ios/submodules/AccountContext/Sources/ExteralessAIHooks.swift
013f678fde9f21ea6446af807d7b44be8bfeb3c7172362fd58687358a08ff748  telegram-ios/submodules/BrowserUI/Sources/InstantPageToMarkdown.swift
9be6449749bfc7224b4093fd4eff115e3d822b39f7334d11027c9f09428afa92  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeRequest.swift
ccba9509562225a25dbf2650485798cb12dd7531688155c5e202d39857fa4a81  swift/ExteralessCore/Sources/ExteralessCore/AINativePolicy.swift
```
