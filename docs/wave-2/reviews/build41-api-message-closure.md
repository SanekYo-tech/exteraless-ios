# Build 41: API presentation-message P2 closure

## Reviewed scope

- Base HEAD at review: `3d6abfe10be9d85c2fbf235eb286a0209ed3a758`.
- Reviewed the working-tree `AppDelegate.swift` hunk that clears a superseded bootstrap presentation message before the first settings gate opens and consumes an API presentation event after all presentation guards pass.
- Production review was read-only. This report is the only file created by this review. No CI polling, network, native execution, commit, or push.
- The coordinator reports 11 passing source/smoke tests; this review did not rerun them or treat them as device/first-frame evidence.

## Verdict

**The previously reported P2 stale-message replay is closed at source level for the specified event sequences. No new blocking actor/order defect was found in this hunk.**

The cleared state is `AppDelegate.clientAPIErrorMessage`, a presentation-only string. The canonical Client API environment, launch resolver, configuration store, vault, account pin, and account producer are not reset or changed by this hunk. A scoped diff of the environment/resolver/settings/keychain files was empty.

All AppDelegate references below are to `telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift` as read during this review.

## Exact ordering checks

| Sequence | Source result |
|---|---|
| Bootstrap API failure → Settings recovery → successful Retry → first `.ready` | The API observer retains the message (2051–2058), but presentation is blocked until settings are prepared. First `.ready` clears the superseded message **before** `clientSettingsPrepared = true` and **before** `clientSettingsReady.set` (2010–2016). The following helper call has no obsolete message to present. |
| Account-specific failure after settings gate opens, before first scene | The first-ready clear has already run. The error observer stores the new message; the missing-scene guard returns **before** the consume statement (2102–2109). `attach` makes the window visible and invokes the helper (2220–2223). Subsequent ready events do not execute the first-ready clear. |
| A error → show/consume → OK → `.ready` | Successful guard admission captures A locally and sets pending message to nil (2103–2110). OK clears only the current alert (2111–2113). Later `.ready` finds no pending A and cannot replay it. |
| B emitted while A alert is active | The observer stores B (2054). The existing-alert guard returns before consume (2103), preserving B. A's OK does not clear the pending message. The next eligible `.ready`/`attach` can admit B; it is a new pending event, not a replay of consumed A. |

### Why the first-ready clear does not erase an error from opening the account gate

The order is explicitly:

```text
clear superseded bootstrap UI message
set clientSettingsPrepared = true
publish clientSettingsReady
attempt pending API presentation
```

The SharedContext/account path subscribes behind `clientSettingsReady` (1301 onward). Even if publication synchronously reenters a subscriber, there is no later clear in this `.ready` branch to erase an account-specific error emitted by that subscriber. This distinction matters because SwiftSignalKit `Queue.async` executes inline when already on its queue (`SSignalKit/SwiftSignalKit/Source/Queue.swift:50–65`).

The error observer is delivered on main (2051–2052), and Runtime publishes preparation results from `DispatchQueue.main.async` / `MainActor.assumeIsolated` (`ExteralessClient/ExteralessClientRuntime.swift:212–238`). The new assignments and guards are main-serialized. ValuePromise calls subscribers after unlocking; the consume statement does not add a mutex or wait.

For the bootstrap retry sequence, the API configuration failure publishes its error before the worker reports preparation failure (`TelegramCore/Sources/ExteralessClientAPI/ExteralessClientAPIEnvironment.swift:27–30`; Runtime 103–117). The error delivery and subsequent preparation completion are enqueued on main in that order from the same serial worker. The inspected path does not leave the original bootstrap error queued behind the successful retry's first-ready clear.

### Pending B is intentionally deferred, not automatically drained by OK

OK calls retention presentation, not `presentClientAPIErrorIfNeeded` (2111–2113). Thus B can remain pending until a later helper trigger. This matches the requested narrow behavior; it is not a guaranteed immediate presentation after A dismisses and does not resume account creation. Any future immediate-drain change should respect UIKit dismissal completion.

The pending storage is one latest-message slot, not a FIFO. Also, B here means an error actually emitted by the upstream ValuePromise: the environment retains `ignoreRepeated: true`, so a repeated identical error enum is not necessarily another event. These semantics were not changed or disguised as an error-counter/latch reset.

## Fatal-root and native-presentation boundary

- Both API and Settings recovery helpers reject presentation when `clientLaunchFailure` is present (2105,2121). A late settings result following the write-probe early return cannot use these helpers to present on the old Window1 host behind the standalone diagnostic root.
- Consumption happens after the scene/prepared/preparing/fatal/preparation-alert guards, so a message waiting for those prerequisites is not consumed early.
- Consumption occurs at **presentation admission**, not UIKit completion. `Window1.presentNative` calls `UIViewController.present` without an acknowledgement (`Display/Source/WindowContent.swift:1523–1526`). Actual alert visibility during scene activation or another native modal remains a runtime verification item; this review does not certify it from guard conditions.

## Remaining evidence / open work

- L1 (`accountWithId` completing without a result after Client API failure) remains open. Neither OK nor message consumption restarts its producer.
- First-launch rendering on the reported signed, unchanged-Bundle-ID iOS 27.0.1 installation remains unverified. This closure does not attribute the black screen to signing or absent App Groups.
- Native observations still needed: bootstrap-failure/retry produces no stale API alert; a genuinely pending post-bootstrap error appears after scene attachment; A does not reappear after OK and a reload; emitted B remains available for the next eligible presentation trigger. Record the actual presenter/window and visible frames for presentation claims.
