# Privacy / ghost / proxy / notifications — implementation handoff

Status: native source and owner handoff supplied; the coordinator has applied both
Network guards and outgoing callbacks. Remaining common insertion hunks are still
coordinator/chat-owned. [Phase-2 fixes and checks](privacy-phase-2.md) cover UI import
boundaries, real history bounds, observation lifecycle, central namespace allocation
and TL metadata. **No native build, runtime, visual, APNs delivery or device
pass is claimed on Windows.** The machine-readable fragment is
[`privacy-parity.json`](privacy-parity.json), validated by the real inventory
`merge_parity` function (34 feature IDs + 4 module IDs; zero verified claims).

## Integration/dependency notices for other implementers

- Pure sources: `swift/ExteralessCore/Sources/ExteralessCore/Privacy*.swift`; tests under `Tests/ExteralessCoreTests/PrivacyPolicyTests.swift` (Core package owned by core-settings).
- TelegramCore read/presence/typing/history/notification adapters import `ExteralessCore`; add the Core dependency to `TelegramCore` and `TelegramCoreTestsLib`.
- `Telegram/NotificationService` needs `//third-party/exteraless:ExteralessCore` for privacy projection and redacted diagnostics.
- Shared allocation **63** needs the coordinator's central `Namespaces.CachedItemCollection.exteralessLocalState` declaration; exact hunk and re-audit are in `privacy-phase-2.md`. Privacy clears only its three prefixed keys; extras already uses a different prefix in the same collection. No common namespace file was edited here.
- Common Network/AppDelegate/PeerInfoSettingsItems and chat-owned Enqueue changes are in [`privacy-insertion-hunks.md`](privacy-insertion-hunks.md). Apply these before treating the related definitions as fully wired. Suppression must complete/error; fabricated PTS must never reach state replay.
- Deleted/edit/media retention and filtering/hidden-account/panic settings now have separate implementers (`ExteralessRetention`, `ExteralessPrivacyExtras`). Their evidence belongs to those owners and is not duplicated by this adapter.
- Obsidian `06-Уведомления` read attempted via local REST API: unavailable (`obsidian_unreachable`). Existing source/API is the evidence used; no secrets were requested or printed. VoidGram is notification-only reference; no IPA analysis.

## Original evidence already inspected

`app/exteraless/{ghost,privacy,proxy,notifications}`, `OpenExteraConfig.kt`, `GeneralConfig.kt`, live NekoConfig/NaConfig callsites, `AyuGhostUtils`, `AyuGhostPreferences`, `LastSeenHelper`, `AyuSpyController`, `ProxyUtil`.

## What is connected

- `PrivacyFeatures`/`PrivacyPolicy`: original defaults, bulk ghost toggle and its
  five locks, scoped read/typing exceptions, story session override, final raw-RPC
  policy, notification privacy, bot selection, scheduled-send eligibility.
- Native read paths: history/secret history, forum discussions and saved/monoforum
  history, voice/video/mention/reaction contents, live-location seen and channel
  view increments. Existing local state changes and operation-log finalizers run.
- Presence recomputes when settings change; it sends offline when online packets
  are disabled and reactivates normal presence when re-enabled.
- Local observations live in separate activity/read-date rows in the owning
  **encrypted Postbox**, not a global user cache. They are observed before read
  state mutation, displayed in a native per-chat screen, and can be cleared. A
  hidden approximate profile presence can use an observed seven-day fallback.
- Own offline timestamp is captured before stock removes self presence from its
  update map; the native ghost screen and self profile can display it.
- Bot navigation/Mini Apps inspect each account's own peer/hash and positive
  dialog evidence. A configured user ID is resolved to the actual native account;
  requested established conversations win, ambiguous/new-ask cases choose,
  incomplete evidence cancels. Private Mini Apps refresh app access hashes after
  switching. Drafts, message subjects and history holders are not copied across
  accounts. Group/inline/attachment/auth/onramp flows retain their identity.
- Payload-link `/start` deduplicates by account record + user identity + bot +
  payload, keeping failures/cancellation retryable. A core send-approval boundary
  is available for the chat-owned common enqueue hunk.
- Proxy CRUD remains Telegram's actual SOCKS5/MTProxy/WEB editor/import/share/
  connectivity path. Names now persist with server settings, survive edits,
  display in the list, and do not create duplicate connections. Wi-Fi/mobile
  suspension projects the effective server, preserving the user's enabled choice.
