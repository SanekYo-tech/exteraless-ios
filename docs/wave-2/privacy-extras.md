# Privacy extras — implementation and coordinator handoff

Source WIP supplied in the assigned new files. **Shared hunks below still need
coordinator insertion and native CI. No XCTest/native/visual/APNs pass is claimed.**
No commit, push, CI dispatch, external plugin execution, real panic, logout or
account deletion was performed. `privacy-extras-parity.json` is a separate receipt,
not an edit of the main inventory. Read both Android Java and Kotlin, the wave
contract, Core settings handoff, parity schema, privacy uncovered matrix and the
complete Telegram AGENTS/CLAUDE guides.

## Integration facts

- `PrivacyExtrasFeatures.definitions`: public filter/presentation definitions only.
  `privateDefinitions` must **not** enter `ClientSettings.shared` or the generic UI.
- `ExteralessPrivacyExtrasIntegration`: `init()`, `update(context:)`, `clearContext()`
  on main. Own one instance in `ExteralessClientRuntime`.
- Storage: existing `<telegram-data>/exteraless/client-settings.json` for filters;
  `privacy-extras-private.json` beside it contains only private-store metadata.
  Private values use the actual entitled app-group Keychain service, device-only,
  through `ClientKeychainSecretStore`. No memory fallback or invented entitlement.
- Full identity is environment + **AccountRecordId + Telegram user ID**. Peer IDs
  are decimal strings of packed native IDs; no slot, abs(chatId), or namespace loss.
- The only Postbox row is
  `Namespaces.CachedItemCollection.exteralessLocalState` with key
  **`exteraless.privacyExtras.blocked.v1`**. The coordinator owns the central name
  (63). No clearing of that collection; no `privacy.*` or `retention.*` row is used.
- **No TelegramCore → PasscodeCore edge:** PasscodeCore already depends on
  TelegramCore. `ExteralessNativeHiddenSettingsAuthorization` in TelegramUI validates
  a real `.settings` PasscodeSession through the narrow Core authorization protocol.
  All new UI files are Postbox-import/access free. Crypto/storage/message/account
  operations remain in TelegramCore; the pure policies are Foundation-only.
- Filtered read state is a **presentation value**. Never write a projected state to
  Postbox, use it to replay an update, or use it to advance PTS/QTS/secret sequences.
  Empty/incomplete history is not fabricated. Native protocol ingestion is unchanged.
- Bind all shared hooks before registering the domain as connected. A setting
  definition or the stock native passcode alone is not the hidden-account feature.

## Exact original → native matrix

Android paths in this section are relative to
`third_party/exteraless-android/TMessagesProj/src/main/`. Native names refer to the
new `TelegramCore/Sources/ExteralessPrivacyExtras/` and
`TelegramUI/Sources/ExteralessClient/PrivacyExtras/` directories unless qualified.
All source implementations below are **unverified**, with shared integration pending.

