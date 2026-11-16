# MS-ROUTE-01 — native settings search and routes

**APPLIED: 16 authorized paths / 50 hunks, using `functions.patch`.** The actual
Root, SettingsUI, URL handlers and harness now contain the settings-search join.
[settings-search-applied.json](settings-search-applied.json) records every exact
applied path, byte length and raw post-hash. The full original packet is retained
as [settings-search-shared.patch](settings-search-shared.patch).

**One deferred hunk:** `telegram-ios/Tests/Exteraless/BUILD` remains with its trust
owner. Apply only [settings-search-tests-build.patch](settings-search-tests-build.patch)
there; it exports the UIKit check source selected by the harness. That export is
still required for the joined harness build.

Reverse packet check passed for all 16 applied paths. **7 Python driver-contract
tests passed (0.062s); `CORE_PROBES` has 13 entries in the actual Swift call order.**
The four secret labels, existing secret-availability segment and **3+3+2** batches
are preserved, as is the coordinator's `ExteralessManagerCustomAliasSources` group.
Swift is unavailable locally; native app/UIKit compilation and frame acceptance
remain unrun here. The separately reported Core run is scoped below.

The ready [Linux Core cohort](settings-search-core-cohort.tar.gz) contains both
author files, the exact 16-test source, seven unchanged dependencies and a
standalone Swift 6 manifest. Its [receipt](settings-search-core-cohort.json) pins
all members and the bounded 120s-build/30s-test commands. No Swift execution is
claimed by the archive/source checks.

**Late coordinator evidence:** CI **43756548501 / 1c97** compiled and executed
Core; the sole reported failure was the localized-title fixture's broad
`key.hasSuffix(".Title")` mapper, which also renamed `Search.Title`. The index's
tie ordering was not changed. The actual test source now preserves the coordinator's
exact `Setting.appearance.avatarCorners.Title` mapper and independent
`Search Exteraless → .search` control. Its SHA-256 is
`2181e9ac2ab100419fda6e0bc549986adfe89e94d1ebadf406528ee9b366ef03`.
The ready archive was refreshed to those bytes; this corrected fixture is not
declared executed by this handoff, and no CI query was made.

## Delivered compiler inputs