- Notification extension redacts complete content at generation and fallback/
  deadline, not just `body`; titles, subtitle, attachments, attributed body,
  sender intents and reply category cannot leak through the redacted branch.
  It reloads only normal privacy definitions from the existing shared root.
- App-lock transitions remove existing message alerts when previews are disabled,
  because iOS cannot silently rewrite delivered APNs content. No local reposts
  are used to imitate push or re-alert watches. New pushes remain redacted.
- All known main-app read/delete/logout notification-clear consumers now call
  `ExteralessNotificationClearing` with the actual receiving `AccountRecordId`.
  NotificationService's separate removal paths also filter by that account.
  Deleting one message clears that exact notification, not all older messages.
- Registration diagnostics distinguish permission, device-token receipt, Telegram
  `registerDevice` acceptance/rejection/invalidation and extension delivery stage.
  No diagnostic API accepts token/key/payload/error-description text. The existing
  registration Bool is retained as its caller's **token-invalidated** contract,
  rather than turning transient errors into repeated APNs token rotation.

## Android-to-native matrix

`implemented` below means connected source, **not** verified execution. `partial`
identifies an unapplied owner hunk or a genuine platform gap. Original file paths
are relative to `third_party/exteraless-android/TMessagesProj/src/main` and their
pins/feature IDs remain in `docs/parity/client-features.json`.

### Ghost / local privacy

