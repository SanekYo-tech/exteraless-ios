# Privacy extras — shared integration receipt

Shared insertion sites from `privacy-extras.md` §§1–9 are connected in source.
**Native readiness still requires the helper fixes and post-commit replay hook
below.** No Swift/UIKit build, XCTest, APNs delivery, panic/account mutation or
visual pass was performed in this Windows session.

## Applied hunks and actual callsites

| HDO section | Applied source / adaptation |
| --- | --- |
| 1 · Composition | `ExteralessClientRuntime`: retained `privacyExtras`, public `PrivacyExtrasFeatures.definitions`, native private-store bootstrap and reload. `privateDefinitions` never enter the shared store/UI/plugin registry. |
| 1 · Lifecycle | Identity replacement calls `clearAccountDomains()` for the nine ordinary domains, then `privacyExtras.update(context:)` owns the expected transition. Full logout/teardown also calls `privacyExtras.clearContext()`. Feed still updates before Appearance; AI hooks, Player and Pills remain installed. |
| Additional Player request | Registered `PlayerFeatures.galleryDefinitions` alongside `PlayerFeatures.definitions` for the already-applied gallery `chats.swipeToPip` consumer. |
| Additional Dialogs request | Registered `DialogFeatures.definitions`, retained/constructed `ExteralessDialogIntegration` after settings configuration, updated it **after** privacyExtras, and cleared it with ordinary account domains. Its 13 definitions were not described as covered by an earlier Core CI snapshot. |
| 2 · History | First display loop of `ChatHistoryEntriesForView` calls `exteralessFilterHistoryEntries`, with `translated: associatedData.translateToLanguage != nil`. Backing view, additional data, holes, validation and native read states remain the original inputs. |
| 2 · Invalidation | `AccountViewTracker.wrappedMessageHistorySignal` and `wrappedChatListView` combine the original signal with `ExteralessFilteringRuntime.shared.changes` before `withState`. They re-emit the native view, not a fabricated/projected replacement. Post-replay hook is handed to TL below. |
| 3 · UI chat lists | **Already applied by Dialogs owner, verified directly:** `ChatListNodeLocation.swift:201–245` calls `exteralessDialogProjectList` once; `ExteralessDialogList.swift:66–71` calls `exteralessFilterChatList` once. Common wrapper covers ordinary initial/navigation/scroll, forum and saved-topic branches, with privacy projection before Dialogs sorting. No filter was added to native sub-branches. |
| 3 · Non-UI chat lists | `TelegramEngineMessages.chatList(group:count:)` combines native view and filtering changes, converts to `EngineChatList`, and applies exactly one privacy projection. |
| 3 · OS badge | `AuthorizedApplicationContext.applicationBadge` delegates to `exteralessPrivacyExtrasApplicationBadge`. Its existing helper uses filtered totals or zero to withhold an unproven OS number; incomplete list counts remain native presentation dots. |
| 4 · Reactions | `EngineMessageReactionListContext.state` combines raw state and filtering changes on the implementation queue; only subscriber output is filtered. Native internal state, total offsets and pagination are not rewritten. |
| 4 · Native blocked list | `BlockedPeers` updates the exact account/peer cache after `.boolTrue`. `BlockedPeersContext.add`, `remove`, and successful bulk `updatePeerIds` publish the same exact-peer callback for `.blocked` only. `.stories` never updates this filter row; false native results are not claimed successful. |
| 5 · Main notifications | `ApplicationContext.notificationMessagesDisposable` wraps its state-manager source in `exteralessPrivacyExtrasNotifications`; native downstream checks/finalizers remain. |
| 5 · Extension bootstrap | NotificationService reloads public privacy/filter definitions and the private store after the existing PasscodeEnvironment configuration. It uses the actual `sharedAccessGroup()` and `keychainScope`; bootstrap failure follows the failable handler/empty delivery path. |
| 5 · Extension presentation | One `ExteralessPrivacyExtrasNotificationGate` per delivery; stamped into every content variant. Identity binds to native record ID, user ID and network environment. Both cached and post-poll message transactions evaluate before sender/media/emoji construction. OAuth exemption is only native `loc-key == OAUTH_REQUEST`. |
| 5 · Story/call and deadline | Identified stories/calls receive their non-message decision; hidden identity is still checked. Both direct CallKit forwarding branches reload/check hidden state before forwarding. `finish` reloads both stores, gates generated/raw fallback, performs lock redaction, then rechecks the gate. No deadline fallback bypasses it. |
| 5 · Extension numeric badge | Content carries the resolved identity. Both locked and normal generators withhold native numeric badges when sender/text filtering is active, because the extension has no complete projected account total. Raw counters still feed native protocol work. |
| 6 · Downloads | InChatPrefetchManager checks each actual message before adding its fetch ID, observes filtering changes on main and disposes that subscription. PrefetchManager adds the changes input and filters actual `chatHistory.media.index.id` values before starting fetches. User-initiated fetch paths are not repurposed. |
| 7 · Local restrictions | `PeerUtils.restrictionText` and `RestrictedContentMessageAttribute.platformText` return nil only for the local notice setting. Sensitive flags/consent, membership, server results and actual media availability retain their native checks. |
| 7 · Zalgo | `stringWithAppliedEntities` filters its final attributed **`string`** only when `message != nil`; the HDO's `return result` was not the actual function return (that belongs to the syntax-highlight spec collector). Twelve user/group/channel/community name-return sites in `PeerTitle` are display-only wrappers; `IndexName` ordering is unchanged. |
| 7 · Protected copy | Inserted into the granted `ChatInterfaceStateContextMenus.contextMenuForChatPresentationInterfaceState` augmentation, not a second outer menu hook. Only normal/message subjects qualify; it is independent of stock `canForward`. Existing stock copy-protection decisions and AI/chat/plugin additions remain. Native helper rechecks the opt-in feature and writable destination/send pipeline. |
| 8 · Real PIN | Added `PasscodeCredentialStore.verifyAppUnlock` under its existing serialized credential/device/attempt lock. Ordinary crypto verification wins; only its failure evaluates the alternate proof. Failed PIN increments the native cooldown counter. Alternate success returns **no PasscodeSession**. |
| 8 · PasscodeUI | App-lock-only routing, opaque attempt/authorization, optional session result, lifecycle and attempt-identity rechecks, background/stop/deinit cancellation. Cancellation targets a non-nil owned attempt; it does not globally cancel another screen via `cancel(nil)`. Secure/resource/settings biometric flow is unchanged. Normal LocalAuth can authorize visible identity only, with `explicitPasscodeEntry: false`; no panic path. |
| 9 · Hidden account consumers | Shared account-info publication filters visible accounts and observes private changes. `switchToAccount` gates before switchingData/current-record mutation. AppDelegate's other-account shortcut title and authorization phone list, ApplicationContext's switch action and BotAccountRouter filter raw accounts by native identity. |
| 9 · Share | Existing entitled PasscodeEnvironment precedes private bootstrap. ShareExtensionContext's actual raw-account picker filters hidden accounts, selects a visible primary fallback or uses its existing unauthorized error path, and rechecks account visibility before retaining its connection. |
| 9 · Recovery URL | Incoming AppDelegate routes and external OpenUrl consume `https://t.me/nasettings/<component>` locally **before** existing NativeServiceOpenHooks/ordinary web handling. Invalid/unavailable capabilities stay local too. The native handler still requires the exact stored key and a real ordinary `.settings` PasscodeSession. AppDelegate waits for ready/unlocked UI and rechecks the same context; no key is logged or passed to a plugin/web opener. |
| 9 · Temporary previews | DocumentPreviewController receives the actual Account, captures full identity and registers the real TempBox handle. Registration failure disposes it and exposes no unmanaged preview. Deinit releases via the identity registry, safely after panic cleanup too. Both OpenChatMessage callers pass Account; their existing file-open barrier remains single. |

