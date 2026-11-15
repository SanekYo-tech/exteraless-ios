# Chat phase 2 — coordinator-owned insertion hunks

Source WIP only. `chat-phase2-shared.patch` is the current remaining packet; examples below include already-applied rationale.
No commits, build dispatch or native/visual verification were performed by Chat.

## Canonical selected-text translation (one setting)

Canonical key: **`chats.showTextTranslate`**, original `nagram.showTextTranslate`.
Chat's real formatting menu consumes `ChatFormattingPolicy.translationActionEnabled`.
`ChatFeatures.migrateSettings` uses the store's atomic `migrateKey`; an explicit
canonical value wins, even true against legacy false, and the old JSON key is removed.
The independent AI definition is now removed and its canonical consumer is applied.

```diff
--- a/swift/ExteralessCore/Sources/ExteralessCore/AIFeatures.swift
+++ b/swift/ExteralessCore/Sources/ExteralessCore/AIFeatures.swift
@@
-            boolean("showTextTranslate", "Show selected-text translation", true, translation),
--- a/swift/ExteralessCore/Sources/ExteralessCore/AITranslationPolicy.swift
+++ b/swift/ExteralessCore/Sources/ExteralessCore/AITranslationPolicy.swift
@@
-        showTextTranslate = store.bool("ai.showTextTranslate", default: true)
+        showTextTranslate = ChatFormattingPolicy.translationActionEnabled(in: store)
--- a/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
+++ b/telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift
@@
-            lastError = nil
+            try ChatFeatures.migrateSettings()
+            lastError = nil
```

Place the migration after all definitions are registered, before domain objects.
The same migration must follow registration in extension composition. Do not add a
second visible alias. AI's provider/language controls keep their existing keys.

The double-tap LLM action reuses the AI owner's existing visible-text projection
(summary/translation/transcription/rich-page handling), rather than copying it.
In `AI/ExteralessAIChatActions.swift`, change only its access level:

```diff
@@
-    private func exteralessAIVisibleText(message: EngineMessage) -> (text: String, entities: [MessageTextEntity]) {
+    func exteralessAIVisibleText(message: EngineMessage) -> (text: String, entities: [MessageTextEntity]) {
```

Retain `@MainActor`. The access and canonical-key changes are present in live AI source;
Main/Share preparation also calls the migration. These applied hunks were removed
from the remaining packet. Include those AI/Root files with the frozen Chat cohort.

## Header actions (appearance's header nodes remain owned by Appearance)

In `PeerInfo/PeerInfoScreen/Sources/PeerInfoData.swift`, at the **last** return of
`peerInfoHeaderButtons` (immediately before `func peerInfoCanEdit`):

```swift
    if isOpenedFromChat {
        if ClientSettings.shared.bool("chats.hideCallButton") {
            result.removeAll { $0 == .call || $0 == .videoCall }
        }
        if case let .channel(channel) = peer, case .broadcast = channel.info,
           ClientSettings.shared.bool("chats.hideChannelSearchButton") {
            result.removeAll { $0 == .search }
        }
    }
    return result
```

Add `import ExteralessCore` in `PeerInfoData.swift` (the header node's import does
not make it available in this source file). This is the native
chat-origin expanded header; the ordinary iOS avatar remains profile navigation.
`.money` is already gated in the owned `ChatControllerOpenAttachmentMenu.swift`.

## Call confirmation before the existing native call path

`TelegramUI/Sources/AccountContext.swift`, split the existing `requestCall` entry:

```diff
@@
     public func requestCall(peerId: EnginePeer.Id, isVideo: Bool, completion: @escaping () -> Void) {
+        exteralessConfirmOutgoingCall(context: self, peerId: peerId, isVideo: isVideo, confirmed: { [weak self] in
+            self?.exteralessRequestConfirmedCall(peerId: peerId, isVideo: isVideo, completion: completion)
+        })
+    }
+
+    private func exteralessRequestConfirmedCall(peerId: EnginePeer.Id, isVideo: Bool, completion: @escaping () -> Void) {
         guard let callResult = self.sharedContext.callManager?.requestCall(context: self, peerId: peerId, isVideo: isVideo, endCurrentIfAny: false) else {
```