| New file | Compiled owner / role |
|---|---|
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSearchIndex.swift` | ExteralessCore; metadata index, result tickets, typed routes/URL parser |
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSourceRoutes.swift` | ExteralessCore; authored Original row/page/class redirects and explicit unavailable destinations |
| `swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsSearchTests.swift` | SwiftPM ExteralessCoreTests; 16 bounded functional fixtures |
| `telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsSearchEntry.swift` | AccountContext; typed weak-provider seam and invalidation signal |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsSearch.swift` | TelegramUI; live session, registration versions, actual search UI and row-focus helper |
| `telegram-ios/submodules/SettingsUI/Sources/Search/ExteralessSettingsSearch.swift` | SettingsUI; projection into actual `SettingsSearchableItem` results |
| `telegram-ios/Tests/Exteraless/SettingsSearchUIViewRouteChecks.swift` | Given-context UIKit checks; selected by applied harness BUILD, source export is the one deferred hunk |

Production source globs already select the Core, AccountContext, TelegramUI and
SettingsUI files. AccountContext already depends on ExteralessCore. The adapter
uses AccountContext/Display/SwiftSignalKit; it does not import TelegramUI or
Postbox. No new Postbox import appears in any delivered Swift file. The stock
recent-search path continues using TelegramEngine.

Core's existing `ClientHarnessDomainFingerprintSources` pattern
`ClientSetting*.swift` includes both new Core files. The applied changes add the
AccountContext/TelegramUI sources and shared URL/search callers to fingerprint
groups, expose the SettingsUI/PeerInfo source groups, and select the UIKit checks
in the existing harness library. The new harness wrapper
`Sources/ClientHarnessSettingsSearch.swift` is an actual applied source file.
No workflow, SDK runtime, account-constructor or scenario-list change is needed.

## Applied entry paths

1. `ExteralessClientRuntime.update(context:)` installs a session **after** the
   actual domain integrations update. `clearAccountDomains()` retires it before
   clearing account-owned integrations. The predicate checks the actual current
   context object, preparation and termination state.
2. `ExteralessSettingsUI.registerActions/unregisterActions` stamp the real
   registration events. Re-registering or removing/reinserting the same ID retires
   previously selected action tickets, even if titles or closure values look equal.
3. Root gains its actual navigation-bar Search action. It creates
   `ExteralessSettingsSearchController`, using `UISearchBar.searchTextField`, actual
   grouped UITableView cells, native row selection and the existing presentation
   data/layout helpers. Query changes run through UIKit `editingChanged`.
4. Stock `settingsSearchableItems(...)` appends the provider's current items through
   an invalidation signal. Selecting one dismisses native settings search and
   invokes the same context/version checked session. It creates no placeholder
   controller to stand in for navigation.
5. Generic setting destinations use the **existing**
   `ExteralessClientSettingsController`: boolean → Root plus row focus; enum →
   selector; numeric/text/structured/secret → existing editor. `.row` explicitly
   requests Root focus. No table/control selection is fired by the focus helper.
6. Action destinations invoke the actual currently registered
   `ExteralessSettingsAction.action(context,presenter)` closure. Domain factories
   and their existing readiness/error behavior remain authoritative.
7. AppDelegate handles recognized URLs behind actual account readiness/AppLock,
   with a bounded 30-second pending subscription, context-identity check and
   cancellation on context replacement. In-app OpenUrl uses the lock gate and the
   current provider. Stock `handleSettingsPathUrl` handles typed client paths before
   its ordinary native index lookup. Recognized malformed/unavailable client URLs
   are consumed locally.

## Metadata, availability and ticket contract

`ClientSettingsSearchIndex.refresh` takes **definitions, secret classifications and
native action metadata**, not `snapshot.values`, persisted overrides, a credential
getter, a Postbox reader or an arbitrary object serializer.

- Indexed text is the registered title, explanation, section, stable key/action
  identity and authored source aliases. Localization uses the same
  `clientSettingsText` keys as Root. No current/default credential payload is
  interpolated into a result, error, URL or search term.
- Root and the index use the shared `isGenericVisible` policy: AI-state fields,
  the SDK-only compatibility definitions/reserved prefix, and generic Client API
  controls remain hidden. The index allows only the **known six** Client API
  definitions as owner-page results; an unknown registered API-private journal
  does not become searchable.
- `clientAPI.*` field links/results always resolve to **`clientAPI.edit`**.
  `cloud.includeApiKeys` resolves to **`cloud.settings`**. `.row` cannot bypass that
  ownership. The user chooses the environment/options on the owner page; a link
  never supplies an ID/hash, enables key inclusion or changes a draft.
- A missing owning action is explicitly unavailable. Removed actions vanish on
  refresh. Learned-secret/public-schema migration disables generic navigation.
  A registered secret with unavailable typed data can still open its existing
  repair editor; value availability is not falsely treated as navigation absence.
- Definition equality, localized metadata, destination and action-registration
  UUID form the entry fingerprint. Tickets carry **session UUID + monotonic
  entry version + namespaced identifier**. Unchanged refresh retains identity;
  changed/removed/re-added definitions/actions invalidate it. Raw value changes
  alone do not authorize or invalidate unrelated routes.
- A retained result is revalidated on invocation, after ending editing, and before
  constructing/pushing the existing controller. Retirement stops results, links,
  factories and actions. A stale context cannot even construct an error alert.
- Stock recent IDs are scope/version IDs, so an old account/process result does
  not silently bind to a new owner. Copy Link separately emits a canonical URL
  after current-ticket validation. Canonical URLs intentionally resolve afresh
  in the account in which the user opens them.
- Index limits: **2048 total entries**, 2048-byte raw titles, 512-byte sections,
  8192-byte explanations; duplicate identities/oversized catalogs fail closed.
  Search accepts **256 UTF-16 units / 16 terms** and returns at most **80** results.
  Input URLs are bounded to **2048 bytes**.

The action source is exactly `ExteralessSettingsUI.registeredActions`, not widget
class inspection or matching an unrelated `NSStringFromClass` name. Root's own
action enabled state is local busy state; additional provider checks remain in
the registered domain action. Indexing does not execute those actions or promise
their remote service is available.

### The accepted secret-label branch is retained

The shared packet starts from SettingsController SHA-256
`e8f2d6b67c4dc64a9f0dc5b7956121c40f6a4da5764e720fa00b1fdc38d26ed0`.
Its four-label branch remains present in the actual applied source:

| State | Root label |
|---|---|
| `values[key] == nil`, known stored | Stored value unavailable |
| `values[key] == nil`, no known presence | Secure storage unavailable |
| Typed available/redacted `.null`, stored | Stored securely |
| Typed available/redacted `.null`, absent override | Not set |

`ClientSettingsSnapshot`/store APIs are unchanged. Search never fills a credential
editor from an indexed value. Root retains explicit reset, including VoiceOver;
its long-press menu now offers Copy settings link and Reset. The menu waits for
dismissal and revalidates the ticket before presenting reset confirmation.

## Typed URL and Original alias surface

| Input | Actual destination |
|---|---|
| `tg://settings/exteraless` | Existing client Root |
| `tg://settings/exteraless/search` | Actual native client search controller |
| `tg://settings/exteraless/setting/appearance.avatarCorners` | Existing numeric editor |
| `tg://settings/exteraless/row/appearance.hideHelpSection` | Existing Root, highlighted control; no toggle |
| `tg://settings/exteraless/action/appearance.customizeMenu` | Registered native Customize Main Menu factory |
| `https://t.me/exteraless/appearance?r=avatarCorners` | Original row alias → canonical avatar editor |
| `https://t.me/nasettings/exteraless_chats?r=videoMessagesCamera` | Original moved row → `tools.videoMessageCameraFacing` selector |
| `tg://settings/exteraless/source?class=com.exteragram.messenger.preferences.AppearancePreferencesActivity&row=avatarCorners` | Exact Original class redirect + row → canonical editor |
| `tg://settings/exteraless/setting/clientAPI.test.customAppHash` | Registered Client API owner page, not a generic hash editor |

The source table names row symbols and literal aliases, known moved-page
relationships, App Navigation's explicit negative IDs, and the exact relevant
`ClassAliases.EXACT` redirects. Chats' no-argument class default is Chats; explicit
page/row qualifiers disambiguate its four constructor modes. Conflicting class/page
qualifiers or multiple different destinations fail with an ambiguity error.
No default-first-candidate or arbitrary class-name reflection is used.