| Original symbol / declaration default | Actual iOS key | Native consumer / evidence | Status / verification |
| --- | --- | --- | --- |
| `NekoConfig.sendReadMessagePackets = true`; `AyuGhostUtils.isReadMessageRequest`, `interceptRequest` | `privacy.sendReadMessagePackets` | `State/SynchronizePeerReadState.swift`; `ManagedConsumePersonalMessagesActions`; `ManagedSynchronizeConsumeMessageContentsOperations`; `ApplyMaxReadIndexInteractively`; `ReplyThreadHistory`; `MarkAllChatsAsRead` | Typed paths and both raw Network guards connected; final TL metadata consumed. `PrivacyPolicyTests`, `ExteralessPrivacySignalTests` prepared |
| `AyuGhostUtils` changes `getMessagesViews.increment`, not the fetched counts | same | `AccountViewTracker.updateViewCountForMessageIds`: false increment, real count response | Connected source; no fabricated views/PTS |
| `NekoConfig.sendReadStoriesPackets = true` | `privacy.sendReadStoriesPackets` | `ManagedSynchronizeViewStoriesOperations.pushStoriesAreSeen`; `Stories._internal_markStoryAsSeen` pinned and regular | Connected source, including both raw Network guards |
| `NekoConfig.sendOnlinePackets = true`; disabled rewrites `account.updateStatus.offline=true` | `privacy.sendOnlinePackets` | `ManagedAccountPresence` combines requested online state with settings invalidation | Connected source; raw guard is terminal denial rather than raw-byte mutation |
| `NekoConfig.sendUploadProgress = true` | `privacy.sendUploadProgress` | `ManagedLocalInputActivities.requestActivity`; `TypingDraftStop` | Text, upload, recording, games, sticker/emoji, encrypted typing; raw guards connected |
| `NekoConfig.sendOfflinePacketAfterOnline = false`; 1000 ms after send/edit/encrypted-service completion | `privacy.sendOfflinePacketAfterOnline` | `ExteralessOutgoingPrivacy.exteralessPrivacyDidComplete`; account-owned cancellable lease installed in `Account.init` | Both Network completion hooks connected; iOS coalesces consecutive follow-ups per account |
| `NekoConfig.markReadAfterSend = true` | `privacy.markReadAfterSend` | `ExteralessOutgoingPrivacy.exteralessPrivacyWillSubmit`, real loaded max ID / explicit scoped read | Both Network will-submit hooks connected; actual PTS forwarded only for real responses |
| `sendReadMessagePacketsLocked = false` | `privacy.sendReadMessagePacketsLocked` | `PrivacyPolicy.ghostModeChanges` -> `exteralessToggleGhostMode` -> native ghost screen | Implemented source; lock means bulk-toggle exclusion |
| `sendReadStoriesPacketsLocked = false` | `privacy.sendReadStoriesPacketsLocked` | same | Implemented source |
| `sendOnlinePacketsLocked = false` | `privacy.sendOnlinePacketsLocked` | same | Implemented source |
| `sendUploadProgressLocked = false` | `privacy.sendUploadProgressLocked` | same | Implemented source |
| `sendOfflinePacketAfterOnlineLocked = false` | `privacy.sendOfflinePacketAfterOnlineLocked` | same | Implemented source |
| `NekoConfig.isGhostModeActive`, `setGhostMode`, `toggleGhostMode` | existing five fields | `PrivacyPolicy.ghostModeActive/ghostModeChanges`; native toggle sends resulting presence | Preserves all-locked behavior and reactivation defaults; tests prepared |
| `AyuGhostPreferences.ghostModeReadExclusions`, prefix `ghostModeReadExclusion_`, default false | `privacy.ghostModeReadExclusions` object | Native per-chat editor; read/story policy | iOS adaptation uses `AccountRecordId:packedPeerId`, not Android `abs(chatId)` (no account/namespace collisions) |
| `AyuGhostPreferences.ghostModeTypingExclusions`, prefix `ghostModeTypingExclusion_`, default false | `privacy.ghostModeTypingExclusions` object | Native per-chat editor; typing and offline-follow-up policy | Same account/namespace isolation |
| `AyuState.allowReadPacket`, default off / one-use bypass; `AyuGhostUtils.markReadOnServer` | no global transient setting | `exteralessMarkReadOnServer`, descriptor+network-scoped weak authorization | Explicit UI action bypasses only its actual request; no global next-packet race |
| `NekoConfig.showGhostInDrawer = false` | `privacy.showGhostInDrawer` | Optional native Settings quick-toggle, supplied advanced row id 9 | Partial until PeerInfo coordinator hunk; drawer has no direct iOS equivalent |
| `NekoConfig.showGhostModeStatus = false`; ActionBar/Dialogs checks `isGhostModeActive` | `privacy.showGhostModeStatus` | `ChatTitleView` idle subtitle + VoiceOver status, live invalidation | Implemented source; frames pending |
| `NaConfig.askBeforeOpeningStory = false`; `StoryViewer.shouldAskBeforeOpening` | `privacy.askBeforeOpeningStory` | `StoryContainerScreen` wraps the real `StoryContentContext` before it can mark seen | Native normal/private/cancel choice; own known peer skips; frames pending |
| `AyuGhostUtils.storyGhostSession = false`, released with viewer | account-owned transient lease | `ExteralessStoryPrivacySessions`, `ExteralessPrivacyStoryContent.close/deinit` | Private view overrides read exceptions; account clear cannot let a stale private viewer send views; tests prepared |
| `NaConfig.ghostScheduledSend = false`; `SendMessagesHelper.shouldGhostSchedule` and +12 s | `privacy.ghostScheduledSend` | `ExteralessPrivacyOutgoingMessages`; preserves media/entities/grouping/replies/correlation | Partial until chat enqueue hunk; paid/special/self/bot/secret/explicit schedules excluded; eligibility tests prepared |
| `NaConfig.silentMessageByDefault = false` (also shown in GhostModeActivity) | chat domain, no privacy duplicate | Original changes UI notify defaults and permits explicit notify override | Not implemented/claimed by this adapter; request chat-owner mapping, not a blanket network mute |
| `OwnLastSeen.seconds/time/isToday/format`, no config | no extra toggle | Capture server offline timestamp before self-presence removal; `exteralessOwnLastSeen`; native self-profile/ghost overview | Native localized date/time adaptation; no request for guessed own presence |
| `NekoConfig.hidePhone = true`; ExteraConfig `getHidePhoneNumber` alias | `privacy.hidePhone` | `PeerInfoHeaderNode`, `PeerInfoProfileItems`; remaining settings-edit/suggestion hunks | Partial until common labels integrated; server privacy/change-number action retain real data |
| `NaConfig.saveLocalLastSeen = false`; `LastSeenHelper`, cleanup 7 days, increasing timestamps only | `privacy.saveLocalLastSeen` | `UpdatePeers`, `AccountStateManagementUtils` reactions, `AccountViewTracker` loaded history; `ExteralessPrivacyObservations`; `PeerInfoData` | Per-account encrypted row; 7-day expiry on load/maintenance; iOS 50,000-activity quota; phase-2 namespace hunk/tests pending |
| `NaConfig.saveReadDate = false`; `AyuSpyController.onUpdatesRead/getReadDate/getContentsReadDate` | `privacy.saveReadDate` | Native read/secret-read/played replay hooks before state changes; recent per-chat UI; private `MessageReadStats` fallback | Implemented source, bounded adaptation: 50,000 records/scan and 100 displayed recent loaded messages; missing server date is explicitly observed arrival time |
| `GeneralConfig.contentCapture = false` | `privacy.contentCapture` | `NotificationContent.generate` gates incoming `INInteraction.donate` | Adapted to Siri donation; not Android ContentCaptureManager parity |