| Exact parity ID; declaration default | Original effect | Actual key / Swift consumer | Mode / prepared evidence |
|---|---|---|---|
| `neko.ignoreBlocked`; false (`NekoConfig.java:88`) | `ChatActivity.java:41609–41628`, `DialogCell.java:3384–3398`, notifications `1229–1236,5550–5557`, `ReactionFilter.java:25–49` | `privacy.ignoreBlocked`; `FilteringConfiguration`, `FilteringPolicy.decision`, native blocked context/row, history/notification/reaction projections | Client-local. `FilteringPolicyTests.testSenderAndReplyScopesMatchOriginalRatherThanServerBlocking` |
| `nagram.blockedChannelsData`; `"[]"` (`NaConfig.kt:460–465`) | `AyuFilter.java:477–570`: negative dialog IDs; sender/channel shadow bans | `privacy.blockedChannelsData`; `setPeer`, `hidesSender`, native projections | Account-scoped object of packed peer-ID arrays; no server block RPC |
| `nagram.customFilteredUsersData`; `"[]"` (`NaConfig.kt:466–471`) | `AyuFilter.java:608–765`, `isCustomFilteredPeer`: positive user IDs | `privacy.customFilteredUsersData`; same native writer and policy; native peer selector/removal UI | Stores native identity, not another account's Android access hash. Identity/namespace test |
| `nagram.regexFiltersEnabled`; false (`NaConfig.kt:430–435`) | `AyuFilter.java:259–308`; DownloadController `617,679,882`; notifications skip OAuth | `privacy.regexFiltersEnabled`; `FilteringPolicy.decision`, `exteralessFilteringMessage`, prefetch helpers | Native NFA and display/download/notification hooks; bounded adversarial tests |
| `nagram.regexFiltersData`; `"[]"` (`NaConfig.kt:436–441`) | `AyuFilter.java:44–107,245–253,768–817`: enabled, reversed, ASCII case-insensitive, MULTILINE find | `privacy.regexFiltersData`; `FilteringRule`, `FilteringRegex`, rules list/editor | Account-scoped rule array; unsupported Java regex constructs visibly rejected |
| `nagram.regexChatFiltersData`; `"[]"` (`NaConfig.kt:448–453`) | `AyuFilter.java:221–237,310–420`: chat rules precede shared rules | `privacy.regexChatFiltersData`; per-account/per-peer rule editor and policy | Per-chat rules still run in private chats when shared-private mode is off |
| `nagram.regexFiltersEnableInChats`; false (`NaConfig.kt:442–447`) | `AyuFilter.java:240–243`: private-dialog gate applies only to shared rules | `privacy.regexFiltersEnableInChats`; `FilteringPolicy.decision` | Private/secret scope explicitly represented; rule priority test |
| `nagram.regexFiltersExcludedDialogs`; `"[]"` (`NaConfig.kt:454–459`) | `AyuFilter.java:280–283,422–462`: exclude both rule sets, independent of sender filters | `privacy.regexFiltersExcludedDialogs`; chat editor and policy | Namespace/account isolated; exception/OAuth/outgoing tests |
| `neko.ignoreContentRestrictions`; true (`NekoConfig.java:158`) | `MessagesController.java:23176–23210`: skips local hard notice, separate sensitive consent | `privacy.ignoreContentRestrictions`; `exteralessIgnoreLocalRestrictionNotice`, two presentation hunks below | Client notice only. Server ban/membership/rights and missing content remain real |
| `nagram.zalgoFilter`; false (`NaConfig.kt:204–209`) | `MessageHelper.java:888–889,953–981`: UTF-16 length 4…2048, four consecutive marks trigger removal of all marks, preserving spans | `privacy.zalgoFilter`; `FilteringTextPolicy`, `exteralessZalgoDisplayText` | Display strings only. Attributed/astral UTF-16 test; text/name renderer hunks below |
| `nagram.forwardProtectedAsCopy`; false (`NaConfig.kt:1446–1451`) | `ChatActivity.java:13476–13535,50903–50922`; `MessageHelper.java:1348–1444` | `privacy.forwardProtectedAsCopy`; `exteralessPrepareProtectedCopies`, `exteralessProtectedCopyAction` | New native sends from actual local text/sticker/cached photo/file; not a forward RPC or server-unban promise. Missing media yields a real download prerequisite |
| `passcodehelper.accountHidden`; false (`PasscodeHelper.java:95–108`) | Requires account code; drawer `DrawerAccountPickerView.java:328`; `PasscodeView.java:1111–1129`; notifications `4506` | Private `privacy.accountHidden` + `privacy.passcodeHash`; native private store, `HiddenAccountPolicy`, account-list/select/unlock hooks | Actual hidden-account consumer, not stock passcode equivalence. Exact identity and lifecycle tests |
| `passcodehelper.accountAllowPanic`; true (`PasscodeHelper.java:91–103`) | Configured panic code → activated AND allowed accounts → `performLogout(1)` (`22–33`) | Private `privacy.accountAllowPanic` + `privacy.panicPasscode`; one-shot authorization and native AccountManager transaction | Original includes eligible visible accounts too. Recorder tests never call native logout |
| `passcodehelper.settingsHidden`; false (`PasscodeHelper.java:149–156`) | Hides the false-bottom entry/search result, not all Telegram settings | Private `privacy.settingsHidden`; integration registers/unregisters the hidden-account action | Current page/recovery link remain usable; real `.settings` authorization needed |
| `passcodehelper.settingsKey`; empty then random (`PasscodeHelper.java:137–146`) | `SettingsHelper.java:290`; `NekoPasscodeSettingsActivity.java:294` local `https://t.me/nasettings/<key>` route | Private `privacy.settingsKey`; `recoveryURL`, exact URL match, URL hook, authorized management page | The original key is **global**, not per-account. iOS uses 16 random bytes vs original 8, local-only expiring clipboard; not a login credential |

### P-system-contacts: exact Android-only disposition

`neko.disableSystemAccount` is false by declaration at
`java/tw/nekomimi/nekogram/NekoConfig.java:125`. In
`java/org/telegram/messenger/ContactsController.java:395–435`, Android
`android.accounts.AccountManager.getAccountsByType(BuildConfig.APPLICATION_ID)`
finds the app's OS accounts, and `427–431` gates creation via
`addAccountExplicitly`. The flag also removes those app-type OS accounts at
`440–472`. `NekoGeneralSettingsActivity.java:324–330` calls removal when enabled
and `checkAppAccount()` for each account when disabled.

**Disposition: unsupported / Android-only mechanism; no iOS setting key or toggle.**
iOS does not expose Android application-type system-account registration. The
native `TelegramUI/Sources/DeviceContactDataManager.swift:21–46` uses
`CNContactStore` and change notifications; its `AccountManager<TelegramAccountManagerTypes>`
is Telegram's internal account database, not Android's OS AccountManager. Contact
permission, CNContactStore import/edit, and Telegram contact synchronization are
different operations. None was changed or claimed as an implementation of this
flag. This closes only the assigned `P-system-contacts` ID, with source evidence,
not a runtime/visual verification claim.

## Behavior and limits

### Filters