### Root/lock stream evidence

AppDelegate's PasscodeEnvironment configuration precedes its existing shared-root
configure call, which precedes SharedAccountContext/account UI construction. No new
entitlement or guessed keychain group was introduced.

The authorized-context stream maps **raw primary** from `activeAccountContexts`.
`SharedAccountContext` selects the requested loaded primary or falls back to the
first live account before publishing; an expected A→B switch is not synthesized
as nil. The separate unauthorized/auth-context nil emission does not call the
client root's teardown. Full authorized nil (no live account) still clears extras.
The real app-lock PasscodeEntryController is owned by the shared `AppLockContextImpl`,
not the unused `AuthorizedApplicationContext.passcodeController` slot.

Root now exposes `accountPresentationReady(for:)`. AppDelegate publishes it only
after `context.isReady`, a `contextValue === context` check, and installing
`mainWindow.viewController = context.rootController`. Ordinary-domain teardown resets
it. This is presentation readiness, **not authentication**. The helper must consume
that signal as shown in Fix A before PasscodeUI may uncover the lock.

## Native-owner helper fixes required before readiness

These helper implementations remain with their native owner. The following are
source-confirmed defects and concrete fixes, not claims of an executed device test.

### Fix A — wait for the actual root before finishing hidden unlock

`TelegramUI/Sources/ExteralessClient/PrivacyExtras/ExteralessPrivacyExtrasIntegration.swift:58–71`
currently finishes on raw primary identity alone. AppDelegate creates/installs the
AuthorizedApplicationContext later, while `AppLockContextImpl.unlock()` removes
the cover immediately. This can expose the old account during the handoff.
The Root/AppDelegate half above is already applied. The remaining helper edit is:

```diff
-            self.switchDisposable.set((combineLatest(shared.activeAccountContexts, shared.applicationBindings.applicationInForeground)
-            |> map { accounts, foreground -> Bool? in
+            self.switchDisposable.set((combineLatest(shared.activeAccountContexts, shared.applicationBindings.applicationInForeground, ExteralessClientRuntime.shared.accountPresentationReady(for: identity))
+            |> map { accounts, foreground, ready -> Bool? in
                 if !foreground { return false }
                 guard let primary = accounts.primary else { return nil }
-                return exteralessPrivacyExtrasIdentity(primary.account) == identity ? true : nil
+                return ready && exteralessPrivacyExtrasIdentity(primary.account) == identity ? true : nil
```

Keep the opaque consumed authorization, five-second wait, cancellation and existing
`finishUnlock` call; do not replace this with an independently passed Bool.

### Fix B — incomplete filter evaluation is not notification approval

Core `FilteringDecision` intentionally has `isHidden == false, incomplete == true`
for exhausted input/work budgets. Two native consumers currently check only
`isHidden`, so a reversed/unfinished rule can become an allowed alert.

`TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFilteringNotifications.swift`,
in `exteralessPrivacyExtrasNotificationDecision`, after `policy.decision`:

```diff
-        return decision.isHidden ? .suppress : .allow
+        if decision.isHidden { return .suppress }
+        return decision.incomplete ? .awaitMessage : .allow
```

`TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFiltering.swift`,
in `exteralessFilterNotificationMessages`, replace the filter predicate's tail:

```diff
-        let group = messages.filter { $0.groupingKey != nil && $0.groupingKey == message.groupingKey && $0.id.peerId == message.id.peerId && $0.threadId == message.threadId }
-        return !policy.decision(exteralessFilteringMessage(account: account, message: message, group: group, oauthNotification: oauthNotification), surface: .notification, budget: &budget).isHidden
+        let group = messages.filter { $0.groupingKey != nil && $0.groupingKey == message.groupingKey && $0.id.peerId == message.id.peerId && $0.id.namespace == message.id.namespace && $0.threadId == message.threadId }
+        let decision = policy.decision(exteralessFilteringMessage(account: account, message: message, group: group, oauthNotification: oauthNotification), surface: .notification, budget: &budget)
+        return !decision.isHidden && !decision.incomplete
```

