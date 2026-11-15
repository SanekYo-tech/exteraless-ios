# Privacy — exact coordinator/chat insertion hunks

All implementation helpers below exist. Shared files are intentionally left to their owners.
Main/extension settings path is **`<telegram-data>/exteraless/client-settings.json`**,
matching `ExteralessClientRuntime.configure`. Definitions must be registered before
Account/Network consumers start. `ExteralessPrivacyIntegration` is @MainActor and
implements the contract `init/update(context:)/clearContext()`.

## 1. Coordinator: Network.swift (both request entry points)

In `requestWithAdditionalInfo` and `request`, replace their generator's first line
and insert this before `hasPluginRequestSubscribers`:

```diff
-        return Signal { [requestService] subscriber in
+        return Signal { [weak self, requestService] subscriber in
+            guard let self else {
+                subscriber.putError(MTRpcError(errorCode: 401, errorDescription: "ACCOUNT_CONTEXT_RELEASED"))
+                return EmptyDisposable
+            }
+            if let error = exteralessPrivacyRequestError(network: self, description: data.0) {
+                subscriber.putError(error)
+                return EmptyDisposable
+            }
+            exteralessPrivacyWillSubmit(network: self, description: data.0)
             let hasPluginRequestSubscribers = PluginHookRouter.hasSubscribers(.preRequest) || PluginHookRouter.hasSubscribers(.postRequest)
```

In the `NetworkEngineRequest` in each of those **same two functions**:

```diff
-                completed: { result in
+                completed: { [weak self] result in
+                    if let self {
+                        exteralessPrivacyDidComplete(network: self, description: data.0)
+                    }
                     switch result {
```

No new import. Preserve all existing PluginHooks, real deserialization/PTS and
request disposable. Typed automatic read callsites were patched separately to
emit local results/confirm operation rows. The last-line transport guard gives raw
TL callers a terminal `403 EXTERALESS_PRIVACY_SUPPRESSED`, never fake affectedMessages.
Request descriptions with no typed parameters cannot borrow a peer exception;
SDK/TL services should supply their real description parameters when available.

## 2. Chat owner: EnqueueMessage.swift

At the start of `enqueueMessagesWithoutPluginHooks` split the existing body into an
authorized implementation. This covers both native and plugin-origin enqueue, and
runs before media transforms/database inserts. **Decline returns one nil per input,
not an empty/nonterminating signal.** Group/inline/attachment flows retain their peer.

```diff
 private func enqueueMessagesWithoutPluginHooks(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {
+    return ExteralessBotSendAuthorization.shared.check(account: account, peerId: peerId)
+    |> mapToSignal { allowed -> Signal<[MessageId?], NoError> in
+        guard allowed else { return .single(Array(repeating: nil, count: messages.count)) }
+        return enqueueMessagesWithPrivacyAuthorization(account: account, peerId: peerId, messages: messages)
+    }
+}
+
+private func enqueueMessagesWithPrivacyAuthorization(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {
     let signal: Signal<[(Bool, EnqueueMessage)], NoError>
```

In that function's transaction, before `var resultIds`:

```diff
         return account.postbox.transaction { transaction -> ([MessageId?], [MessageId]) in
+            let messages = exteralessPrivacyOutgoingMessages(transaction: transaction, account: account, peerId: peerId, messages: messages)
             var resultIds = Array<MessageId?>(repeating: nil, count: messages.count)
```

The helper preserves media/entities/forward grouping/correlation and applies
`privacy.ghostScheduledSend` only to eligible new cloud sends, +12 server seconds.
Explicit schedules, bots/unknown private peers, Saved Messages, encrypted chats,
monoforums, paid/suggested/quick-reply/ephemeral/story/game/invoice flows are excluded.
Native resend paths do not call this new-message wrapper. Android silent-by-default
is `NaConfig.silentMessageByDefault=false`, **chat domain** (`chats.silentMessageByDefault`);
preserve explicit notify overrides, not an unconditional mute in the transport.

## 3. Coordinator: AppDelegate notification callbacks

Add `import ExteralessCore` if composition has not already added it.

```diff
     func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
-        Logger.shared.log("App \(self.episodeId)", "register for notifications: didRegisterForRemoteNotificationsWithDeviceToken (deviceToken: \(hexString(deviceToken)))")
+        PrivacyNotificationDiagnostics.shared.recordTokenReceived()
+        Logger.shared.log("App \(self.episodeId)", "APNs device token received")
         self.notificationTokenPromise.set(.single(deviceToken))
@@
     func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
-        Logger.shared.log("App \(self.episodeId)", "register for notifications: didFailToRegisterForRemoteNotificationsWithError (error: \(error))")
+        PrivacyNotificationDiagnostics.shared.recordTokenFailure(code: (error as NSError).code)
+        Logger.shared.log("App \(self.episodeId)", "APNs registration failed (code: \((error as NSError).code))")
@@
     func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
+        let completionHandler = exteralessBackgroundNotificationCompletion(completionHandler)
@@
-        Logger.shared.log("App \(self.episodeId)", "remoteNotification: \(redactedPayload)")
+        Logger.shared.log("App \(self.episodeId)", "Remote notification received")
@@
-                Logger.shared.log("App \(self.episodeId)", "pushRegistry credentials: \(credentials.token as NSData)")
+                Logger.shared.log("App \(self.episodeId)", "VoIP push token received")
```