- History/preview hides blocked/custom senders and replies to them only in native
  megagroups, matching the inspected ChatActivity predicate. Notification sender
  checks apply in all chats. Auto-download follows the original **regex** gate.
- Regex excludes outgoing and empty messages, emoji/sticker-only body, translated
  body and locally restricted body. Keyboard labels and entity/webpage targets
  remain candidates. Poll/transcription text and the original grouped-text shape
  are included. Album decisions are shared, with peer/namespace/thread grouping.
- NFA accepts literals, dot, groups/noncapturing groups, alternation, classes,
  ASCII `\d/\w/\s`, anchors/boundaries, `*+?`, bounded repeats, reluctant repeats.
  Lookarounds, backreferences, inline flags, class intersections and possessive
  repeats are rejected, not passed to an uninterruptible ICU engine.
- Limits: 256 pattern scalars, 512 compiled states, nesting 16, repeat bound 32,
  8,192 input scalars, 64 rules and 4,096 peers per account. NFA **and class range
  visits** consume a shared operation budget (normally 200k, max 1M per projection).
  Incomplete evaluation is never a negative match for a reversed rule.
- Native block-list loading stops at 4,096 peers/40 advancing pages. Incomplete
  evidence keeps numeric unread counts unknown and notification decisions pending;
  the cache is scoped to the owning encrypted Postbox. Native block/unblock hooks
  refresh the exact peer in that row, without changing other-account data.
- Preview searches the latest 20 local candidates. Unread projection has one
  4,096-message/1M-operation budget for a whole list. It subtracts only inspected,
  identified hidden messages. Missing local history uses an unread **dot**, not an
  invented count. Manual marked-unread flags and native outgoing read boundaries stay.
- Recent reactions subtract only identifiable hidden reactors; duplicate samples
  cannot subtract twice; own selections and unidentified/anonymous totals remain.
  Reaction list pagination keeps its raw offsets and state, filtering only output.
- OS numeric badges are withheld on incomplete filtered counts or forum aggregates
  that may count threads. Archive group samples similarly do not claim a complete
  numeric total. This is a presentation suppression, not marking the account read.
- Zalgo operates after entity formatting using attributed-string deletions. Stored
  message text/entities and protocol data are never rewritten by the display hook.
- Protected copies use fresh local-resource upload references for cached photos/
  non-sticker files and native sticker references. Text entities, spoiler/invert
  attributes and new album grouping survive. Poll/game/invoice/location/contact/
  story/service/paid media, verification-code chats and secret/view-once source
  media are excluded. Source Android's automatic AyuForwardLoader is adapted to
  the explicit native download prerequisite; erased retention-only messages are
  not reconstructed from an absent Postbox row. Native destination send/paid/bot
  flow still decides the real send; this setting supplies no server capability.

### Hidden accounts and panic

- Private definitions are not generic editable flags. Writes validate a real
  `.settings` PasscodeSession, its owner account, foreground and unlocked state.
  Code verifier shape is original salted SHA-256; hashes/salts/flags/recovery token
  are Keychain values. Input kind follows the existing native keypad and Unicode
  normalization. Corrupt/unavailable private storage fails closed, visibly.
- Ordinary PIN has priority over an accidentally identical extra/panic code.
  Additional app-unlock success is not a resource/settings PasscodeSession.
  Biometry can only choose a visible identity; it never evaluates panic codes.
  With every account hidden, ordinary/biometric unlock stays covered; use an
  account code. Settings entry can be recovered by the stored link and ordinary PIN.
- `HiddenAccountAttempt`/authorization are opaque and one-shot, expire after 15 s,
  and are invalidated on cancellation, configuration change, account replacement,
  background/lock/storage changes or a newer attempt. A separate continuation is
  checked after the expected account switch; only PasscodeUI may then uncover AppLock.
- Panic is reached only from a consumed authorization for a **configured code
  manually submitted to the actual app lock screen**. No settings code-save,
  wrong PIN, successful regular PIN, biometric, cancel, background, or account
  switch invokes its private native effect method.
- Native effect validates full identity again against AccountManager backup peer
  and environment **inside the same transaction**, then applies the stock
  `logoutFromAccount(false)` `.loggedOut` transition. This avoids a check-then-logout
  race against a changed record. Native `managedCleanupAccounts` performs real
  remote logout/database cleanup. Missing/mismatched identity metadata is skipped.
- An admitted target's account-code/hidden/eligibility Keychain entries are removed
  by exact identity. A cleanup error leaves an unavailable/reloadable private-store
  state; it never resets another identity or the global panic/recovery configuration.
- Temporary cleanup disposes only tracked native TempBox handles for admitted
  identities, max 256 per account. It neither takes arbitrary paths nor scans/removes
  an app-group folder. Native account removal handles the account's own cache.
  Independent wallet storage is not asserted erased by an account-manager marker.
- Pure tests inject an effect recorder. They cannot call `logoutFromAccount`, any
  native AccountManager, or filesystem cleanup on a user account.

## Coordinator insertion hunks (not applied by this owner)