The existing body, current-call replacement prompt and permissions stay inside the
confirmed implementation. The helper exists in `Chats/ExteralessChatCallConfirmation.swift`.

## Silent default: preserve absence versus explicit audible override

Enqueue already applies default only when no notification attribute exists. The
empty-flags attribute is an explicit audible choice. Apply these shared signature
and transform changes together with the owned optional callers:

`ChatControllerInteraction/Sources/ChatControllerInteraction.swift`: change both
the stored property and initializer argument for `sendCurrentMessage` from
`(Bool, ChatSendMessageEffect?) -> Void` to **`(Bool?, ChatSendMessageEffect?) -> Void`**.

`AccountContext/Sources/AccountContext.swift`, send parameters:

```diff
@@
     public var textIsAboveMedia: Bool
+    public var notificationOverride: Bool?
@@
-        textIsAboveMedia: Bool
+        textIsAboveMedia: Bool,
+        notificationOverride: Bool? = nil
@@
         self.textIsAboveMedia = textIsAboveMedia
+        self.notificationOverride = notificationOverride
```

`TelegramUI/Sources/ChatController.swift`:

```diff
@@
-                    self.sendMediaRecording(silentPosting: silentPosting, messageEffect: messageEffect)
+                    self.sendMediaRecording(silentPosting: silentPosting ?? (self.presentationInterfaceState.interfaceState.silentPosting || ClientSettings.shared.bool("chats.silentMessageByDefault")), messageEffect: messageEffect)
@@
-        let silentPosting = self.presentationInterfaceState.interfaceState.silentPosting
+        let silentPosting: Bool? = self.presentationInterfaceState.interfaceState.silentPosting ? true : nil
@@
-    func transformEnqueueMessages(_ messages: [EnqueueMessage], silentPosting: Bool, scheduleTime: Int32? = nil, repeatPeriod: Int32? = nil, postpone: Bool = false) -> [EnqueueMessage] {
+    func transformEnqueueMessages(_ messages: [EnqueueMessage], silentPosting: Bool?, scheduleTime: Int32? = nil, repeatPeriod: Int32? = nil, postpone: Bool = false) -> [EnqueueMessage] {
@@
-            return message.withUpdatedAttributes { attributes in
+            return message.withNotificationOverride(silent: silentPosting).withUpdatedAttributes { attributes in
@@
-                if silentPosting || scheduleTime != nil {
-                    for i in (0 ..< attributes.count).reversed() {
-                        if attributes[i] is NotificationInfoMessageAttribute {
-                            attributes.remove(at: i)
-                        } else if let _ = scheduleTime, attributes[i] is OutgoingScheduleInfoMessageAttribute {
-                            attributes.remove(at: i)
-                        }
-                    }
-                    if silentPosting {
-                        attributes.append(NotificationInfoMessageAttribute(flags: .muted))
-                    }
-                    if let scheduleTime {
-                         attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: repeatPeriod))
-                    }
+                if let scheduleTime {
+                    attributes.removeAll { $0 is OutgoingScheduleInfoMessageAttribute }
+                    attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: repeatPeriod))
                 }
@@
-                let messages = strongSelf.transformEnqueueMessages(mappedMessages, silentPosting: silentPosting, scheduleTime: scheduleTime, postpone: postpone)
+                let messages = strongSelf.transformEnqueueMessages(mappedMessages, silentPosting: parameters?.notificationOverride ?? (silentPosting ? true : nil), scheduleTime: scheduleTime, postpone: postpone)
@@
-    func enqueueChatContextResult(_ results: ChatContextResultCollection, _ result: ChatContextResult, hideVia: Bool = false, closeMediaInput: Bool = false, silentPosting: Bool = false, scheduleTime: Int32? = nil, resetTextInputState: Bool = true, postpone: Bool = false) {
+    func enqueueChatContextResult(_ results: ChatContextResultCollection, _ result: ChatContextResult, hideVia: Bool = false, closeMediaInput: Bool = false, silentPosting: Bool? = nil, scheduleTime: Int32? = nil, resetTextInputState: Bool = true, postpone: Bool = false) {
@@
-        let sendMessage: (Int32?, Bool) -> Void = { [weak self] scheduleTime, silentPosting in
+        let sendMessage: (Int32?, Bool?) -> Void = { [weak self] scheduleTime, silentPosting in
```