The second change also retains namespace in album scope. Fixture: exhaust a tiny
NFA budget on a reversed rule and verify no title/sound/attachment is admitted by
either native notification consumer. No unbounded regex evaluation is needed.

### Fix C — publish hidden presentation transitions and retire replaced accounts

`TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessHiddenAccounts.swift` currently
publishes `changes` only for private-configuration writes/reload. `consume` can
reveal the already-selected hidden account without a raw account-list update;
Dialogs' previously empty projection then receives no invalidation. Also, `update`
compares policy identities only, so replacing an Account object with identical
record/user/environment can retain an old attempt.

Keep configuration revision separate from presentation invalidation:

```diff
     private var revision: UInt64 = 0
+    private var presentationRevision: UInt64 = 0
@@
     public var changes: Signal<UInt64, NoError> { changesPromise.get() }
+    public func invalidatePresentations() {
+        lock.lock()
+        presentationRevision &+= 1
+        let value = presentationRevision
+        lock.unlock()
+        changesPromise.set(value)
+    }
@@ public func update(accounts: [Account], current: Account?, foreground: Bool, locked: Bool) {
         lock.lock(); defer { lock.unlock() }
+        if accounts.prefix(HiddenAccountPolicy.maximumAccounts).contains(where: { account in
+            let identity = exteralessPrivacyExtrasIdentity(account)
+            return self.accounts[identity] != nil && self.accounts[identity] !== account
+        }) {
+            policy.cancel(nil)
+        }
         orderedIdentities = accounts.prefix(HiddenAccountPolicy.maximumAccounts).map(exteralessPrivacyExtrasIdentity)
@@ private func updatePolicy() {
         policy.update(configuration: configuration, accounts: orderedIdentities, current: current, foreground: foreground, locked: locked, available: !failed && storage != nil)
+        invalidatePresentations()
     }
     private func publish() {
         revision &+= 1; updatePolicy()
-        changesPromise.set(revision)
     }
```

In `ExteralessHiddenAccountUnlock.complete`, immediately **after successful consume**:

```swift
ExteralessHiddenAccounts.shared.invalidatePresentations()
```

In the handler's failure branch, after `policy.abandonUnlock(authorization)`, also
invalidate before `completion(false)`. For failed `finishUnlock`, invalidate before
returning false. Successful AppLock state transition reaches `updatePolicy` above.
This wakes the one-way presentation consumers without changing private credentials,
configuration revision, native messages or counts. `cancel(nil)` in this fix is only
for an actual native Account replacement, not a generic PasscodeUI dismissal.

### Fix D — distinguish account loading from a confirmed empty account set

`ExteralessHiddenAccounts.requiresUnlockRouting` currently checks only codes for
`orderedIdentities`. During cold bootstrap that list is empty, before the first
native account snapshot. A stored hidden-account code without a panic code can
therefore fall through to ordinary app unlock while accounts are still loading.
Conversely, a global panic code with a genuinely empty account set must not trap
the logged-out app in an alternate-auth flow that cannot begin an attempt.

The root's confirmed-nil path now calls `ExteralessHiddenAccounts.clearContext()`
even if its integration has not been constructed. The native helper needs:

```diff
     private var orderedIdentities: [PrivacyExtrasAccountIdentity] = []
+    private var hasAccountSnapshot = false
@@ public func update(accounts: [Account], current: Account?, foreground: Bool, locked: Bool) {
         lock.lock(); defer { lock.unlock() }
+        hasAccountSnapshot = true
@@ public func clearContext() {
         lock.lock(); defer { lock.unlock() }
+        hasAccountSnapshot = true
@@ public var requiresUnlockRouting: Bool {
         lock.lock(); defer { lock.unlock() }
-        return failed || hasPanicCode || orderedIdentities.contains { state($0).hasPasscode }
+        if hasAccountSnapshot && orderedIdentities.isEmpty { return failed }
+        let accountCodeConfigured = hasAccountSnapshot
+            ? orderedIdentities.contains { state($0).hasPasscode }
+            : !values("passcodeHash").isEmpty
+        return failed || hasPanicCode || accountCodeConfigured
```