### 1. Composition and build

In `TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`:

```diff
     private var privacy: ExteralessPrivacyIntegration?
+    private var privacyExtras: ExteralessPrivacyExtrasIntegration?
@@
-                    + PrivacyFeatures.definitions + AIFeatures.definitions + ToolsFeatures.definitions)
+                    + PrivacyFeatures.definitions + PrivacyExtrasFeatures.definitions
+                    + AIFeatures.definitions + ToolsFeatures.definitions)
@@
                 registered = true
             }
+            try exteralessPrivacyExtrasConfigure(rootPath: rootPath)
@@
         if privacy == nil { privacy = ExteralessPrivacyIntegration() }
+        if privacyExtras == nil { privacyExtras = ExteralessPrivacyExtrasIntegration() }
@@
         privacy?.update(context: context)
+        privacyExtras?.update(context: context)
@@
         privacy?.clearContext()
+        privacyExtras?.clearContext()
```

On lifecycle reload, after the normal settings reload, call the native private
store's `reload()` (add `import TelegramCore` to the composition file). Bootstrap
must run after `PasscodeEnvironment.configure` and before account picker/AppLock
presentation. Keep the integration through an expected account replacement;
`clearContext` means cancellation/teardown, not a second step before every update.

Sources use existing recursive globs. Core pure sources require Foundation only.
TelegramCore's new sources use ExteralessCore, Postbox, SwiftSignalKit and Apple
CryptoKit/Security. **Do not add a PasscodeCore dependency to TelegramCore.**
PasscodeUI needs ExteralessCore for the opaque policy types used below. TelegramUI
already has native PasscodeCore/PasscodeUI/ContextUI/PresentationDataUtils dependencies.
No BUILD file was edited by this owner.

### 2. History and live invalidation

In `TelegramUI/Sources/ChatHistoryEntriesForView.swift`, replace the first message
loop (not the backing Postbox view or validation input):

```diff
-    loop: for entry in view.entries {
+    loop: for entry in exteralessFilterHistoryEntries(account: context.account, entries: view.entries) {
```

If this presentation displays translated body text, pass `translated: true`; keep
the original message for keyboard/link extraction. Preserve the original view's
holes/anchors/read states and native validation. Do not create a replacement
MessageHistoryView with the short public initializer (it drops essential metadata).

At the start of `AccountViewTracker.wrappedMessageHistorySignal`, replace
`var signal = signal` with:

```swift
var signal = combineLatest(signal, ExteralessFilteringRuntime.shared.changes)
|> map { value, _ in value }
```

Apply the same invalidation input before `withState` in `wrappedChatListView`.
Settings and block-list changes then re-render without rewriting history. The
projected messages carry a presentation version to refresh reaction attributes.
After a completed native state replay that edits message text/reactions, call
`ExteralessFilteringRuntime.shared.invalidatePresentations()` so aggregate badges
also refresh for non-top-message edits. This call has no database/network effect.

### 3. Chat-list preview, unread and numeric badge

In `ChatListUI/Sources/Node/ChatListNodeLocation.swift`, append to **each** ordinary
chat-list and forum/saved-topic result pipeline, after community summaries:

```swift
|> mapToSignal { update -> Signal<ChatListNodeViewUpdate, NoError> in
    return exteralessFilterChatList(account: account, list: update.list)
    |> map { list in
        ChatListNodeViewUpdate(list: list, type: update.type, scrollPosition: update.scrollPosition)
    }
}
```

This returns native EngineChatList items, retaining drafts/order/rights/thread data;
it avoids modifying `ChatListItem`. In `TelegramEngineMessages.chatList`, append
`|> mapToSignal { exteralessFilterChatList(account: self.account, list: $0) }` after
the EngineChatList conversion for its non-UI callers.

In `ApplicationContext.applicationBadge`, replace the getter body with:

```swift
return exteralessPrivacyExtrasApplicationBadge(context: self.context)
```

### 4. Reactions and native blocked list

In `State/MessageReactions.swift`, inside `EngineMessageReactionListContext.state`,
keep `Impl.InternalState` and offsets unfiltered. Replace the subscription output:

```swift
disposable.set(combineLatest(impl.statePromise.get(), ExteralessFilteringRuntime.shared.changes).start(next: { state, _ in
    subscriber.putNext(exteralessFilterReactionList(account: impl.account, message: impl.message,
        state: State(hasOutgoingReaction: state.hasOutgoingReaction, totalCount: state.totalCount,
                     items: state.items, canLoadMore: state.canLoadMore)))
}))
```

In `TelegramEngine/Privacy/BlockedPeers.swift`, inside the successful native
block/unblock transaction, after cached-user update:

```swift
exteralessFilterBlockedPeerChanged(transaction: transaction, account: account,
    peerId: peerId, blocked: isBlocked)
```

Apply the same exact-peer callback after successful `.blocked` add/remove in
`BlockedPeersContext`; do not call it for `.stories` blocks. The lease loads native
blocked peers for all live accounts; mutations update only the receiving account's
`exteraless.privacyExtras.blocked.v1` row.