Secret-chat note: Android's `isReadMessageRequest` does **not** suppress encrypted
`sendEncryptedService` read-content actions. This patch gates encrypted read-history
and typing like the original and does not discard sequence-numbered encrypted
service operations. Do not claim that ghost mode hides every possible activity
signal (sending, calls and protocol-mandated service messages can reveal activity).

### Original `app/exteraless/privacy` bot routing

| Symbol/default | Native equivalent/callsite | Status/evidence |
| --- | --- | --- |
| `GeneralConfig.botPrivacyEnabled=false` | `privacy.botPrivacyEnabled`; `NavigateToChatControllerImpl`, private Web/Mini App entry points | Source connected; common enqueue hunk still required |
| `GeneralConfig.botPrivacyAlwaysAsk=false` | `privacy.botPrivacyAlwaysAsk`; independent mode in `BotAccountPolicy.choose` | Choice/incomplete/explicit-established tests prepared |
| `GeneralConfig.botPrivacyUserId=0L` | `privacy.botPrivacyUserId`; native account picker persists Telegram user ID | Existing records/objects resolved each decision; no slot conversion |
| `BotAccountPolicy.choose/isCurrent/isEnabled` | Pure `BotAccountPolicy`; UI generation + exact account object and preference snapshot checks | Bounded async work; stale decisions finish nil/false |
| `BotAccountRouter.configuredAccount/accounts/accountName/selectAccount` | `activeAccountContexts`/`activeAccountsWithInfo` within same testing environment | No account/hash copied from another identity |
| `Check.inspect/inspectPeer` -> `MessagesStorage.hasBotConversation` | `exteralessBotConversationEvidence`: local top/read markers, per-account username resolution, `getPeerDialogs` | Cached user/empty dialog alone is not prior contact; fully erased histories remain unobservable |
| `allowNextOpen/consumeHandoff`, process-local 15 s | UI navigation object handoff; preference/account generation invalidation | No global selected-account access in network helpers |
| `interceptChat` before `/start` | `NavigateToChatControllerImpl` hook; account-local payload start | Private navigation only; different account rebuilds navigation state |
| `interceptWebView` excludes group/inline/auth | `ChatControllerOpenWebApp` private normal/main/app entry points | Target account fetches `getBotApp` by short name again; frames/real accounts untested |
| `guardComposer/guardSend`, configured after stale chat was opened | `ExteralessBotSendAuthorization.check`, native UI resolver; `_internal_requestStartBot` | Common enqueue nil-per-input cancellation hunk still required; no message transfer when chosen account differs |
| `BotStartDeduplicator.begin/failed` | Same identity/bot/payload semantics, native payload start; failed/cancelled retry | Prepared Core tests; no actual bot/account requests executed |

### Proxy

