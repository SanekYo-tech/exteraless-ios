# MS-ROUTE-01 — independent source closure

**Partial source closure; MS-ROUTE-01 remains P2.** The metadata index, native
search UI, stock Settings search projection and normal URL navigation are joined.
Five scoped source counterexamples remain in dispatch, lifetime and qualifier
enforcement, detailed below. They are source traces, not executed UIKit failures.

- Reviewed **2026-11-15**. Initial read-time HEAD:
  `93edf05ec061ff976380465c838f2bfe0fe82caa`; later observed HEAD:
  `d1df6ad60056cec78407991c2e8373bdea617ff7`.
- At **20:24:45 UTC**, all **16 paths / 50 hunks** in
  [settings-search-applied.json](../settings-search-applied.json) matched their
  raw byte lengths and SHA-256 postimages. The subsequently joined BUILD export
  was observed directly; the full **17-path / 51-hunk** packet reverse-check
  passed before the later Reset edits.
- Supplied execution evidence: **16 search tests passed**, within **687 Core
  tests**, Linux **43757030337 / 93edf05e**. No CI query or local Swift run was
  performed. Native compilation, UIKit execution and recorded-frame acceptance
  remain pending.
- Authored output: this document. The schema-1 route map, its identities and
  `verified`/`ported` authority remain inputs. Later concurrent source changes are
  identified by read-time hashes below.

## Source path key