### 5. Notifications — actual content and deadline

Main app, `ApplicationContext` notification subscription:

```diff
-        self.notificationMessagesDisposable.set((context.account.stateManager.notificationMessages
+        self.notificationMessagesDisposable.set((exteralessPrivacyExtrasNotifications(
+            account: context.account, source: context.account.stateManager.notificationMessages)
```

Keep the rest of its native subscription/filter/finalizers. Upstream state replay
must still receive every update even for a hidden sender/account.

`Telegram/NotificationService/Sources/NotificationService.swift`:

1. After resolving the existing `rootPath` and configuring PasscodeEnvironment:

```swift
try ClientSettings.shared.register(PrivacyExtrasFeatures.definitions)
try ExteralessHiddenAccounts.shared.configure(basePath: rootPath,
    accessGroup: PasscodeEnvironment.shared.sharedAccessGroup(), isMainApp: false,
    keychainScope: PasscodeEnvironment.shared.keychainScope)
try ExteralessHiddenAccounts.shared.reload()
```

Use the existing settings error/fallback path for failure. Its shared settings loader
must register `PrivacyFeatures.definitions + PrivacyExtrasFeatures.definitions` so
both the generation and deadline reads retain these normal settings.

2. Add `let extrasGate = ExteralessPrivacyExtrasNotificationGate()` to
`ExteralessNotificationDelivery`, and
`var extrasGate: ExteralessPrivacyExtrasNotificationGate?` to `NotificationContent`.
At the **first line** of `NotificationContent.generate()`:

```swift
if let extrasGate, !extrasGate.canPresent { return UNMutableNotificationContent() }
```

3. In `didReceive`'s `updateCurrentContent` closure, stamp every content variant:

```swift
var value = value
value.extrasGate = delivery.extrasGate
if !delivery.isFinished.with({ $0 }) { let _ = delivery.content.swap(value) }
```

Pass `extrasGate: delivery.extrasGate` as a new parameter to `NotificationServiceHandler.init`.
This is one gate per existing once-only delivery, not a process-global current push.

4. After `let accountPeerId = stateManager.accountPeerId`:

```swift
let extrasIdentity = PrivacyExtrasAccountIdentity(recordId: recordId.int64,
    userId: accountPeerId.id._internalGetInt64Value(),
    testingEnvironment: stateManager.network.context.isTestingEnvironment)
extrasGate.bind(account: extrasIdentity)
let extrasPolicy = ExteralessFilteringRuntime.shared.policy(extrasIdentity)
if !extrasPolicy.hasSenderFilters && !extrasPolicy.configuration.regexFiltersEnabled {
    extrasGate.update(.allow, generation: ExteralessFilteringRuntime.shared.generation)
}
```

5. In both `pollWithUpdatedContent` Postbox transactions (cached branch and the
post-poll branch), before constructing sender/media/emoji content:

```swift
exteralessPrivacyExtrasEvaluateNotification(gate: extrasGate, account: extrasIdentity,
    transaction: transaction, peerId: peerId, messageId: messageId,
    actorId: interactionAuthorId,
    oauthNotification: (payloadJson["loc-key"] as? String) == "OAUTH_REQUEST")
```

Android's OAuth exemption is backed by `PushListenerController.java:288–331`, which
sets `isOauthPush=true`; it is not inferred from arbitrary text. Story/call
presentation uses `extrasGate.update(.allow, generation: …)` after its action has
been identified, since message regex does not filter stories/calls. The gate still
checks the exact hidden-account flag at generation. Leave poll/read/delete/delivery
report operations running; gate only their presentation.

6. In `ExteralessNotificationDelivery.finish`, replace the generated fallback line:

```swift
let generated: UNNotificationContent = extrasGate.canPresent
    ? (self.content.with { $0 }?.generate() ?? self.initialContent)
    : UNMutableNotificationContent()
```

Keep existing `PrivacyCompletion`, finish-once, lock redaction and diagnostics.
This is essential: title/subtitle/attachments/sound/intent and raw deadline fallback
must not bypass an unresolved/reversed filter. APNs topic/signing/provider setup
and physical-device delivery remain external verification prerequisites.

### 6. Automatic downloads

`InChatPrefetchManager.update`, at the top of its `(message, media)` loop:

```swift
guard exteralessFilterAllowsAutomaticDownload(account: self.context.account, message: message) else { continue }
```

Subscribe that manager to `ExteralessFilteringRuntime.shared.changes` on main and
call its existing `update()`; dispose with its other subscriptions.

In `PrefetchManager`, after building `[PrefetchMediaItem]` and before starting any
fetch, use the existing item's actual message ID:

```swift
|> mapToSignal { items -> Signal<[PrefetchMediaItem], NoError> in
    let ids = items.compactMap { item -> EngineMessage.Id? in
        if case let .chatHistory(value) = item { return value.media.index.id }
        return nil
    }
    return exteralessFilterAutomaticDownloads(account: account, ids: ids)
    |> map { allowed in items.filter { item in
        if case let .chatHistory(value) = item { return allowed.contains(value.media.index.id) }
        return true
    } }
}
```