Unknown accounts with stored codes stay covered until an actual snapshot allows
the opaque attempt. A confirmed, available empty set uses ordinary native PIN
authorization; it neither fabricates an account nor executes panic.

## TL-owner post-commit replay hunk (not applied here)

`AccountStateManagementUtils.replayFinalState` takes an already-open `Transaction`;
inserting before its return is **inside** the transaction. The suitable post-commit
sites are its six callers in `TelegramCore/Sources/State/AccountStateManager.swift`.
Append `afterNext` immediately after each replay transaction, before existing tuple
mapping/delivery. Keep its original emitted value and every native PTS/QTS/sequence.

For `Signal<AccountReplayedFinalState?, NoError>`:

```swift
|> afterNext { value in
    if value != nil { ExteralessFilteringRuntime.shared.invalidatePresentations() }
}
```

For the difference tuples (the actual field is spelled **`finalStatte`**):

```swift
|> afterNext { value in
    if value.finalStatte != nil { ExteralessFilteringRuntime.shared.invalidatePresentations() }
}
```

| Caller anchor, at inspection | Result shape / insertion |
| --- | --- |
| Channel reset replay at `:748–779`, call `:753` | Optional, before `deliverOn(self.queue)` |
| `pollDifference` replay at `:910–928`, call `:912` | Four-field tuple; after transaction close |
| `processUpdateGroups` replay at `:1052–1070`, call `:1057` | Optional, before `map { ($0, finalState) }` |
| `.replayAsynchronouslyBuiltFinalState` at `:1360–1374` | Optional, before tuple map |
| `standaloneReplayAsynchronouslyBuiltFinalState` at `:1413–1427` | Optional, before tuple map |
| `standalonePollDifference` at `:1494–1525`, call `:1496` | Three-field tuple; after transaction close |

This is independent of the Dialogs pin-echo hook and the TL mutation pipeline.
No edit was made to Network, Account.swift, AccountStateManagementUtils,
UpdateMessageService, Host, C or Python.

## Exact changed files

Paths below are relative to `telegram-ios/`:

- `submodules/TelegramUI/Sources/AppDelegate.swift`
- `submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`
- `submodules/TelegramUI/Sources/SharedAccountContext.swift`
- `submodules/TelegramUI/Sources/ApplicationContext.swift`
- `submodules/PasscodeCore/Sources/Passcode.swift`
- `submodules/PasscodeUI/Sources/PasscodeEntryController.swift`
- `Telegram/NotificationService/Sources/NotificationService.swift`
- `Telegram/NotificationService/Sources/ExteralessNotificationPrivacy.swift`
- `submodules/TelegramCore/Sources/State/AccountViewTracker.swift`
- `submodules/TelegramCore/Sources/State/MessageReactions.swift`
- `submodules/TelegramCore/Sources/TelegramEngine/Privacy/BlockedPeers.swift`
- `submodules/TelegramCore/Sources/TelegramEngine/Privacy/BlockedPeersContext.swift`
- `submodules/TelegramUI/Sources/InChatPrefetchManager.swift`
- `submodules/TelegramUI/Sources/PrefetchManager.swift`
- `submodules/TelegramUI/Sources/ChatHistoryEntriesForView.swift`
- `submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift`
- `submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift`
- `submodules/TelegramCore/Sources/Utils/PeerUtils.swift`
- `submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift`
- `submodules/TextFormat/Sources/StringWithAppliedEntities.swift`
- `submodules/LocalizedPeerData/Sources/PeerTitle.swift`
- `submodules/TelegramUI/Sources/ExteralessClient/Privacy/ExteralessBotAccountRouter.swift`
- `submodules/TelegramUI/Sources/OpenUrl.swift`
- `Telegram/Share/ShareRootController.swift`
- `submodules/TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift`
- `submodules/TelegramUI/Sources/DocumentPreviewController.swift`
- `submodules/TelegramUI/Sources/OpenChatMessage.swift`
- `submodules/Postbox/AllowedPostboxAccess.txt` — removed only OpenChatMessage's stale entry after its last two direct accesses became Account arguments; no allowlist expansion.