Apply the `message.withNotificationOverride` replacement only inside
`transformEnqueueMessages`, not another same-named map. The prior forwarded
content/Stars/send-as/native guard insertions must be retained. This uses the real
TelegramCore optional inline API already patched by Chat.

The extra **Send with sound** action and the owned text/rich-text callers are in
this source wave; shared parameters above are their compile-time dependency.

### TL owner: resolved Bool send options must remain explicit

`TelegramCore/Sources/ExteralessRuntime/TLMediaServices.swift:321` receives an already
resolved `silent: Bool`. Preserve **false** at the native enqueue boundary too:

```diff
-            if silent { attributes.append(NotificationInfoMessageAttribute(flags: [.muted])) }
+            attributes.append(NotificationInfoMessageAttribute(flags: silent ? [.muted] : []))
```

This is a TL-owner hunk, not a Chat edit to SDK/TL. Otherwise the receiving enqueue
cannot distinguish this explicit audible request from an absent default. The native
enqueue and its plugin MODIFY policy already preserve the empty-flags attribute.

## Native menu visibility gates (preserve native action bodies)

In `ChatInterfaceStateContextMenus.swift` (already imports Core), apply:

```diff
@@
-        if let starStatus = data.starStatus {
+        if let starStatus = data.starStatus, ChatMenuPolicy.enabled("showAddToFavorites") {
@@
-        if !messageText.isEmpty || richMessageMarkdown != nil || (resourceAvailable && isImage) || diceEmoji != nil {
+        if !messageText.isEmpty || richMessageMarkdown != nil || (resourceAvailable && isImage && ChatMenuPolicy.enabled("showCopyPhoto")) || diceEmoji != nil {
@@
-        if let message = messages.first, message.id.namespace == Namespaces.Message.Cloud, let channel = message.peers[message.id.peerId] as? TelegramChannel, !channel.isMonoForum, !(message.media.first is TelegramMediaAction), !isReplyThreadHead, !isMigrated {
+        if ChatMenuPolicy.enabled("showCopyLink"), let message = messages.first, message.id.namespace == Namespaces.Message.Cloud, let channel = message.peers[message.id.peerId] as? TelegramChannel, !channel.isMonoForum, !(message.media.first is TelegramMediaAction), !isReplyThreadHead, !isMigrated {
@@
-        if data.messageActions.options.contains(.report) {
+        if data.messageActions.options.contains(.report) && ChatMenuPolicy.enabled("showReport") {
```

The separate ad/report and ephemeral menus keep their mandatory native actions.
The first-wave `exteralessMessageContextActions` insertion is **already applied**;
it now supplies the added repeat-copy/forward-copy/reminder/bookmark/media/admin/chat
actions. Do not insert it a second time.

In `Chat/ChatControllerOpenMessageContextMenu.swift`, add `import ExteralessCore`
and gate only reaction-panel creation (retaining AI and plugin items):

```diff
@@
-                if canAddMessageReactions(message: EngineMessage(topMessage)), let allowedReactions = allowedReactions, !topReactions.isEmpty {
+                if ChatMenuPolicy.enabled("showReactions"), canAddMessageReactions(message: EngineMessage(topMessage)), let allowedReactions = allowedReactions, !topReactions.isEmpty {
```