Include the runtime changes signal in the existing `orderedPreloadMedia` combine
so turning the feature off restores normal prefetch. User-initiated downloads retain
their native path. No fetch request is faked successful.

### 7. Restrictions, Zalgo and protected-copy action

At entry to `TelegramCore/Utils/PeerUtils.swift`'s
`restrictionText(platform:contentSettings:)` and
`PlatformRestrictionMatching.swift`'s `RestrictedContentMessageAttribute.platformText`:

```swift
if exteralessIgnoreLocalRestrictionNotice() { return nil }
```

Do **not** alter `isSensitiveContent`, `restrictedContentAttribute`, flags,
membership, server errors, missing media, or `account.setContentSettings`.

In `TextFormat/Sources/StringWithAppliedEntities.swift`, at the final `return result`
of `stringWithAppliedEntities`, use `return exteralessZalgoDisplayText(result)`.
Apply only on display calls with `message != nil` if the same function is used for
editable input. The helper deletes ranges in the finished attributed string;
do not strip text before applying original UTF-16 entities.

In `LocalizedPeerData/Sources/PeerTitle.swift` wrap user/group/channel/community
return strings in `compactDisplayTitle` and `displayTitle` with
`exteralessZalgoDisplayText(...)`. Do not change `IndexName.isLessThan` or peer storage.
These modules already import TelegramCore. About/caption display wrappers can use
the same attributed helper; no Postbox import is required.

In the existing `.list(items)` context-menu augmentation in
`Chat/ChatControllerOpenMessageContextMenu.swift`, append independently of stock
`canForward` (which intentionally rejects noforwards):

```swift
let copyItem = MainActor.assumeIsolated {
    exteralessProtectedCopyAction(context: self.context,
        messages: updatedMessages.map(EngineMessage.init),
        peerProtected: self.presentationInterfaceState.copyProtectionEnabled,
        parent: self)
}
if let copyItem { actions.content = .list(items + [.separator, copyItem]) }
```

Merge with AI/chat/plugin additions from the current list, rather than overwriting
their entries. Exclude scheduled/quick-reply/custom-service menus at this entry,
as the original does. The helper uses the real writable peer/topic selector,
native chat navigation, paid-message authorization and `sendMessages` pipeline.

### 8. Actual app-lock authentication (critical combined hunk)

Add this method **inside** `PasscodeCredentialStore` in `PasscodeCore/Passcode.swift`.
It reuses the real credential/attempt/device lock. It returns no credential session
for an alternate app unlock and must not be used for settings/resource authorization.

```swift
public func verifyAppUnlock(_ code: String, reference: PasscodeCredentialReference? = nil,
    alternative: () throws -> Bool) throws -> PasscodeSession? {
    return try self.serialized {
        guard let record = try self.load(), let kind = record.kind, let salt = record.salt,
              let iterations = record.iterations, let wrapped = record.wrappedKey else {
            throw PasscodeError.authenticationRequired
        }
        if let reference, reference.id != record.id { throw PasscodeError.staleAuthorization }
        var attempts = try self.attempts()
        let remaining = Int(max(0, min(60, ceil(attempts.deadline - self.clock().uptime))))
        guard remaining == 0 else { throw PasscodeError.cooldown(remaining) }
        var kek = try PasscodeCrypto.derive(code: kind.normalize(code),
            deviceSecret: self.deviceSecret(), salt: salt, iterations: iterations)
        defer { kek.resetBytes(in: 0 ..< kek.count) }
        let key: Data
        do {
            key = try PasscodeCrypto.open(wrapped, key: kek,
                context: "credential.v1:\(record.id):\(kind.rawValue)")
        } catch {
            if try alternative() {
                try self.storage.remove("attempts")
                return nil
            }
            attempts.count = min(1_000_000, attempts.count + 1)
            attempts.deadline = attempts.count >= 6 ? self.clock().uptime + 60 : 0
            try self.storage.write(JSONEncoder().encode(attempts), account: "attempts", biometric: false)
            throw PasscodeError.invalidCode
        }
        try self.storage.remove("attempts")
        return PasscodeSession(credentialId: record.id, revision: record.revision,
            key: key, scope: .appUnlock, authentication: .passcode)
    }
}
```

In `PasscodeUI/PasscodeEntryController.swift`, import ExteralessCore and add:

```swift
private var extrasAttempt: HiddenAccountAttempt?
```

In `verifyCode`, after its initial lifecycle guard, before setting `checkingCode`:

```swift
let routeExtras = self.applicationBindings.isMainApp && self.authenticationScope == .appUnlock
    && self.authenticated == nil && self.completed == nil
    && ExteralessHiddenAccounts.shared.requiresUnlockRouting
let extrasAttempt = routeExtras
    ? ExteralessHiddenAccounts.shared.beginAppUnlockAttempt(explicitPasscodeEntry: true) : nil
if routeExtras && extrasAttempt == nil {
    self.controllerNode.resetInput()
    self.controllerNode.updateCredentialError(true)
    return
}
self.extrasAttempt = extrasAttempt
```