| Symbol/default | Native equivalent/callsite | Status/evidence |
| --- | --- | --- |
| `OpenExteraConfig.proxyDisableConditions=0` | `privacy.proxyDisableConditions`; `ExteralessProxyEnvironment`, `ProxySettings.effectiveActiveServer`, both Account proxy subscriptions | Wi-Fi/mobile native source implemented; combined field partial because VPN bit unsupported |
| `ProxyDisableCondition.VPN=1` | no exposed choice | iOS does not provide a reliable system-wide third-party VPN-state API for this app; no utun/name heuristics or fake VPN setting |
| `MOBILE_DATA=2`, `WIFI=4` | NWPathMonitor default path, options 0/2/4/6 | Event-driven, no polling; manual disabled state is never automatically enabled |
| `NaConfig.disableProxyWhenVpnEnabled=false` / legacy preference migration | original migrates into VPN bit | No Android preferences imported; unsupported native global-VPN condition |
| `ProxyUtil.proxyAutoDisabled=false` | effective-server projection rather than a persisted enabled flip | Preserves active server and user preference through route changes/restart |
| `ProxyController.get/setName`, empty default, replace newlines | `ProxyServerSettings.displayName`, native editor/list | Source implemented; name round-trip/credential-preservation tests prepared |
| `getDisplayName/getProxyTypeName` | optional name then native host/port or WEB address; actual connection type | Source implemented |
| `get/setCurrentProxy/getProxyList/load/save/add/saveProxy/remove/delete/clearAll` | stock AccountManager ProxySettings transactions, real editor/import/share/delete | Native stock-equivalent source; no verified claim; connection-identity dedup preserves renamed endpoints |
| `ProxyPingController.INTERVAL_MS=10000`, reads existing native active ping | stock `ProxyServersStatuses` and connection-status labels while settings is open | Native adaptation: cancellable on-screen checks, no permanent background ping; WEB RTT is not exposed as a invented value |
| `ProxyController.requestProxyCountry` always invokes callback with `""` | no geolocation request or false country UI | Original no-op/compat behavior, not an omitted functional country resolver |

### Notifications / APNs

| Original symbol/default | Native equivalent/callsite | Status/evidence |
| --- | --- | --- |
| `NaConfig.showNotificationPreviewWhenLocked=false` | `privacy.showNotificationPreviewWhenLocked`; service-extension initial/generation/final-expiry policies; native lock-state subscription | Source implemented; foreground callback hunk pending; live lock removes old alerts instead of reposting them |
| `NotificationsHelper.load/saveWearNotificationIds`, empty per-account IDs | OS delivered/pending notification store + explicit account matching | Survives process restart without a new process-local ledger; unknown legacy account IDs are not cleared as another account |
| `computeNotificationSignature/shouldSkipNotify`, empty in-memory map | stock per-account Postbox displayed-notification markers + stable request IDs | Existing source equivalent; no re-notify loop added; edit/avatar/signature parity is not device-verified |
| `removePostedSignature/clearPostedSignatures/isSummaryPosted` | OS enumerate/removal; `ExteralessNotificationClearing`, extension removal branches | Main read/delete/forced-logout clears actual receiving account; exact delete differs from read-through-max |
| `NaConfig.pushServiceType=1` | Native APNs, Telegram encrypted `registerDevice`, native bounded wakeup and service extension | **platform-prerequisite** for end-to-end delivery; application callback hunks supplied |
| `pushServiceTypeInAppDialog=false` | native iOS permission UI is a different API | Android provider prompt unsupported; no inert native boolean |
| `pushServiceTypeUnifiedGateway`, `...UnifiedSimple`, `...WebPushPrivateKey`, `...WebPushPublicKey`, `...WebPushAuthSecret` defaults empty | no corresponding iOS distributor mode | Unsupported, no credential import or embedded APNs provider keys |
| `NaConfig.notificationIcon=1` | iOS system-selected app icon | Android small-icon selection unsupported |
| `NekoConfig.disableNotificationBubbles=false` | no Android bubble API in iOS | Unsupported, no fake toggle |
| Stock `account.registerDevice` result/error handling | `PrivacyNotificationDiagnostics`, numeric error codes and actual Bool response | Token receipt is not provider delivery; transient RPC error is not success and does not rotate a valid token |
| Foreground/background delegate completion | `ExteralessNotificationCallbacks`, exact AppDelegate replacements | Pending coordinator insertion; once-only completion including denied, active-account foreground and initialization timeout |
| Extension `didReceive` / expiry race | per-delivery `ExteralessNotificationDelivery`, protected immutable initial fallback | Once-only completion, old delivery cannot overwrite new content; handler nil finishes promptly; native tests/device pending |

APNs external prerequisites are independent of source readiness: signed App ID,
the correct `aps-environment`, APNs topic/environment, and **Telegram provider-side
configuration for that topic** must match. A certificate plus bundle ID alone does
not prove push works. No `.p8` provider key, APNs provider secret, GitHub token or
push token is packaged by this implementation. Real physical-device notification
registration and delivery remain unverified. Existing push-triggered bounded
state synchronization is preserved; no permanent background polling is introduced.

## Remaining inventory surfaces — not silently counted as ports