`deleteChatForBothSides` initializes the real `.unsendPersonal` deletion switch in
`ChatControllerAdminBanUsers.swift`; user changes still win. The five linked defaults
also have a real indirect original consumer (`getDeleteMenuChecks` →
`AlertsCreator:7961,8089` → `DeleteMessagesBottomSheet.toggleDefaultChecks`). They now
use one native parent bitmask and the actual moderation sheet, including the
common-groups option. The prior storage-only disposition has been withdrawn.

## External URL / share import

`AppDelegate.swift` already imports Core. Normalize only HTTP(S) input at both
public arrival funnels, before the existing Ton/proxy/import/native-service routing:

```diff
@@
     private func openUrl(url: URL) {
+        let url = ClientSettings.shared.bool("chats.stripTrackingOnOpen", default: true)
+            ? (URL(string: ChatLinkPolicy.removingTracking(from: url.absoluteString)) ?? url) : url
@@
     private func openUrlWhenReady(accountId: AccountRecordId? = nil, url: URL, external: Bool = false) {
+        let url = ClientSettings.shared.bool("chats.stripTrackingOnOpen", default: true)
+            ? (URL(string: ChatLinkPolicy.removingTracking(from: url.absoluteString)) ?? url) : url
```

The cleaner preserves non-HTTP/file/Ton/tg links, user-info and signed/proxy URLs.
Keep every existing resolution/confirmation and NativeService URL/document barrier.

`TelegramUI/Components/ShareExtensionContext/Sources/ShareExtensionContext.swift`:
add `import TextFormat` and its direct BUILD dependency. At the named `sentItems`
closure, immediately before `let sentItems = sentShareItems(...)`:

```swift
    let contents = contents.map { item -> PreparedShareItemContent in
        if case let .text(text) = item { return .text(exteralessCleanIncomingLinkText(text)) }
        return item
    }
    let additionalText = exteralessCleanIncomingLinkText(additionalText)
```

This is the actual import DTO: `.text(String)` or `.media(StandaloneUploadMediaResult)`.
It keeps uploaded media as-is. It does not project a rich payload into a string.
`TextFormat/ExteralessIncomingLinks.swift` exists and uses the same Core filter and
reverse UTF-16 edit policy as the composer.

Before constructing the share account context (after `rootPath` is established in
`Telegram/Share/ShareRootController.swift:46`), extension composition must register
the same typed chat definitions, select the **existing** shared settings file and
configure the filter cache:

```swift
    let exteralessDirectory = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent("exteraless", isDirectory: true)
    do {
        try ClientSettings.shared.configure(storageURL: exteralessDirectory.appendingPathComponent("client-settings.json"))
        try ClientSettings.shared.register(ChatFeatures.definitions)
        try ChatFeatures.migrateSettings()
        try ChatTrackingRulesStore.shared.configure(overrideURL: exteralessDirectory.appendingPathComponent("adguard_url_tracking.txt"), bundledURL: Bundle.main.url(forResource: "adguard_url_tracking", withExtension: "txt"))
    } catch {
        // Cache retains last-known-good values. Never replace a failed read with defaults on disk.
        NSLog("Exteraless share settings/filter could not be refreshed")
    }
```

Add `import ExteralessCore` to the share root and its build dependency through the
build owner. Reuse an already-integrated extension configure call instead of
duplicating it. On extension re-entry call `ClientSettings.shared.reload()` before
using the cached toggles. Full filter bundling in the extension is a build resource task.

**Latest-root integration:** Main and Share now register Chat definitions and call
the canonical migration in their existing preparation. Share also has Retention,
ClientAPI and hidden-account barriers. The remaining packet adds only the filter
cache configuration immediately after that existing migration call.

The ready packet also normalizes `handleOpenURL(_:)` before its existing
`openUrlInProgress` comparison, so deduplication uses the same address as
`openUrlWhenReady`. All three transformations are idempotent and preserve signed links.