Inside its worker, preserve native legacy migration. Change result type to
`Result<PasscodeSession?, Error>` and add `var extrasAuthorization: HiddenAccountAuthorization?`.
Replace the final verification return with:

```swift
if let extrasAttempt {
    return try PasscodeCredentialStore.shared.verifyAppUnlock(code, reference: reference) {
        extrasAuthorization = ExteralessHiddenAccounts.shared.authorizeAlternativeAppUnlock(
            attempt: extrasAttempt, code: code)
        return extrasAuthorization != nil
    }
}
return try PasscodeCredentialStore.shared.verify(code, reference: reference, scope: scope, lifetime: lifetime)
```

Before dispatching the worker result to main:

```swift
if let extrasAttempt, case .success(.some) = result {
    extrasAuthorization = ExteralessHiddenAccounts.shared.authorizeOrdinaryAppUnlock(attempt: extrasAttempt)
}
let finalExtrasAuthorization = extrasAuthorization
```

At the existing main-thread lifecycle acceptance guard, invalidate optional success
with `session?.invalidate()`. After re-enabling input, before the stock result switch:

```swift
if let extrasAttempt, case let .success(session) = result {
    session?.invalidate()
    guard let authorization = finalExtrasAuthorization else {
        ExteralessHiddenAccounts.shared.policy.cancel(extrasAttempt)
        self.controllerNode.resetInput()
        self.controllerNode.updateCredentialError(true)
        return
    }
    self.checkingCode = true
    self.controllerNode.isUserInteractionEnabled = false
    ExteralessHiddenAccountUnlock.complete(authorization) { [weak self] success in
        guard let self, self.authenticationLifecycle.acceptsResult(generation: generation) else { return }
        self.checkingCode = false
        self.controllerNode.isUserInteractionEnabled = true
        self.extrasAttempt = nil
        if success { self.appLockContext.unlock() }
        else { self.controllerNode.resetInput(); self.controllerNode.animateError() }
    }
    return
}
```

The stock success switch becomes `.success(.some(session))`; add `.success(nil)`
as a reset/error branch. Keep all existing ordinary-session handling and failure/
cooldown UI. On failure, cancel `extrasAttempt`. Cancel/clear it in the background
invalidation block, `stopAuthentication` and deinit:

```swift
ExteralessHiddenAccounts.shared.policy.cancel(self.extrasAttempt)
self.extrasAttempt = nil
```

In the normal LocalAuth `requestBiometrics` callback, **after its existing domain
and lifecycle checks**, inside `if result`, before stock success:

```swift
if strongSelf.applicationBindings.isMainApp && strongSelf.authenticationScope == .appUnlock
    && strongSelf.authenticated == nil && strongSelf.completed == nil
    && ExteralessHiddenAccounts.shared.requiresUnlockRouting {
    strongSelf.hasOngoingBiometricsRequest = false
    guard let attempt = ExteralessHiddenAccounts.shared.beginAppUnlockAttempt(explicitPasscodeEntry: false),
          let authorization = ExteralessHiddenAccounts.shared.authorizeBiometricUnlock(attempt: attempt) else {
        strongSelf.controllerNode.resetInput()
        strongSelf.controllerNode.updateCredentialError(true)
        return
    }
    strongSelf.extrasAttempt = attempt
    ExteralessHiddenAccountUnlock.complete(authorization) { [weak self] success in
        guard let self, self.authenticationLifecycle.acceptsResult(generation: generation) else { return }
        self.extrasAttempt = nil
        if success { self.appLockContext.unlock() }
        else { self.controllerNode.resetInput(); self.controllerNode.animateError() }
    }
    return
}
```

Do not wire this into `requestSecureBiometrics`, settings authentication, Share PIN
completion or wallet/resource scopes. A failed resource PIN cannot become panic.

### 9. Hidden account consumers, recovery and temporary files

`SharedAccountContext.swift` account-info publication: combine
`activeAccountContexts` with `ExteralessHiddenAccounts.shared.changes` and return
`exteralessPrivacyExtrasVisibleAccounts(accountsWithInfoResult)` instead of the raw
array. Keep the raw `activeAccountContexts` signal for lifecycle/management use.

At the top of `switchToAccount`, before mutating switchingData/current record:

```swift
guard let target = self.activeAccountsValue?.accounts.first(where: { $0.0 == id })?.1,
      ExteralessHiddenAccounts.shared.canSelect(exteralessPrivacyExtrasIdentity(target.account)) else { return }
```

In `ExteralessBotAccountRouter.resolve`, extend its context filter with
`!ExteralessHiddenAccounts.shared.isHidden(exteralessPrivacyExtrasIdentity($0.account))`.
The integration already invalidates pending bot routing when hidden settings change.
Apply the same visibility predicate to any account picker/shortcut using raw account
records rather than the shared account-info signal. Share extension bootstrap reads
the same private store via its already-configured PasscodeEnvironment, `isMainApp:false`.