| Key | Repository path |
|---|---|
| `CORE` | `swift/ExteralessCore/Sources/ExteralessCore/` |
| `CLIENT` | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/` |
| `APP` | `telegram-ios/submodules/TelegramUI/Sources/` |
| `AC` | `telegram-ios/submodules/AccountContext/Sources/` |
| `SEARCH` | `telegram-ios/submodules/SettingsUI/Sources/Search/` |
| `PEER` | `telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/` |
| `HARNESS` | `telegram-ios/Tests/ExteralessHarness/Sources/` |
| `JAVA` | `third_party/exteraless-android/TMessagesProj/src/main/java/` |

Runtime line references describe the initial applied postimage unless explicitly
marked as the late Reset join. Other principal search implementation anchors were
unchanged during the reviewed interval.

## Remaining closure counterexamples

### R1 — launch/notification URLs reach intent hooks before local denial

`APP/AppDelegate.swift:1808–1814,2183–2191,3460–3465` reaches
`openUrlWhenReady`, whose continuation at **3424–3451** consumes privacy-recovery
URLs but has no corresponding `consumeClientSettingsURL` call. It offers the URL
to `NativeServiceOpenHooks.interceptURL(..., fromIntent: true, ...)` first.

Concrete input, using an owned sentinel:

```text
tg://settings/exteraless/setting/clientAPI.customAppHash?value=OWNED_CANARY
```

The settings parser recognizes this namespace and rejects its value query.
`clientCleanOpeningURL:3006–3012` consequently preserves the original bytes.
On the launch/notification route, however, a matching active intent handler can
receive those bytes **before** that rejection and before the settings-specific
readiness/lock gate:

1. `CLIENT/PluginServices/NativeServiceOpenHooks.swift:33–45` constructs the real
   intent context and invokes the interception registry.
2. `swift/PluginHost/Sources/PluginHost/NativeServiceInterceptionModels.swift:74–120,197–220`
   includes `data_string`, decoded query values and the original intent data.
3. `NativeServiceOpenBarrier.swift:292–309` selects matching live handlers.
4. Only the continuation reaches `APP/ApplicationContext.swift:973–981` →
   `openExternalUrlImpl`, where the client parser/lock handling finally occurs.

This is a settings-route ingress omission, not a defect inferred about arbitrary
plugin behavior. The ordinary `openUrl` branch already consumes the same input at
`AppDelegate.swift:3069–3071`. Closure requires the launch/scene/notification branch
to reach that local consumer before offering a recognized client URL externally.

### R2 — an in-app pending URL can bind to a replacement session after ABA

`APP/OpenUrl.swift:369–381` retains a canonical URL while waiting up to 30 seconds
for unlock. Its standalone subscription captures a weak `AccountContext` and
navigation controller, but no search-session identity, result ticket or
registration version. Runtime retirement does not cancel that subscription.

Source witness:

1. Queue a client URL for account-context object **A** while the lock gate waits;
   use the supported `navigationController: nil` path.
2. Publish B, then A again. `SharedAccountContext.swift:787–789,816–835` retains
   account-context objects in its account array and selects an existing object as
   primary. Runtime retires the old search session and installs a new one.
3. Unlock before timeout. `OpenUrl.swift:377` selects the current main-window
   navigation controller. `AC/ExteralessSettingsSearchEntry.swift:56–63` looks up
   the **new** provider and resolves the retained URL afresh.
4. The new provider's context-identity check succeeds for A, even though the
   original session and any original action registration have retired.

Thus the old pending UI request can construct/push a destination without a new
user open. The UUID in an old *result ticket* cannot help: this continuation never
retains one. The normal AppDelegate consumer is stronger: its disposable is
cleared on replacement and it compares the captured `AuthorizedApplicationContext`
object at `AppDelegate.swift:1594,3042–3050`.

A copied canonical URL should remain reusable upon a **new explicit user open**.
An already pending open needs captured lifetime authority/cancellation across its
wait; it must not reacquire permission merely because the same account object
becomes primary again.

### R3 — queued schema invalidations lose an intermediate A→B→A change

`CLIENT/ExteralessSettingsSearch.swift:84–88` turns store invalidations into
MainActor tasks and discards the event's keys/history. Each task later reads the
then-current snapshot. `CORE/ClientSettingsSearchIndex.swift:149–157` retains a
ticket version whenever that snapshot's fingerprint equals the last indexed one.

A deterministic source witness fits in one MainActor turn, using the fixture's
given context and actual store/session:

```swift
// A and B have the same registered key/type; only their title differs.
try settings.register([A])
let old = try session.resolve(.canonical(.setting(A.key))).ticket
try settings.register([B])
try settings.register([A])
// Source consequence: session.accepts(old) is true, including after queued tasks drain.
```

Both replacements are allowed by `ClientSettings.swift:237–242,566–579`.
Publication reports changed definitions at **890–900**, but no per-definition
generation accompanies the snapshot. The queued callbacks both observe A, so B
never advances the index's sequence. Changing A's section to `AI state` and back
has the same lost intermediate removal from the searchable catalog.

This also reaches the private generic selector/editor: its retained route ticket
is checked by `ExteralessSettingsController.swift:160–164,187–203` and the row-focus
predicate at **135–137**, but the stale ticket still validates. Additional checks
around layout therefore cannot detect this ABA.

The Core tests at `ClientSettingsSearchTests.swift:48–80` explicitly refresh the
index at each intermediate state. They establish that algorithm's behavior, not
delivery of every schema transition through the native asynchronous observer.
Closure needs schema-event identity captured before coalescing, while retaining
the intended stability for unchanged refreshes and unrelated value-only changes.

### R4 — the shipping default Root factory has a permissive sessionless fallback

The installed production factory is still
`CLIENT/ExteralessClientRuntime.swift:244–247` →
`exteralessSettingsController(context:)` at
`ExteralessSettingsController.swift:55–57`. It constructs Root unconditionally.
The initializer at **128–133** converts a missing/mismatched current session to
nil, and `routeIsCurrent:160–163` returns **true** for nil.

After `clearContext()` or a context replacement, a retained default factory/PeerInfo
row can therefore still construct an active Root using the old context:

- `AC/ExteralessSettingsEntry.swift:15–34` retains the installed factory; search
  retirement clears the search provider, not this factory.
- The actual advanced Settings row at `PEER/PeerInfoSettingsItems.swift:279–285`
  passes its captured context into it and pushes the returned controller.
- The resulting Root can render current global definitions/actions. Its private
  editor fallback at `ExteralessSettingsController.swift:434–445` also constructs
  a controller without route authority. A disabled Search button does not retire
  those ordinary controls/factories.

The explicit `searchSession:` overload correctly refuses a retired session at
**65–69**. The UIKit fixture's retirement check exercises only that overload
(`SettingsSearchUIViewRouteChecks.swift:149–152`). Its native-page fixture action
uses the two-argument, potentially unbound overload at **33–38** and pops that page
before retirement; it does not test a retained default Root/editor.

Closure requires the shipping default entry to enforce a matching live session,
including subsequent private editor construction, and a given-context regression
through that real default factory.

### R5 — the Nagram moved-row fallback can discard an explicit class constraint

`CORE/ClientSettingsSourceRoutes.swift:408–425` initially narrows candidates by
the exact class's pages and the requested page. At **428–430**, the Nagram fallback
instead searches all rows when that constrained set is empty; it does not retain
the class restriction.

Concrete recognized source URL:

```text
tg://settings/exteraless/source?page=nasettings/general&class=app.exteraless.settings.OpenExteraGeneralActivity&row=HideHelpSection
```

The General class permits `general`. `HideHelpSection` belongs to `hiding`, with
`appearance` as its previous page (**308**), so the constrained candidate set is
empty. The fallback then returns `.setting("appearance.hideHelpSection")`.
The same class/row request without the additional Nagram page qualifier fails.
Adding a qualifier has broadened, rather than narrowed, the route.

The original `SettingsHelper.java:127–138,380–403` supplies those Nagram moved-row
aliases, but supplies no mixed class-qualifier rule that discards an explicit
class. Current General has no such row; the declaration is in
`OpenExteraChatsActivity.java:785–788`. Preserve the authored Nagram redirects
while intersecting them with an explicitly supplied class, or reject inconsistent
qualifiers. The final `candidates.count == 1` check does not repair lost scope.

## Joined behavior established by source

### Application, stock search and actual UIKit navigation

- Runtime updates the actual domain integrations before installing the search
  session (`ExteralessClientRuntime.swift:272–322`). It captures the context object,
  preparation and termination predicates. `clearAccountDomains:379–405` retires
  the session, clears its weak provider and invalidates prior result capabilities.
  The late Reset integration is described below.
- `ExteralessSettingsUI.registerActions/unregisterActions:31–44` stamps actual
  registration events with UUIDs. Unlike R3's schema notifications, action ABA is
  preserved even if the intermediate catalog is never rendered. Selection checks
  the current registration through the fingerprint.
- `SEARCH/SettingsSearchableItems.swift:4487–4489` appends the provider through
  an invalidation signal. `SettingsSearchItem.swift:311–334,387–403` consumes those
  real items and resolves recent IDs against the current catalog. Recent IDs are
  session/version identifiers, not account-independent routes.
- The adapter at `SEARCH/ExteralessSettingsSearch.swift:8–28` validates the requested
  context, asks the actual PeerInfo search overlay to dismiss, then invokes the
  provider. `PEER/PeerInfoScreen.swift:5085–5110` supplies that real dismissal and
  navigation path; **5118–5133** revalidates Copy Link when selected.
- Root's Search UIBarButton invokes `searchPressed` at
  `ExteralessSettingsController.swift:216–225,448–451`. The resulting controller
  installs a real `UISearchBar.searchTextField`, UIKit `editingChanged`, and the
  grouped table renderer (`CLIENT/ExteralessSettingsSearch.swift:245–320`).
- The table delegate at `ExteralessSettingsUIHelpers.swift:356–360` executes the
  selected result's closure. Session navigation at `ExteralessSettingsSearch.swift:187–207`
  validates before and after ending editing and before the factory/push. Actual
  `Display/Source/ViewController.swift:646–648` forwards to
  `Display/Source/Navigation/NavigationController.swift:1702–1709`, which appends
  the real controller to the navigation stack.
- The existing factory selects Root/focus for booleans and explicit `.row`, the
  existing selector for options, and the private numeric/text/JSON/secret editor
  otherwise (`ExteralessSettingsController.swift:72–105`). Focus at
  `ExteralessSettingsSearch.swift:334–350` checks the ticket around layout, locates
  an existing mounted cell, scrolls/highlights it and checks validity again in its
  delayed cleanup. It invokes neither `didSelectRowAt` nor a switch/slider action.
  Secret editor initialization leaves its draft empty at Controller **142–148**.

Correctly retired sessions refuse items, tickets, links, factories and alerts
(`ExteralessSettingsSearch.swift:96–114,136–184,210–215`). R2–R4 identify the
specific paths where that authority is reacquired, never bound, or not advanced.

### Metadata, six API owner fields and immutable identities

`ExteralessSettingsSearchSession.refresh:123–133` passes definitions, secret
classifications and native action metadata to Core. `ClientSettings.readSnapshot`
is a cache read, redacts secrets and omits unknown stored fields
(`ClientSettings.swift:88–111,328–333`). The index constructs search text only from
title, section, explanation, namespaced identity and authored aliases
(`ClientSettingsSearchIndex.swift:144–193,218–232`). It does not enumerate
`valueShape` object fields or serialize current/default/option payloads as search
text, results, errors or URLs. Whole definitions are retained for equality;
registered credential defaults/options are constrained by
`ClientSettingDefinition.swift:149–161`.

The owner-page exception is exactly these six keys:

```text
clientAPI.customApi                 clientAPI.test.customApi
clientAPI.customAppId               clientAPI.test.customAppId
clientAPI.customAppHash             clientAPI.test.customAppHash
```

`ClientAPIFeatures.swift:19–37` supplies that closed list.
`ClientSettingsSearchIndex.swift:176–193,253–268` excludes an arbitrary
`clientAPI.privateJournal`, maps all six to **`clientAPI.edit`**, and maps
**`cloud.includeApiKeys`** to **`cloud.settings`**, including `.row` requests.
Missing owners fail explicitly. `Cloud/ExteralessCloudIntegration.swift:100–119`
checks its current context and opens the existing owner controllers. A link
supplies no ID/hash, environment change, include-keys toggle or draft mutation.
The API controller chooses its initial environment from the account and requires
separate user actions to edit/save (`Cloud/ExteralessClientAPIController.swift:15–20,29–47,73–124`).

Root and the index exclude `AI state`, the declared SDK compatibility keys and
the entire reserved **`compat.exteraconfig.`** prefix. Learned-secret/public-schema
migration disables generic navigation; a registered secret whose typed stored
value is unavailable can still reach its repair editor. The accepted **d7** Root
labels remain: **Stored value unavailable / Secure storage unavailable / Stored
securely / Not set** (`ExteralessSettingsController.swift:281–293`).

Ticket scope/version/identifier and route/action metadata are immutable `let`
values. Lookup uses exact registered keys/IDs and literal alias tables, not a
dictionary of arbitrary private fields or class-name reflection. Duplicate
catalog identities fail closed. Definition equality and registration versions
govern validation; value-only changes are not navigation authority.

Core/direct-search limits are **2048 entries**, **256 UTF-16 query units**, **16
terms** and **80 results**. The stock Settings projection retains its own token
matcher at `SEARCH/SettingsSearchableItems.swift:4546–4579`.

### URL grammar and Original routes

`ClientSettingsLink:298–354` bounds recognized URLs to 2048 bytes, rejects
userinfo/ports/fragments and encoded path separators, rejects double-encoded
native payload paths, and allows only the declared query names. Native setting,
row and action URLs accept no query; source URLs accept `page/class/row`, and
Original web links accept one of `r/row`. Duplicate decoded parameters and
`v/value/reset/import` are denied. Foreign hosts return no client route; a
foreign authority cannot acquire a settings destination.

`AC/ExteralessSettingsSearchEntry.swift:48–75` consumes recognized invalid or
unavailable requests locally. `OpenUrl.swift:369–382` precedes tracking cleanup,
native open hooks and `forceExternal`. The ordinary AppDelegate consumer waits
for real account readiness/unlock, times out after 30 seconds and cancels on
replacement. Its real lock signal is forwarded by
`telegram-ios/submodules/AppLock/Sources/AppLock.swift:126–133`; actual passcode
state is published at **229–279** through `State/AppLockStatus.swift:14–28`.
`SEARCH/SettingsSearchableItems.swift:4582–4586` handles a typed client
path before stock index lookup; `APP/OpenResolvedUrl.swift:1035–1046` is its real
caller. R1 is the separate application-ingress bypass; R2 concerns the in-app wait.

Legacy class redirects use the relevant literal `ClassAliases.EXACT` entries;
accepted canonical/short class names are also explicitly enumerated. Unknown/nested
class guesses fail. Row names and page aliases remain case-sensitive. The sole
multi-page class is Chats: its no-argument constructor really delegates to
`SCREEN_CHATS` (`OpenExteraChatsActivity.java:385–386`), so that declared default is
not an ambiguous first-candidate selection. Row resolution requires exactly one
distinct destination. Examples traced include `avatarCorners`, the moved
`chats/videoMessagesCamera`, and navigation's literal `-101`. R5 limits the claim
of strict qualifier intersection. Known unsupported rows remain explicit; adding
an alias does not fabricate their native provider.

Canonical Copy Link revalidates the selected ticket. A later deliberate open
resolves that URL in the then-current account. Retained search/recent-result
closures instead carry their original ticket; they do not silently rewrite it as
a fresh canonical request.

## Fixtures and remaining acceptance

| Evidence | Scope retained |
|---|---|
| Linux **43757030337 / 93edf05e** | User/coordinator-reported compile and **16/16 search tests**, within **687 Core**. Local `git show` bytes for the two Core sources and corrected test match the archived receipt. |
| Author's **7 Python driver contracts** | Supplied host/source-contract receipt, not a native UI pass; not rerun here. |
| `SettingsSearchUIViewRouteChecks.swift` | Given-context fixture using the existing configured store, real Root/Search/table/input/controller instances and native Back actions. Source-provided; native execution pending. |
| Eight recording scenarios | Existing **3+3+2** protocol retained: `core-light/core-dark/sdk-ui`, `feed-render/player-render/pill-render`, `avatar-render/composer-render`. None accepted from frames here. |

The UIKit fixture checks mounted result geometry, the actual switch row's
`isHighlighted`, unchanged values **and override presence**, a clearly named
fixture-native-page action, existing selector/editor views and deliberate session
retirement. It is selected by the harness BUILD at **70,109** and called by
`HARNESS/ClientHarnessScenarios.swift:31,40,52,63,80`. It does not create another
account or establish execution of the real Cloud/API services. The source-fingerprint
wrapper is `HARNESS/ClientHarnessSettingsSearch.swift:12–38`.

Both added probes fit the existing **13-probe** Core sequence. The six 650 ms
settles add approximately 3.9 seconds; the driver still has a **30-second** process
budget. Actual timing remains an acceptance measurement. The existing
`secret-availability` source and scenario-selection source retain their receipt
hashes.

The pre-recording expectations in
[settings-search-remediation.md](../settings-search-remediation.md#expected-frames-specified-before-recording)
remain the visual criteria: real search chrome/results, visible unchanged control
and row highlight, correct Back stack, unclipped light/dark frames and clean
retirement/home. UIKit property/geometry assertions cannot certify those pixels;
acceptance requires frame indices and **ffprobe PTS**. Future given-context checks
must exercise the five witnesses above, particularly a retained default Root,
private editor/focus, coalesced schema ABA and a pending URL across replacement.

## Late Reset join and read-time fingerprints

Concurrent edits observed at **20:32–20:34 UTC** added Runtime's
`SettingsResetIntegration`, its BUILD fingerprint glob and the
`other/resetSettings → general.settingsReset` alias. The updated integration
registers before search installation; its clear now precedes search retirement.
`SettingsResetIntegration.swift:27–43` opens the native Reset page;
`SettingsResetController.swift:58–92` schedules its preview. This accounts for the
new search action/alias without assigning a general Reset implementation verdict.

The Core test gained the corresponding registered-action assertion at **203–205**.
Its new bytes and the revised route table are **not** covered by the supplied
93edf05e pass. The archive still pins the earlier tested snapshot. These edits do
not change the five counterexample paths above. The frozen 55-action declaration
map remains its original boundary; it is not a current live-row count.

Read-only Python data/hash/AST checks, each bounded to 30 seconds, confirmed:
the packet's 16/50 plus 1/1 decomposition; all **12 receipt-listed archive member
pins**; **12/12 Original file pins**; **16/16 accepted registration-source pins**;
the **16 test method names**; driver **13 probes / 30 seconds**; and the two
preserved harness-source pins. An initial current-cohort equality check stopped on
the concurrent route-table change; the subsequent check records both changed
Core files explicitly instead of treating the old archive as their postimage.

Initial 16-file raw postimages are exactly those in the immutable applied JSON
(SHA-256 `ac2696f72b3632d1358759e708bf81f8966b924c04f2664f7329ac8254ceb1e5`).
At 20:32:39, **14/16** still matched; Runtime and TelegramUI BUILD had the named
Reset additions. No source postimage was restored over those edits.

| Artifact | Initial read-time SHA-256 | Later read-time SHA-256 |
|---|---|---|
| Remediation document | `774f58569dcc178b62db5f46ac9544f9be54f3dfa633b5385ce61b4193e6d641` | `bd41246fb33d2c0cd7964c3a234982986a3c430ba46a8f121879f9236f48abe9` |
| `CORE/ClientSettingsSourceRoutes.swift` | `1c3929d6fa07270abaa3059cc869c0c7b41e5ff82f0a8865b6fde0fa564c5496` | `820eaf1fa00bfbcb53232b5fda6711cc39676d7dea66cab2da473f4c6542eabe` |
| `swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsSearchTests.swift` | `2181e9ac2ab100419fda6e0bc549986adfe89e94d1ebadf406528ee9b366ef03` | `6a2228317f0e4e4f0b8d5fcc3ff247f0277c6c70de4b32655a4c9021ef73eaf5` |
| `CLIENT/ExteralessClientRuntime.swift` | `b6b066575d9ad2af0ef81e2f103f589ad1498b78b3eed9e9fe5c056832c58b27` | `5041de7b3d2e5d0098ec61773eef3617a63984dd167b946e443e1c5242fd48e8` |
| `telegram-ios/submodules/TelegramUI/BUILD` | `bc7ec961ff6444ea7fdc589891813f4b1a7702e2183d058e1b68124ca3623ef8` | `4931ffba01c25541800582d062c4f7640966539b4f3131e4bdb87ce7702acf2b` |
| `telegram-ios/Tests/Exteraless/BUILD` | `0665dd2749723e181dd37bdf67fc545fcb5bbba4843c52994b1efb933d9ac61b` | `8d6349b229fdf223b16e5c6be026729ca4ff923ec9ff8ad5dca058687b168bc5` |

Later pins in that table were captured at **20:34:50 UTC**. The BUILD export is
present at lines **8–11**; the old deferred flag in the application receipt is
historical. The remediation's later coordinator note also records its completion.

<details>
<summary>Additional raw pins for the reviewed search implementation and supporting callers</summary>

```text
ffc974596dbabdc71a4667e6673eca21dfd0a7eb0ab283832e6984daef1e406f docs/wave-2/module-routes/settings.json
653a1c5007587175a6d5a6f62a9dd39bfecf4b707e85df2cfa2e028b864dd36c swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSearchIndex.swift
203b973a7f09bb657075ea92daf22065e2ee0baf060147bbc8c0661f1231c556 swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift
fa06bb1f791b9de9a896d6aa625e4358cb3d954fc242b9b9ac4c87d4d65d3cb5 telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsSearchEntry.swift
31d57e33cd116d1aca8e5f1a50d5cb231153d77208832a17f65c2fcd7f859f59 telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsEntry.swift
f0f13a860092be48dd4b0485958a8c30a84c9e8ec92a2debb0adf42428cd3a19 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsSearch.swift
38e80de4588af477064bd1bb36793855e8918ee0ef181f18f1ae7df6d6fd5ed0 telegram-ios/submodules/SettingsUI/Sources/Search/ExteralessSettingsSearch.swift
a989e146236ac2ca2fe378f6a8b041df9185cad393e7e1d78997d09a1324994a telegram-ios/submodules/SettingsUI/Sources/Search/SettingsSearchItem.swift
eb42f03719fe7bad39534194509601024475441daf5b70304438b63fea26bfe0 telegram-ios/submodules/TelegramUI/Sources/ApplicationContext.swift
4d6a22ae9d3e72eba29c3b025309d508b2b0d9debb6caaa4685cb48ce76dffa8 telegram-ios/submodules/TelegramUI/Sources/SharedAccountContext.swift
afb5aa8bd9c4e762c7e0d19538058bbf44db0ef88c2d6c6beb2d23831251594a telegram-ios/submodules/TelegramUI/Sources/OpenResolvedUrl.swift
9c1ff02e4a17096b0eacb2630d5f9218c439625fbd1467abe534de318f1f05e2 telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift
161d3ec4f774e45d3abeba0e0a6cab3e8570a5946c72271235544151597d4493 telegram-ios/submodules/AppLock/Sources/AppLock.swift
d475e849560a8e14a08d88134e5b58b09a58b868f2d022369e7bdadd07fea12f telegram-ios/submodules/AppLock/Sources/State/AppLockStatus.swift
2f697cd25a01375ce6ccaa1753e1dec7758eeef8f2c7bfe2f17d11c6a536d7d5 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/NativeServiceOpenHooks.swift
05ed1af2ac1d6418b4f80f3b9efc8054f07c3687daa2f101f30413a1d09d81fb swift/PluginHost/Sources/PluginHost/NativeServiceInterceptionModels.swift
f97529c4feb219f34a9167eb8f867bd040b5f96479bbce42ad623ef82e9e54e9 swift/PluginHost/Sources/PluginHost/NativeServiceOpenBarrier.swift
906dc689c32c820d092cd8f1ea2d8ac393ecb823f51acfd5543a3d10dbcd8d68 telegram-ios/submodules/Display/Source/ViewController.swift
1b1578150658bcf25361d95dfc56e99bc3a6cae745b646ca8e6dd08fdfa5b69d telegram-ios/submodules/Display/Source/Navigation/NavigationController.swift
c337944f7e500bd52c783ea70669e2ba818fdf0d25ed3ebb16ebb825de04e682 telegram-ios/Tests/Exteraless/SettingsSearchUIViewRouteChecks.swift
5ff47c09b4fd54a61809591622ab2d7d2a55ca1e6b5e07d67d0144137d383c37 third_party/exteraless-android/TMessagesProj/src/main/java/tw/nekomimi/nekogram/helpers/SettingsHelper.java
74cfd0742414ea39ad85559da1e5bfe15ea82e86fe6c0c1dc6bf45121c909296 third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/plugins/ClassAliases.java
bbbdae624a8a00ac07bc30e5402efee0347013ade5273b2a81618bd18cb67e4d telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetIntegration.swift
bd97d5f2b322134c78d07616d344c02fc8ee95d00fd1de405fa2282b44fb0ecc telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetController.swift
```

Supporting caller pins were captured at 20:34:50 UTC; Display, open-barrier and
late Reset-controller pins at 20:38:23 UTC. These identify reviewed source, not
compiled artifacts or a whole-app dependency fingerprint.

</details>