No `v`, `value`, reset/import query, duplicate parameter, foreign authority,
fragment, encoded path separator or double-encoded native path is accepted.
Unknown/private fields are not recovered from stored JSON. Non-client URLs are
left to the existing dispatcher; recognized bad client links do not fall through
to a network resolver.

Unavailable Original destinations have authored reasons, including Glyph,
Android push/battery/camera-engine controls, unsupported composite resets and
unregistered project links. Existing stock Delete Account/Sensitive Content,
Plugins and nested weather pages have their independently owned entries; this
client registry does not invent a new action ID for them. A known alias whose
canonical provider is not registered in the current context reports that fact.
Adding a source alias does not implement the feature behind its destination.

### Original pins

The twelve settings files use the accepted
[`module-routes/settings.json`](module-routes/settings.json) source boundary and
file pins (map SHA-256
`ffc974596dbabdc71a4667e6673eca21dfd0a7eb0ab283832e6984daef1e406f`).
Additional directly read inputs:

| Path | Raw SHA-256 |
|---|---|
| `third_party/exteraless-android/TMessagesProj/src/main/java/tw/nekomimi/nekogram/helpers/SettingsHelper.java` | `5ff47c09b4fd54a61809591622ab2d7d2a55ca1e6b5e07d67d0144137d383c37` |
| `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/plugins/ClassAliases.java` | `74cfd0742414ea39ad85559da1e5bfe15ea82e86fe6c0c1dc6bf45121c909296` |

SettingsRegistry's runtime plugin UItem/alias maps are not enumerated from static
row declarations. Unknown runtime plugin entries have no inferred native route.

## Actual registration paths