At the beginning of `OpenUrl.swift`'s `openExternalUrlImpl`, before remote resolution:

```swift
if let parsed = URL(string: url), let parent = navigationController?.topViewController as? ViewController,
   exteralessPrivacyExtrasOpenRecoveryURL(context: context, url: parsed, parent: parent) { return }
```

The recovery link does not authenticate itself or become an external request.

For actual document-preview temporary handles in `DocumentPreviewController.swift`,
replace its internal `postbox` initializer parameter with `account: Account`, retain
the exact account identity, and use `account.postbox` only inside that existing file.
Update both `OpenChatMessage.swift:presentDocumentPreviewController` calls from
`postbox: params.context.account.postbox` to `account: params.context.account`.
At the native TempBox handle creation:

```swift
let tempFile = TempBox.shared.file(path: path, fileName: fileName)
do {
    try ExteralessPrivacyExtrasTemporaryFiles.shared.track(tempFile,
        account: exteralessPrivacyExtrasIdentity(account))
} catch {
    TempBox.shared.dispose(tempFile)
    return // no unmanaged exported copy
}
```

On disposal use registry `release(file, account: storedIdentity)`. Register other
account-owned export handles at their actual creation the same way; never infer an
owner from a filename or register a shared parent directory. This uses native
TempBox reference-counted disposal, not arbitrary file deletion.

## Verification / handoff gate

Completed locally: Android source/default/callsite inspection; Core/native API and
dependency-graph inspection; UTF-8/trailing-whitespace and no-Postbox-UI/no-cyclic-
PasscodeCore-import checks over the supplied sources. A first literal import check
matched a comment; the anchored import check passed. These are static checks only.

The real `tools.compat.feature_inventory.merge_parity` accepted the fragment:
**exact 16 IDs** (all 15 `R-privacy-extras` IDs plus `neko.disableSystemAccount`),
85 source anchors with existing paths/in-range lines, zero verified/ported claims.
Final static boundary checks cover 22 owned source/test/handoff files. The two Core
suites contain 20 prepared test methods; they have not been executed locally.

Prepared bounded XCTest suites: `FilteringPolicyTests` and `HiddenAccountPolicyTests`.
They cover original defaults, per-record/user/environment/namespace isolation,
sender/reply/notification/download scopes, rule precedence/private exceptions,
OAuth/outgoing/empty exclusions, reversed unknown handling, NFA adversarial limits,
reaction sample dedup/own selection, incomplete unread data, Zalgo UTF-16 spans,
wrong/ordinary/account/panic/biometric paths, one-shot expiry/cancel/supersession,
expected versus unrelated account switches, and injected-secret redaction/export.

**Not run:** Swift compiler/XCTest (neither swift nor swiftc is installed; WSL is
not installed), native UIKit linking, device/Simulator, APNs or recorded frames.
No XcodeBuildMCP tools are exposed. Coordinator should run the Core suites after
building, then the supported complete IPA build and fake-account native auth tests.
Use bounded test commands, e.g. `timeout 30s swift test --skip-build --filter
'FilteringPolicyTests|HiddenAccountPolicyTests'` in `swift/ExteralessCore`.

### Expected frames, specified before recording

- Filter root → peer/rule editor: native grouped-list push/pop (~0.3 s), no extra
  spring. Long patterns/footer/error wrap in light/dark, RTL, large type and reserved
  corners. Switch values refresh from persisted state; invalid regex leaves the
  previous policy active with an error. No main-thread freeze on adversarial input.
- History filter on/off: hidden rows, their empty date/unread separators and album
  spacing disappear/reappear together; original scroll anchor and visible neighbors
  remain stable. No sender/reply/avatar/reaction leak for a frame. Incoming edits
  recompute; another account with identical peer/message IDs stays unchanged.
- Chat list/notifications: previous visible preview replaces a hidden top message;
  incomplete counts show no invented number. Reaction badges and actors agree.
  Foreground/APNs/deadline/locked variants have no title/attachment/intent leak and
  no repost/duplicate alert. Use known fixture OAuth/system categories separately.
- Zalgo: triggering mark runs disappear with span colors/links/emoji still aligned;
  legitimate short combining sequences and >2048-unit messages stay intact.
- Protected-copy menu: only eligible source content appears; picker cancel keeps
  drafts. Cached albums remain grouped; missing media shows the real prerequisite.
  The native paid/send path and recipient/topic remain correct after navigation.
- Hidden accounts: code setup never shows a stored verifier; hide removes only
  eligible picker rows and alerts. Recovery link opens local ordinary-PIN management.
  During account-code unlock the native lock cover stays up until the expected
  account is ready, with no old hidden-content flash. Wrong/regular PIN, Face ID,
  cancellation, background and account switches remain non-destructive.
- Panic animation/flow is recorded **only with injected effects and synthetic
  identities**. It must record exactly configured targets and owned temp handles,
  leave excluded identities intact, stay covered and refuse stale completions.

Until labelled frames and native CI exist, every related receipt remains unverified.