These original settings are discovered in the expanded Java/Kotlin inventory but
are assigned to the new retention/extras implementers. The table records this
adapter's phase-1 scope only; their current global status must come from their own
fragments rather than this handoff:

| Symbols | Original defaults | Current native status |
| --- | --- | --- |
| `NaConfig.enableSaveDeletedMessages`, `enableSaveEditsHistory` | false / false | Pending local deleted/edited-content archive and inline rendering; observations above store timestamps only |
| `saveDeletedExceptionsMode`, `saveEditedExceptionsMode` | 0 / 0 | Pending retention allow/deny-list semantics |
| `saveDeletedInPrivateChats`, `saveDeletedInGroups`, `saveDeletedInChannels`, `saveInArchivedChats` | true | Pending with deleted-message retention, not independent fake toggles |
| `saveDeletedMessageForBot`, `saveDeletedMessageForBotUser` | false | Pending retention policy |
| `messageSavingSaveMedia`, `saveMediaInPrivateChats/PublicChannels/PrivateChannels/PublicGroups/PrivateGroups` | true | Pending archive-owned media lifetime, not satisfied by ordinary Telegram cache |
| `customDeletedMark`, `deletedMarkColor`, `translucentDeletedMessages`, `useDeletedIcon`, deleted-history context menu fields | see pinned NaConfig declaration records | Pending saved-message presentation; no claim from ghost read policy |
| `NekoConfig.ignoreBlocked=false`, `NaConfig.blockedChannelsData="[]"`, custom filtered users/regex fields | false/empty as pinned | Pending client-only sender/reaction/notification filtering; Telegram's server block list is not equivalent |
| `NekoConfig.ignoreContentRestrictions=true` | true | Pending restriction-policy mapping; no implicit server/content permission bypass claimed |
| `PasscodeHelper.accountHidden=false`, `accountAllowPanic=true`, `settingsHidden=false`, per-account `settingsKey` | template defaults | Pending hidden-account/panic feature; native passcode is a different stock capability |
| `NaConfig.disableCrashlyticsCollection=false` legacy state | false, migration feeds GeneralConfig.crashReports | Android Crashlytics flag is not claimed as iOS telemetry controls; tools owner must map actual reporting |

The supplied JSON changes only implemented/integrated-scope features and known
platform-only provider/icon modes. It does not downgrade or overwrite another
owner's prospective evidence for the remaining inventory surfaces.

## Files changed (outside common owner hunks)

- Core: `swift/ExteralessCore/Sources/ExteralessCore/Privacy{Features,Policy,Observations,NotificationDiagnostics}.swift`; matching `PrivacyPolicyTests.swift`.
- Native helpers: `TelegramCore/Sources/State/Exteraless{PrivacyPolicy,PrivacyObservations,OutgoingPrivacy}.swift`, `Network/ExteralessProxyPolicy.swift`, `TelegramEngine/Privacy/ExteralessBotPrivacy.swift`, `PendingMessages/ExteralessPrivacyOutgoingMessages.swift`.
- Native connected consumers: `Account/Account.swift` (proxy subscriptions/account lease); `State/{SynchronizePeerReadState,ManagedAccountPresence,ManagedLocalInputActivities,TypingDraftStop,ManagedSynchronizeConsumeMessageContentsOperations,ManagedConsumePersonalMessagesActions,ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations,ManagedSynchronizeViewStoriesOperations,AccountViewTracker,AccountStateManagementUtils}.swift`; `TelegramEngine/Messages/{Stories,MarkAllChatsAsRead,ApplyMaxReadIndexInteractively,ReplyThreadHistory,MessageReadStats,RequestStartBot}.swift`; `TelegramEngine/AccountData/RegisterNotificationToken.swift`; `Settings/ProxySettings.swift`; `SyncCore/SyncCore_ProxySettings.swift`.
- UI: `TelegramUI/Sources/ExteralessClient/Privacy/**`, `NavigateToChatController.swift`, `Chat/ChatControllerOpenWebApp.swift`, `ApplicationContext.swift` (notification-clear subscriber), `SharedNotificationManager.swift` (account-scoped removal).
- Components: `ChatTitleView/Sources/ChatTitleView.swift`; `PeerInfoScreen/Sources/{PeerInfoData,PeerInfoHeaderNode,PeerInfoProfileItems}.swift`; `StoryContainerScreen/Sources/{ExteralessStoryPrivacy,StoryContainerScreen}.swift`.
- Proxy UI: `SettingsUI/Sources/Data and Storage/{ProxyServerSettingsController,ProxySettingsServerItem}.swift`.
- Extension: `Telegram/NotificationService/Sources/{NotificationService,ExteralessNotificationPrivacy}.swift`.
- Native tests: `TelegramCore/Tests/{ExteralessPrivacySignalTests,ExteralessProxyNameTests}.swift`.