Paths below are under
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/`.
The 16 files supplying the accepted 55 native action declarations were compared
with the accepted map's raw pins: **zero registration-source drift** at handoff.
That is a source-declaration boundary, not a rendered/live row count.

| Registration source | Native action family |
|---|---|
| `Appearance/ExteralessAppearanceIntegration.swift` | nativeThemes, autoNight, appIcons, mainMenu, customizeMenu, iconPacks, editIconPack |
| `Appearance/ExteralessMonetThemeActions.swift` | appearance.monetThemes |
| `Chats/ExteralessChatIntegration.swift` | chats.feed/player/bookmarks/deleteDefaults/trackingFilter |
| `Player/ExteralessPlayerIntegration.swift` | appearance.playerLibrary/playerDecoderInfo |
| `Pills/ExteralessPillIntegration.swift` | pills.status |
| `Privacy/ExteralessPrivacyIntegration.swift` | privacy.ghost/chat/botAccount/proxies/notifications |
| `PrivacyExtras/ExteralessPrivacyExtrasIntegration.swift` | privacy.localFilters/hiddenAccounts |
| `Dialogs/ExteralessDialogIntegration.swift` | dialogs.forumLayout |
| `AI/ExteralessAIIntegration.swift` | ai.services/roles/editor/result/translationModels/translationLanguages/speech/pluginReview |
| `Tools/ExteralessToolsIntegration.swift` | tools.fileSaving/favoriteStickers/backup/updates/diagnostics/files/shortcuts |
| `Network/ExteralessNetworkIntegration.swift` | network.resolverStatus |
| `Maps/ExteralessMapIntegration.swift` | maps.providerScope |
| `Stickers/ExteralessStickerIntegration.swift` | emojiPacks, pinnedChats/Channels, quickReaction, nativePacks/nativeEmojiPacks, localGifs |
| `Identity/ExteralessIdentityIntegration.swift` | identity.account |
| `Retention/ExteralessRetentionIntegration.swift` | retention.archive/importAyu/chatRecords/exceptions |
| `Cloud/ExteralessCloudIntegration.swift` | cloud.settings and clientAPI.edit |

## Fixtures and expected frames

### Pure Core fixtures — corrected coordinator source retained

The 16 XCTest methods (not executed locally) cover localized/explanation/Original-name search;
exact class/moved-row redirects and case-sensitive identity; conflicting
qualifiers/duplicate native identities; unchanged versus changed definitions;
definition/action removal and ABA; different/retired scopes; all compatibility
fields and unknown API-private state; owned API/Cloud routing; secret migration
versus repair; real isolated ClientSettings plus injected secret-store I/O
counters; canonical URL round trips; malformed/value-import/duplicate URLs;
explicit unavailable rows; and query/result/catalog bounds.

The secret fixture uses owned sentinel bytes and a real temporary Core file.
The index receives only its actual metadata snapshot and must neither perform
secret backend I/O nor find the sentinel/unknown stored field. No live account,
system Keychain or network transport is needed by these Core fixtures.

### Given-context UIKit fixture — applied source

`SettingsSearchUIViewRouteChecks` accepts the harness's existing real context,
navigation and four-field ClientSettings fixture. It does not construct another
account. The applied source calls it from `core-light`/`core-dark`:

- Actual Root Search UIBarButton target/action → real UISearchBar field
  `editingChanged` → actual result UITableView delegate → existing Root/control.
- Checks actual mounted cell geometry, selected-row highlight and unchanged
  values **and override presence**, then returns through native Back actions.
- A clearly named **fixture native-page action** opens the shipping settings
  renderer exactly once. This checks action dispatch without impersonating a
  Cloud/API/network provider.
- Existing selector/text/numeric probes additionally assert their actual option
  and input views. Root row activation now shares the same session/factory used
  by typed setting links.
- After the original core screen has returned home, retained tickets, search and
  Root factories, editor links and action calls must all refuse the retired scope,
  with no new controller/alert or action invocation.

This is an executable given-context fixture, not an additional standalone XCTest
label. It is selected for the existing harness library and called by the applied
core-scenario source; actual compilation awaits the deferred source export.
The two new probes are `settings-search-results` and `settings-search-row`.
The existing `secret-availability` segment and checks remain present.

### Expected frames, specified before recording

| Probe/segment | Required observed frames |
|---|---|
| Root → Search | Native push/chrome transition; actual search field above grouped results, no blank canvas, duplicate title or clipped controls. Settle 0.65s before input. |
| `settings-search-results` | Query `harness.enabled`; actual **Fixture enabled** result with section/metadata detail. No stored values in result text. Real table cell has positive geometry inside the live window. Light/dark follow the current Telegram palette. |
| `settings-search-row` | Existing Root's **Fixture enabled** switch is visible and its row is highlighted. The switch and all four stored fixture values/presence remain unchanged. No synthesized switch, automatic tap, keyboard obstruction or extra selection callback. |
| Back / fixture action | Back returns to Search, then original Root; the fixture action opens the same shipping settings renderer and returns. No lingering search controller, modal, highlight on another row or bright dark-mode frame. |
| Existing selector/editor probes | Actual option checkmarks and actual editor UITextInput are supplied by the existing renderer through the new route helper. Existing validation/save assertions continue to apply. |
| Retirement/home | No additional controller or alert is created; home remains the sole root. The following existing secret-label segment still renders its three distinct statuses. |

The segment adds six fixed 650ms settles (~3.9s plus bounded local UI work), with
two probes. It does not extend the existing native/driver **30-second whole-process
deadline**. Coordinator timing must still establish that the complete core process
fits it. Scenario batches remain exactly **3+3+2**; no new process, batch, simulator
or recording scenario is introduced. Frame indices/timing acceptance must come
from the eventual recordings and ffprobe PTS, not these source expectations.

## Applied-source validation

From the repository root, the application was checked with:

```text
git apply --reverse --check --exclude=telegram-ios/Tests/Exteraless/BUILD docs/wave-2/settings-search-shared.patch
python -B -m unittest discover -s telegram-ios/Tests/ExteralessHarness/Tests -p test_driver_contract.py -v
```

Source checks verified each actual post-hash, unique source-hunk application,
Python/Starlark syntax, all 13 core probe IDs/order, four secret labels, unchanged
secret-availability/scenario source pins and the ManagerCustomAliasSources block
hash. The Core archive's member set, internal checksum list and repository source
bytes were compared without running Swift. The earlier new-Swift lexical/import
checks remain source checks, not a typecheck or a passing XCTest/UIKit run.

No CI, commit, simulator, live account, network, external plugin or Swift compile
was run. The 16 specifically authorized paths were applied directly; the excluded
Tests/Exteraless BUILD and unrelated Developer/CustomUI/PluginRuntime work were not
edited. The accepted route-map receipts remain the prior source snapshot.

SDK ConfigManifest was not regenerated. The applied `ExteralessClientRuntime`
raw pin is now `b6b066575d9ad2af0ef81e2f103f589ad1498b78b3eed9e9fe5c056832c58b27`
(previously `5709414fc3a29f553eb160c3fc267956e3138de56fc207cbcf61e57981a4dcbf`).
This is expected Root-pin drift for the coordinator's later SDK regeneration
after unrelated PluginRuntime work is joined.

### Applied input → actual post-hashes

Base SHA-256 is the read-time checkout input. Post SHA-256 is the **actual raw
applied file**, currently UTF-8 LF. The separate JSON receipt uses full paths.
Prefixes in this table: `UI` = `telegram-ios/submodules/TelegramUI/`, `H` =
`telegram-ios/Tests/ExteralessHarness/`, `S` = `telegram-ios/submodules/SettingsUI/`.

| Shared path | Base SHA-256 | Postimage LF SHA-256 |
|---|---|---|
| `UI/Sources/ExteralessClient/ExteralessSettingsController.swift` | `e8f2d6b67c4dc64a9f0dc5b7956121c40f6a4da5764e720fa00b1fdc38d26ed0` | `6b84ab54c99f85325066daed71717d9f8b57139e228a43c6d39f62921ac3053a` |
| `UI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift` | `79ac4211fb894dcfc200b2d668964616582339d9476918c6536495e029be79a2` | `92d974d7eaf88b71c2cf9157f4fd9fef3b73f913e2cd1cdc486aed85a4de630b` |
| `UI/Sources/ExteralessClient/ExteralessClientRuntime.swift` | `5709414fc3a29f553eb160c3fc267956e3138de56fc207cbcf61e57981a4dcbf` | `b6b066575d9ad2af0ef81e2f103f589ad1498b78b3eed9e9fe5c056832c58b27` |
| `S/Sources/Search/SettingsSearchableItems.swift` | `ae29f3c25ac8953378b2dc0a0c6a58ec9d2515c6ef1007380f2378b72c2fb676` | `dfd6cb16d526075cb221cdf8b7043ac989f6206e99e4fc071e5184abd704bf86` |
| `UI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift` | `ecbedfd0769269b8907f6063bf557b4a8594c976c5904505d48c9de8802163ae` | `70a014013b4f4f82b4a0b885e3426474d189c53fa2b17e833c1cb900ce03d140` |
| `UI/Sources/OpenUrl.swift` | `7f9af800b39f373906069e6e16c1e80b28bc42f86858a9204818e3d717e0b264` | `1bec273cbb339ce173af41a63d366ea11ae623a34fafeff5e01dffa45019cc67` |
| `UI/Sources/AppDelegate.swift` | `41510dbce703be2fee7070c18f6bb942e9cfde70279bb5f4c8d2209bc67f7636` | `bc6137f4a134e191f8923223b8c6a4023cb54aa06b884e5f0cba972d900690e4` |
| `telegram-ios/submodules/AccountContext/BUILD` | `613c6e683d0ac77ae3362a71e706bd94ccf594eb7d428d620ce2d0c7e4b1f7be` | `b30c6f9f7ea19046eb8e9ab0fcda5d491539ca0b3b3b64a7d79ca6f0344bb3c8` |
| `UI/BUILD` | `98cb9853672b1bf7f6ea8f45aceda598c43db33fa0c5c664b991e599d8cfc20f` | `bc7ec961ff6444ea7fdc589891813f4b1a7702e2183d058e1b68124ca3623ef8` |
| `S/BUILD` | `d4a91306cd7686704d693623cfe32882c0953b7cec0ddb2e24317ee8a4fb6c18` | `7c0c9e467ca55332a3f9428111534532a82652651a77adc5c69e4699c8ce45f3` |
| `UI/Components/PeerInfo/PeerInfoScreen/BUILD` | `6e3ab9c38b79e8dbb56b8440cd25486be3e523e6934e4b32e4452ec07a238a90` | `19484f3c0fb0e71c73bb10370a991bbc5c7317c0dece4d26040e225ce02ec058` |
| `H/BUILD` | `c802e04b329ecf9df6e07c310a89a9ec820d643f76ce2a33cf38eebcd2730d73` | `dd2710d544e3e683024a1eacae790582be78cb28571c370936467cb5d60e0b69` |
| `H/Sources/ClientHarnessApplication.swift` | `0e037ddbdddbeefc3b7c771c8b913bdf3682cc6a79dca371fef16f6cad0bbf00` | `33cc85ff5b094d1ade34a06af41ddff9d9d947e9bb38ad6d5c16b6dc1d9c11c0` |
| `H/Sources/ClientHarnessScenarios.swift` | `f6be7ff6d68c18ff8ecb62bd6726eea84fddc45a932bc61a6ae12faae654f043` | `280984ae4486efcc757f6c6af4e24c3c465811a2d8b440a8a238eef4b9164455` |
| `H/Sources/ClientHarnessSettingsSearch.swift` | newly applied | `6b462f63b9ffe5292cc820cc4a1e190110d288574371bfc60592d1ef5030e19c` |
| `tools/runtime/client_ui_harness.py` | `ba64e92ce31978bccd4eb7bf10a6f561480c2a9dea3065cbe87860885a5dd6e4` | `c9dbe6bbf5d2d2e4887da5dfc32631744884890d5e6fc817b115a05a262651d7` |

## New artifact SHA-256

Use the full paths in the compiler-input table to distinguish the two module-local
`ExteralessSettingsSearch.swift` files.

| New artifact | Raw SHA-256 |
|---|---|
| `ClientSettingsSearchIndex.swift` | `653a1c5007587175a6d5a6f62a9dd39bfecf4b707e85df2cfa2e028b864dd36c` |
| `ClientSettingsSourceRoutes.swift` | `1c3929d6fa07270abaa3059cc869c0c7b41e5ff82f0a8865b6fde0fa564c5496` |
| `ClientSettingsSearchTests.swift` (coordinator mapper fix) | `2181e9ac2ab100419fda6e0bc549986adfe89e94d1ebadf406528ee9b366ef03` |
| `ExteralessSettingsSearchEntry.swift` | `fa06bb1f791b9de9a896d6aa625e4358cb3d954fc242b9b9ac4c87d4d65d3cb5` |
| TelegramUI `ExteralessSettingsSearch.swift` | `f0f13a860092be48dd4b0485958a8c30a84c9e8ec92a2debb0adf42428cd3a19` |
| SettingsUI `ExteralessSettingsSearch.swift` | `38e80de4588af477064bd1bb36793855e8918ee0ef181f18f1ae7df6d6fd5ed0` |
| `SettingsSearchUIViewRouteChecks.swift` | `c337944f7e500bd52c783ea70669e2ba818fdf0d25ed3ebb16ebb825de04e682` |
| `settings-search-shared.patch` | `302cf3010dd7ae899698a4aa09d6d0c62b134c3b9a3cb349ecdcd28d00aa580d` |

Coordinator applied the remaining `Tests/Exteraless/BUILD` source export after the
trust owner completed that file. All17 shared paths are now joined. The corrected
Core search cohort passed Linux43757030337/93edf05e within687 Core tests; native
UIKit execution and recorded frames remain separate pending checks.
| Deferred `settings-search-tests-build.patch` | `3fa9c2675b8f9cb467fc701058fbaf449f4b70db698050e15551b5ba383b097c` |
| Linux `settings-search-core-cohort.tar.gz` | `c15c986b1d4ea1f5c722b68fb5112bb4eb835fc68c1e9b8e5728079bfd364585` |

## 2026-11-16 — R1–R5 production remediation applied

Coordinator CI43763528246/27360543 compiled and ran the Core delta. One fixture
attempted to read `settings.json` after schema registration alone, which correctly
leaves a cold store fileless. It now seeds an actual public override with `setPublic`
before recording the file bytes. All schema-ABA, unchanged-value/presence and
byte-for-byte persistence assertions are preserved. Production code is unchanged
by this fixture correction; the original R1–R5 receipt retains its prior hashes.

**19 source/test paths are applied, including production fixes for all five
counterexamples.** The full-path receipt is
[settings-search-r1-r5-applied.json](settings-search-r1-r5-applied.json).
This appendix supplies the current source status and pins for this pass; the
earlier receipts describe their original snapshots. The independent
[source review](reviews/settings-search-source-closure.md) remains byte-unchanged:
`a649cc519b15ea93ac959d3905f66c9072c5485aa789c018e011b5db0ad52c86`.

### Applied production behavior

| Review witness | Applied change |
|---|---|
| **R1 — launch/notification ingress** | `AppDelegate.openUrlWhenReady` now calls the **existing** `consumeClientSettingsURL` immediately after privacy recovery and before `NativeServiceOpenHooks.interceptURL`. Recognized invalid/value-bearing URLs return locally. The consumer's actual account-ready, unlock, timeout, captured authorized-context and disposable checks are byte-identical to its preimage. |
| **R2 — pending unlock ABA** | `OpenUrl` prepares an operation **before** `dismissInput` and before subscribing. Preparation strongly captures the concrete session and the resolved item/ticket, or a typed error. The session owns its pending `DisposableSet`, disposes it on retirement/deinit and removes completed subscriptions. Its continuation checks that original lifetime before evaluating the nil-navigation/main-window parent lookup. Provider replacement retires the preceding provider. Only a new explicit open resolves against the new provider. |
| **R3 — coalesced schema ABA** | `ClientSettings.publish` mints a per-definition UUID under `cacheLock` and publishes it atomically with that definition. The native session supplies the snapshot IDs to every index refresh/admission. A→B→A therefore differs even when neither queued MainActor invalidation read B. Identical declarations, value-only writes, override changes and backend errors retain IDs; schema/classification changes replace them. The map contains current definitions only. |
| **R4 — unbound default Root/editor** | The actual context-only factory delegates to the installed live provider and returns `ViewController?`. The store overload requires that provider's exact store. Private controller construction requires a matching session and ticket before `super.init`; its session is nonoptional. The private editor fallback is removed, and Root rows retain tickets. MainMenu, Player, the installed AccountContext factory and harness callers propagate unavailability. Retired input/save/reset/search/export continuations cannot create new route UI. |
| **R5 — discarded class qualifier** | The Nagram moved-row fallback retains `classPages` and intersects every fallback candidate with it. General + `nasettings/general` + `HideHelpSection` fails with `.notFound`. Valid Original moved rows, including the Chats class's declared multi-page ownership, remain supported. |

The narrow Core change is metadata-only: `perform`, public CAS, recovery/Keychain
writer helpers and the entire `ClientSettingsFile` implementation match the
read-time preimage. IDs are process-local, contain no values, are neither encoded
nor persisted, and are not used to alter CAS semantics. They retain no historical
definition/value tombstones.

### Public API/compiler surfaces

| Surface | Signature/contract change |
|---|---|
| `ClientSettingsSnapshot` | Adds `public let definitionVersions: [String: UUID]`; its initializer adds trailing `definitionVersions: [String: UUID] = [:]`. Existing reconstructed/CAS snapshots retain their call syntax. Unknown version keys are pruned. |
| `ClientSettingsSearchIndex.refresh` | Adds `definitionVersions: [String: UUID] = [:]` after `actions`. Store-backed callers pass `snapshot.definitionVersions`; the corresponding UUID participates in each definition fingerprint. |
| `ExteralessSettingsSearchProvider` | Adds `retire()`, `makeRoot(context:settings:) -> ViewController?` and `prepare(request:context:) -> ExteralessSettingsSearchOpen?`. Its shipping conformance is `ExteralessSettingsSearchSession`. |
| `ExteralessSettingsSearchEntry` | Adds `makeRoot(context:settings:)` and `prepare(url:context:)`. `install` retires a replaced provider, including replacement with nil. |
| `ExteralessSettingsSearchOpen` | New one-shot MainActor operation: `start(whenUnlocked:from:)`. Its captured session owns the bounded wait; it does not reacquire a provider. |
| `exteralessSettingsController` | Context-only and context+store overloads now return `ViewController?`; the explicit session overload remains optional. The default obtains its store from the installed scope; Runtime installs the shared production store, while the harness explicitly installs its given-store session. |
| `ExteralessSettingsEntry.setControllerFactory` | Factory closure becomes `@MainActor (AccountContext) -> ViewController?`. Runtime's existing closure composes directly; PeerInfo already unwraps the result. The two direct production callers, MainMenu and Player, now unwrap too. |

`TelegramUI` and the harness already declare SwiftSignalKit. AccountContext's
fingerprint group now includes `ExteralessSettingsEntry.swift`; TelegramUI's group
adds `Appearance/ExteralessMainMenu.swift`, and its existing Player glob includes
the changed Player caller. Core's existing `ClientSetting*.swift` glob covers the
metadata/index/routes. The UIKit fixture remains on the already-joined harness
source export. No new native target or dependency cycle is introduced.

### Bounded Core delta and native fixtures

The ready source cohort is
[settings-search-r1-r5-cohort.json](settings-search-r1-r5-cohort.json), with a
[pinned stager and commands](settings-search-r1-r5-cohort/README.md). It contains
nine actual production Swift sources and two test files: the coordinator's
unchanged **16** search fixtures plus **6** new closure fixtures, **22 total**.
The old archive remains its historical snapshot.

```sh
python3 -B docs/wave-2/settings-search-r1-r5-cohort/stage.py --output "$HOME/settings-search-closure-cohort"
```

In that newly staged directory, the supplied Linux executor commands are:

```sh
sha256sum -c SHA256SUMS
timeout --signal=TERM --kill-after=5s 120s swift build --build-tests --configuration debug --jobs 2
timeout --signal=TERM --kill-after=5s 30s swift test --skip-build --configuration debug --filter 'ClientSettingsSearch(Closure)?Tests'
```

`ClientSettingsSearchClosureTests.swift` covers actual-store title/visibility ABA
without an intermediate index refresh, unchanged tickets across public batches,
reloads and identical declarations, accepted schema publication despite a file
read failure, constructor compatibility/version-key pruning, the exact R5 URL
with a **registered target definition**, valid moved-row controls, and the rejected
credential-value canary. The registered R5 target prevents an unavailable/missing
provider from accidentally satisfying that counterexample.

The executable given-context native fixture is now awaited from
`ClientHarnessSession.finishSettingsSearchChecks` before the existing
secret-availability segment. `facts.settingsSearchClosure` is returned only after:

- The installed `ExteralessSettingsEntry` and **real context-only default factory**
  create a mounted Root for the given store. A real Root table selection opens the
  private numeric editor.
- Actual `ClientSettings.register(B)` / `register(A)` calls occur in one MainActor
  turn. Retained native tickets fail before queued refresh drains and remain
  invalid afterwards. An unrelated ticket and value-only edits remain stable.
  A retained UIKit Save target/action cannot persist a stale draft.
- A prepared URL waits on an owned signal. Retirement synchronously disposes that
  subscription exactly once. Three publication lifetimes reuse the **same given
  AccountContext object**; the old operation and an old not-yet-started operation
  perform **zero** parent lookups after replacement. No second account is created.
- A **new explicit** operation for the same copied URL uses the real nil-navigation
  main-window fallback, opens exactly one current text editor and leaves values
  and override presence intact.
- An unavailable selection returns **false** and displays its actual native
  error; that assertion was not replaced with a consumption result. A recognized
  invalid API-value URL displays only the typed local denial after its unlock
  signal, with no canary in its message.
- Retired default/store/explicit factories return nil. Retained Search, row menu,
  Reset/Enter-value accessibility actions and the private editor Save produce no
  new controller, alert or mutation. Back returns to the actual home stack.

This native fixture exercises the shipping prepared-operation/session/controller
code. **R1's AppDelegate launch/notification path is source-order checked here;
the harness does not pretend to instantiate a full AuthorizedApplicationContext.**
The coordinator's full-app check must observe the exact canary URL being consumed
by the existing readiness/unlock consumer before any intent-hook invocation,
both on launch and on notification open.

The added native closure cohort has six 650ms transitions (**3.9s**), three polls
bounded at 500ms each, and one 50ms queue-drain delay: at most **5.45s of explicit
waits**, plus work. The **13 Core probes**, **30-second whole-process ceiling** and
**3+3+2** recording groups are unchanged. Runtime timing remains unmeasured here.

### Expected frames, specified before execution

The earlier search/results/row-highlight criteria still apply. In the additional
closure segment, recorded light/dark frames should show:

1. The actual default Root and numeric editor. After schema ABA, the stale draft
   is replaced by the changed-route row, Save disappears and no success, reset or
   value-change UI appears. Persisted values retain their pre-fixture state.
2. The retired Root stays on its unavailable state while the **old** pending
   operation's unlock is released. No page, alert, keyboard or highlight appears
   from that operation. The fresh explicit copied-link open then performs exactly
   one normal navigation into the current text editor.
3. The unavailable-selection alert and, separately, the invalid-link alert have
   readable native chrome and the expected messages. The canary/query is never
   drawn. These alerts appear only in their live, unlocked operation.
4. Final retirement removes active editor actions; two normal Back transitions
   restore home with no orphan page, first responder or overlay. No clipping,
   theme flash or detached highlight is accepted.

Acceptance still requires recorded frame indices and **ffprobe PTS**. Property,
geometry, source and cohort-hash checks are not frame acceptance.

### Executed local checks and retained coordinator work

- **7/7 existing Python driver contracts PASS**, reported **0.074s**. These are
  host/source contracts, not native runtime tests.
- Source checks passed for the two actual AppDelegate ingress orders, exact
  preservation of the original ready/unlock consumer, captured pending lifetime
  and cancellation wiring, publication-lock/UUID plumbing, mandatory Root scope,
  R5 intersection, the current **22** test identities and cohort source hashes.
- Python/BUILD AST checks passed. Core file/CAS/Keychain writer bytes and
  AppDelegate bytes outside `openUrlWhenReady` match the read-time preimages.
- The coordinator's Reset update/clear/register integration and
  `other/resetSettings → general.settingsReset` alias are retained. The baseline
  search fixture still contains the exact localized-title mapper, its search-route
  control, and the Reset action assertion.
- The d7 four-label branch is byte-preserved. Secret-availability's only change is
  explicit owned-session construction/factory labeling; preparation, assertions,
  probe and subsequent segment bytes are retained.
- Concurrent ResetController and Manager/SDK BUILD edits were observed. Only the
  named MainMenu fingerprint input was authored in TelegramUI BUILD by this pass;
  its raw post-pin includes the other owners' read-time changes. The Manager group
  at pin capture hashes to
  `111098c451ba5987092c8c800bc6abedfa391e11495a8f65cbef4939a444f6b0`.

Supplied baseline evidence remains attributed to the coordinator: search16 on
Linux **43757030337 / 93edf05e**, and Reset17/704 Core on **43759513734 / 1880**.
It does not cover this new 22-test/source snapshot. **No local Swift/XCTest/UIKit,
CI query/run, commit, live account, network or foreign plugin operation was
performed.** ConfigManifest and the old archive/receipts were not rewritten.

### Exact applied raw post-pins

These are the **19 actual source/test files** at receipt capture, not an apply
plan. Full-byte pins include any named concurrent owner work present at that read.

| Path | SHA-256 |
|---|---|
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift` | `8677713c19c4ff623caf9437f4ff2613d8665a5f48b89e53a45b348873320701` |
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSearchIndex.swift` | `22aa851f9fc313d9f764dc607629defbf95a0083a6483944ff2178548ebf2047` |
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSourceRoutes.swift` | `117282d9bd93fa1321fa6b0511b2fa65c5286d5bf2cb415df110648ceaa0a1f9` |
| `swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsSearchClosureTests.swift` | `8d4e030909c3e1a3b558d9731389294c619d3e9c0ae493c255440bfb9e9eb583` |
| `telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsEntry.swift` | `0f8fe81f8782e53b4b222f692d30e6eef191c8ea37d893d8ed285218b1a7aa94` |
| `telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsSearchEntry.swift` | `574c0d16253f2643d94ba53a47c56f41f7d81c8fe7f9347752c7c2e5cb015c5d` |
| `telegram-ios/submodules/AccountContext/BUILD` | `f9fe32231403cd296a08a6306d58a38be00e66b4590ff66b4a702422e51d7c5a` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsSearch.swift` | `8e49e4d6b4c8a81df57129816700d4580755b8d979c0b0dd7289a62be87b0979` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift` | `a0b332369915c6817e039bda1ca6a4ce8f6c0f6962debb10dc97e55fd8d35bf5` |
| `telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift` | `2d77b0d4dee87086458057a2a99d50fa1da23ac247be5b93e1e7de2252edec62` |
| `telegram-ios/submodules/TelegramUI/Sources/OpenUrl.swift` | `384b70c842ad715d32b173d9286a9e9415244fe5ea3b95dcfd686dfaeff0ee5b` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessMainMenu.swift` | `14b415c48b46254a5c46e864c82683b2cb5cbaf2f7fb0b5238b408f1571ddedb` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerActions.swift` | `b9016ce5f3cb7147782cb1a4dc514045545409bfd5917c7f74a2e4e78c77d92f` |
| `telegram-ios/submodules/TelegramUI/BUILD` | `1c3f99addd73a0ec030e40e196c74780346ad80daaa6697f14f2da6cac81a9d9` |
| `telegram-ios/Tests/Exteraless/SettingsSearchUIViewRouteChecks.swift` | `be2b05c6c0723cbeb3ba7c594d834279cf8085d9d284db3a34449725d57e8ff2` |
| `telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessApplication.swift` | `925bf7a6db0ab073750166b62e85d1a1507b166a54244ca911a52db36a8d41f5` |
| `telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessSecretAvailability.swift` | `97edca499ab1855753c2a1e097c73d1b2df1ff1a1efd2416067375f8ee545c21` |
| `telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessSettingsSearch.swift` | `12f2c9ebd8bec3b11db578bdc9f9a07052641bd93dc88306087033a7cde671fe` |
| `telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift` | `3fd1e8de09e5c4825b86e9091b33b480d4045ddab8751b5277a21046fece23cd` |

Retained current Root Runtime pin:
`5041de7b3d2e5d0098ec61773eef3617a63984dd167b946e443e1c5242fd48e8`.
Retained coordinator Core16 test pin:
`6a2228317f0e4e4f0b8d5fcc3ff247f0277c6c70de4b32655a4c9021ef73eaf5`.
The source stager is pinned separately in the receipt; it does not execute Swift.

Final source staging verified all **15 output members**, repository source bytes
and `SHA256SUMS` for the **22-test** cohort, without Swift execution.

At **2026-11-15T21:21:45.711313Z**, the concurrently edited
`telegram-ios/submodules/TelegramUI/BUILD` had advanced to **49,810 bytes**, SHA-256
`8ea8d0e3ef2efe78f88c991f3dd7978e6fdb0c06e74facaace9faa8249dabd71`.
Its `ClientHarnessDomainFingerprintSources` block, including the single authored
MainMenu input, hashes to
`49becbc0da165095bcaa5322a58cb01b60bab55ffbda68a24396d8c68eb24470`.
The receipt records both read-time raw BUILD pins and this exact retained hunk
boundary; the other 18 applied source/test pins matched on the final check.