Receipt: `docs/wave-2/privacy-extras-integration.md`.
ChatListNodeLocation was verified but not changed: its already-connected owner
wrapper is the required composition boundary.

## Source verification

- Official `python -B build-system/Make/PostboxImportCheck.py` from `telegram-ios`:
  **one invocation, exit 0**. No allowlist entry was added.
- Targeted `git diff --check`: passed on the applied shared sources.
- Bounded read-only Swift source checks: delimiter/comment/string sanity, no
  Markdown headings; source ordering/bootstrap/public-private registration; actual
  root readiness publication; PIN-priority/cooldown and non-nil attempt cancellation;
  no hidden routing in secure biometrics; per-delivery notification gates and both
  OAuth transaction inputs; badge withholding; exact one-way list coverage;
  successful exact-peer block callbacks; prefetch lifetime; explicit protected-copy
  entry; existing URL/file barrier counts; TempBox identity; nil-message display
  guard and unchanged name sorting. Passed. These are not Swift typechecking.
- No BUILD edits. Build owner should include the new explicit ExteralessCore import
  in `//Telegram:ShareExtensionLib`; PasscodeUI's direct Core dependency was already
  present when inspected. Native CI must check the complete app graph.
- No commit/push/CI/network action or real-account test. The owner's 20 prepared Core
  tests and the reported earlier CI snapshots are not claimed as execution evidence
  for these UIKit/TelegramCore insertions or newly composed Dialogs code.

## Native and frame acceptance (pending)

1. Hidden unlock: synthetic A→B, same-account reveal, unrelated/same-identity object
   replacement, slow root, timeout, background and cancellation. Cover stays until
   the actual target root is ready; no old-account frame. Wrong PIN, ordinary PIN,
   biometric and resource/settings PIN never execute panic. Ordinary PIN has priority.
2. Panic: **injected effects/synthetic identities only**; exactly configured eligible
   native record/user/environment targets, one consumed grant, transaction-time identity
   recheck, exact tracked TempBox handles, no effects for stale/wrong/cancelled input.
3. History/list: hidden album rows and separators move together; original anchors,
   drafts, native ordering/rights and read boundaries persist. Incomplete unread data
   shows a dot, not an invented number. Repeat ordinary/forum/saved and Dialogs sorting.
4. Notifications: foreground/background/deadline, hidden account, incomplete/reversed
   rules, changed settings mid-delivery, OAuth, stories and calls. No leaked title,
   subtitle, attachment, sender intent, sound or unproven numeric badge; no duplicate
   watch alert. APNs provider/signing/delivery remains a separate physical-device check.
5. Zalgo: final attributed display spans retain correct links/emoji/colors; editable
   nil-message input and stored text/entities are unchanged. Light/dark/RTL/large text.
6. Protected copy: opt-in only, one menu item, normal/scheduled/service exclusions,
   real cached-media prerequisite and writable paid/bot/topic send path. Cancel keeps
   drafts. Temp preview cleanup remains identity-scoped and once-only.
7. Recovery: exact valid key requests ordinary Settings PIN locally; invalid key,
   unavailable vault and missing presenter do not reach plugin/web hooks. Share and
   account pickers show visible accounts only, including a hidden primary fallback.

Record and evaluate labelled frames according to `telegram-ios/AGENTS.md` before
claiming visual correctness. No visual claim is made by this receipt.