## Verification performed / prepared

Performed, bounded, no account/network actions:

1. Read original Java and Kotlin callsites, including `AyuGhostUtils` request sets,
   actual `/start` routing, `MessagesStorage.hasBotConversation`, reaction/last-seen
   hooks, proxy migration and notification locking/cancel semantics.
2. `git diff --check` for touched tracked privacy/native files: passed (only Windows
   LF/CRLF notices, no whitespace errors).
3. `merge_parity(existingInventory, fragments=[privacyFragment])`, all referenced
   path/line bounds and zero verified/ported claims: passed, 38 records.
4. Swift toolchain probe: `swift`/`swiftc` absent; no pretend native test execution.
5. Final bounded source checks over 16 new privacy helper files: no `return
   .never()`, no fabricated negative PTS, no stale alert-controller signature;
   all four service-extension removal loops require the receiving account. These
   are static integration checks, not Swift compilation/runtime proof.
6. Phase 2: `python docs/wave-2/tests/privacy_source_fixtures.py` passed 8 static
   fixtures. Official PostboxImportCheck reports zero privacy problems; the first
   whole-tree rerun found two unrelated AI adapter problems. Exact results and
   remaining native compile requirements are in `privacy-phase-2.md`.

Prepared meaningful tests:

- Original defaults and disabling/re-enabling ghost mode; locks vs app lock;
  explicit read vs read-after-send; account/peer-namespace exceptions.
- Raw read/view/status/typing policy keeps getDifference available and blocks
  unknown-peer bypass; no fabricated PTS response.
- Signal suppression emits/completes and runs the local finalizer without calling
  the network factory; subscription-time policy evaluation and disposal propagation.
- Story lease/account clear; bot ambiguous/incomplete/unavailable/explicit history
  decisions; identity/payload start dedup and retry.
- Observed activity expiry, future timestamp rejection and immutable first-read
  dates under replay; notification clearing account/namespace/exact-delete boundary.
- Registration diagnostics account separation and redacted extension report shape.
- Proxy name Codable migration/round-trip/credentials and generated TL request peer
  extraction preserving channel-vs-user namespaces.

Coordinator CI: build the Core package and run `PrivacyPolicyTests`; include
`ExteralessPrivacySignalTests` and `ExteralessProxyNameTests` in the existing
TelegramCore test target. Those source tests are not proof that AppDelegate,
notification extension or UIKit compile; the full supported application build is
still required after common insertion. No agent commit/push/dispatch was performed.

## Expected frames / device checks (not recorded)

- Ghost toggle: locked controls retain values; normal reactivation restores stock
  activity. Chat subtitle badge appears only when enabled/active, without clipping
  name/network activity. Test large type, RTL and rotation.
- Story prompt: content cannot call `markAsSeen` while the choice is pending; normal
  shows the existing viewer, private stays private across story navigation, Cancel
  returns to the original screen. Own known stories skip the prompt. Verify the
  avatar transition, edit/reorder casts, close/PiP and switching accounts.
- Bot routing: a new private bot opens the chosen account; established requested
  chat keeps it; ambiguous/incomplete history cannot send automatically. Cancel
  preserves draft; changing preferences/account during a prompt dismisses it.
- Local data: disabling each observation setting hides its cached display; clear
  affects only the current account. Phone number is absent from own header/profile
  and common settings labels after the coordinator hunk.
- Proxy editor: name edit/reset is reflected in the real list, secret fields retain
  values, same endpoint import does not duplicate; Wi-Fi/mobile pause/resume does
  not turn a manually disabled proxy on.
- Notifications: physical-device foreground/background/extension deadline, locked
  app and denied/provisional permission; no duplicate watch alerts on app lock;
  same peer/message IDs in two accounts clear only the receiving account. Confirm
  real APNs provider prerequisites separately, without collecting keys in app logs.