Also replace the two `pushRegistry didReceiveIncomingPushWith \(payload.dictionaryPayload)`
log strings with `VoIP notification received`; leave the payload handling itself intact.

Replace the complete `willPresent` method with:

```swift
    @available(iOS 10.0, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let complete = exteralessForegroundNotificationCompletion(completionHandler)
        let _ = (accountIdFromNotification(notification, sharedContext: self.sharedContextPromise.get())
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] accountId in
            guard let context = self?.contextValue?.context else { complete([]); return }
            let _ = (exteralessForegroundNotificationOptions(context: context, accountId: accountId, notification: notification)
            |> deliverOnMainQueue).start(next: complete)
        })
    }
```

Replace the complete `registerForNotifications(replyString:messagePlaceholderString:hiddenContentString:hiddenReactionContentString:hiddenStoryContentString:hiddenStoryReactionContentString:includeNames:authorize:completion:)`
method with the following. Native category identifiers/actions are preserved.

```swift
    private func registerForNotifications(replyString: String, messagePlaceholderString: String, hiddenContentString: String, hiddenReactionContentString: String, hiddenStoryContentString: String, hiddenStoryReactionContentString: String, includeNames: Bool, authorize: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        let center = UNUserNotificationCenter.current()
        exteralessRegisterForNotifications(center: center, authorize: authorize, prepareCategories: {
            let reply = UNTextInputNotificationAction(identifier: "reply", title: replyString, options: [], textInputButtonTitle: replyString, textInputPlaceholder: messagePlaceholderString)
            var options: UNNotificationCategoryOptions = []
            if includeNames { options.insert(.hiddenPreviewsShowTitle) }
            var carPlayOptions = options
            carPlayOptions.insert(.allowInCarPlay)
            center.setNotificationCategories([
                UNNotificationCategory(identifier: "unknown", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: options),
                UNNotificationCategory(identifier: "r", actions: [reply], intentIdentifiers: [INSearchForMessagesIntentIdentifier], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions),
                UNNotificationCategory(identifier: "m", actions: [reply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions),
                UNNotificationCategory(identifier: "gr", actions: [reply], intentIdentifiers: [INSearchForMessagesIntentIdentifier], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions),
                UNNotificationCategory(identifier: "gm", actions: [reply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions),
                UNNotificationCategory(identifier: "c", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: options),
                UNNotificationCategory(identifier: "t", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenReactionContentString, options: options),
                UNNotificationCategory(identifier: "st", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenStoryContentString, options: options),
                UNNotificationCategory(identifier: "str", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenStoryReactionContentString, options: options)
            ])
        }, completion: completion)
    }
```

This handles denied/notDetermined-without-prompt/provisional/ephemeral states and
always completes. No synthetic push, persistent background polling or provider key.
The Core registration Bool remains Telegram's **token invalidation** contract;
actual RPC acceptance/failure is recorded separately so generic errors do not rotate
valid device tokens. Diagnostic Retry uses the existing registration manager.

## 4. Coordinator: PeerInfoSettingsItems.swift

After the existing native Exteraless row (id 8), add the optional drawer-equivalent
quick toggle (advanced id 9 is unused in the inspected source):

```swift
    if exteralessShowGhostShortcut() {
        items[.advanced]!.append(PeerInfoScreenDisclosureItem(id: 9,
            label: .text(exteralessGhostModeIsActive() ? "On" : "Off"),
            text: "Ghost mode", icon: PresentationResourcesSettings.security, action: {
                let _ = (exteralessToggleGhostMode(account: context.account)
                |> deliverOnMainQueue).start(error: { _ in
                    guard let parent = interaction.getController() else { return }
                    parent.present(textAlertController(sharedContext: context.sharedContext, title: "Ghost mode", text: "Could not save privacy settings.", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
                })
            }))
    }
```

In `settingsEditingItems`, replace only the existing phone label:

```diff
-        items[.info]!.append(PeerInfoScreenDisclosureItem(id: ItemPhoneNumber, label: .text(user.phone.flatMap({ formatPhoneNumber(context: context, number: $0) }) ?? ""), text: presentationData.strings.Settings_PhoneNumber, icon: PresentationResourcesSettings.recentCalls, action: {
+        items[.info]!.append(PeerInfoScreenDisclosureItem(id: ItemPhoneNumber, label: .text(exteralessShouldHidePhone(accountPeerId: context.account.peerId, peerId: user.id) ? "" : user.phone.flatMap({ formatPhoneNumber(context: context, number: $0) }) ?? ""), text: presentationData.strings.Settings_PhoneNumber, icon: PresentationResourcesSettings.recentCalls, action: {
```

For the phone-confirmation suggestion at `let phoneNumber = formatPhoneNumber(...)`,
use `let phoneNumber = exteralessShouldHidePhone(accountPeerId: context.account.peerId, peerId: peer.id) ? "••••" : formatPhoneNumber(context: context, number: peer.phone ?? "")`.
The actual Change Number action retains the real number. Header/profile rows are already patched.
