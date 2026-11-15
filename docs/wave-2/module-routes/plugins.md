# module.plugins — source member routes

**666/666 original public method-body identities are the boundary of this receipt.**
The accompanying [`plugins.json`](plugins.json) retains `file`, `name`, exact
`parameter_types` and declaration `line` from
`docs/parity/client-features.json["modules"]["plugins"]["public_method_bodies"]`.
There are 69 pinned Java files, 58 with indexed bodies, 11 with none, and no
duplicate four-part identities. Constructors, private/package/protected methods
and interface declarations are not added to that denominator.

This is source-route authorship, dated 2026-11-15. Every member has
`verified: false` and `ported: false`. A native model field, renderer role or
lifecycle counterpart is identified as such; it does not expose an Android class
or prove the original Java method callable through virtualjava.

## Scope and evidence

- Original module aggregate: `996028156e1919e0e5cb8c0339dcdc23330b1e78b414bf4b78f692288dbff991`;
  all 69 raw-file hashes matched the inventory during this review.
- Inventory raw SHA-256: `ee82f6d3f53c1ff2ccc9785305b63553ea504abdb5274c11fa9148144d5fc240`.
- Identity SHA-256: `179676e572472dd1acaccb382378494ce56f73e861c02db1ce410b74efb519d2`.
  Algorithm: UTF-8 JSON of the ordered four-field identities, `sort_keys=True`,
  `ensure_ascii=False`, separators `(',', ':')`, without a trailing newline.
- The JSON pins the actual files used by its routes. Java bodies were read from
  the vendored originals, including same-named nested/anonymous UI methods.
  Unusual inventory parameter tokens are preserved, not repaired or re-parsed.
- Existing Host, BridgeServices, PluginUI, NativeServices, TelegramCore TL and SDK
  source were read. Historical reports are context: `sdk.md`, `sdk-wire.md`,
  `sdk-adapters-final.md`, `plugin-ui-remediation.md`,
  `reviews/host-native-source-closure.md`, `final-app-composition.md`.
- Coordinator-provided later evidence is **C219 / three SDK children green,
  43738810843 / 136 verified**, Core/Ghost `1af670`, 363 pytest and Config
  **276/0/32**, with 744 finite Config aliases. These are supplied receipts, not
  tests rerun here, and do not verify these 666 member contracts or full UIKit,
  network delivery or Android class importability. HNS/TBF/SDK/TL source closures
  remain their owners' receipts. No CI/build status was queried.
- The separate 925-symbol SDK index is outside this denominator. `member_routes`
  uses original Java API identities only; no SDK symbol is claimed merely because
  a module imports. Config aliases and TL schema aliases are finite data mappings.

## Dispositions

`source-routed` means an actual portable operation is connected in the inspected
source. `member-body` means a value/helper counterpart. `platform-lifecycle` and
`platform-renderer` identify native ownership/rendering roles. `partial` retains
the precise missing portable operation or semantic difference. `unsupported`
is limited to the specified Android/JVM/Xposed/DEX mechanism. None is a parity pass.

The ledger below is explicit authoring input, not a heuristic class-name join.
Each row identifies its original declaration and has its own body semantics and
limits. Shared anchor keys expand to full `path/symbol/line/role` records in JSON.
Each of the 666 `member_routes` is keyed by
`file::name(parameter_types joined with comma)@line`; the structured `original`
remains authoritative where a parameter token itself contains a comma.
The own-plugin `getPluginSettingsJson` facade serializes locally; its native
`PluginHost.settingsJSON` evidence is expressly marked `counterpart_only: true`.

## Focused counterexamples

1. **P2 — direct hook facade registration is inert.**
   `PythonBridge.java:64–76` delegates registration/removal to the controller;
   `PluginsController.java:1698–1799` mutates its ledgers. Current
   `python/exteraless_runtime/_platform.py:177–187` only checks ownership.
   `__init__.py:250–254,267–270,328–329` consults BasePlugin's ledger instead.
   Source repro: on a configured loaded worker, call the public Java facade's
   `addRequestHook(id, name, false, priority)` without `BasePlugin.add_hook`;
   `_exteraless_request_hooks` is unchanged, so no matching dispatch is admitted.
   Calling its remove method after a BasePlugin registration also leaves that
   registration intact. The normal BasePlugin path remains a separate valid route.

2. **P2 — manager Custom settings path lacks portable-widget materialization.**
   Android `PythonPluginsEngine.java:464–519` builds custom content and dispatches
   factory clicks; `PluginSettingsActivity.java:811+` consumes it. Current native
   `PluginSettingsModel.swift:89–98` has no custom kind and
   `PluginSettingsController.swift:346–349` renders unknown kinds as unsupported.
   Source repro: return `ui.settings.Custom(view=TextView(...))` from
   `create_settings`, then open the native manager's settings row at
   `PluginManagerController.swift:363–373`. Runtime's read at
   `ExteralessPluginRuntime.swift:404–437` does not run
   `_ui.py:510–516`, whereas the separate SDK `show_settings` path does. A working
   SDK presenter therefore does not close the manager path.

3. **P2 — original target-setting links lack a resolver.**
   `PluginsController.java:1265–1319` generates/parses `p`/`s` links and opens a
   target setting. `_facades.py:53–56` rejects every non-null `target` with the
   explicit native-pagePath error. `PluginSettingsModel.swift:172–180` traverses
   row identifiers, not original link aliases. Source repro: call
   `PluginsController.getInstance().openPluginSettings(ownId, "known_alias")`;
   the rejection precedes presentation. Native explicit page paths are available,
   but are not the original alias/link operation.

4. **P2 — trust-level cap is absent from the native grant model.**
   `PluginTrustLevel.java:93–112` persists ISOLATED/GATED/TRUSTED and removes
   forbidden grants; `PluginPermissions.java:228–240` caps effective grants.
   `PluginModel.swift:277–284` only unions stored grants with UI; native manager
   `PluginManagerController.swift:330–349` edits grants without a trust level.
   Source repro with unsafe mode off: the original ISOLATED-plus-stored-network state returns only UI,
   while a native PermissionsModel with the same stored network grant returns
   network plus UI. No native trust-level state/migration operation was found.
   This is a grant-model parity gap, not a claim of executing foreign code.

## Remaining semantic gaps

- Java manager facade coverage is smaller than native manager coverage: snapshots,
  rescan, reload metadata, install overload flags, direct hooks and several typed
  settings calls have no exact Java route. Own-plugin facade access is not a
  cross-plugin manager registry.
- Capability scan data exists in the stock SDK, but manager scan-cache persistence,
  obfuscation/DEX consent evidence, denial-notice queues, merged audit journal UI,
  signed SharedPreferences and three trust levels are not supplied by log buffers
  or plain native grants.
- Android plugin-source ZIP backup/import is not the data-only Tools backup.
  Rotating disk logs/export/clear, message-tap plugin installation, plugin sticker
  icons, standalone source viewer, list/log search and setting masks/alias targets
  retain operation-specific limits below.
- Native scheduling uses captured interpreter workers; it cannot preserve execution
  of arbitrary Python on Android main/DispatchQueue threads. Native watchdogs use
  dispatch deadlines/abandonment and process-footprint estimates, not Java main-thread
  budget accounting or Java exception attribution.
- Native menus use five placements and a bounded context-expression grammar;
  arbitrary MVEL, Java object context, Android drawables and widgets are not implied.
  TL uses explicit schema values/account namespaces and real native request/enqueue
  providers; submission is not server delivery, and Android object overloads and
  unsupported edit targets remain limited.
- Xposed method/constructor hooks, ART deoptimization, allocation without Java
  constructors, DEX proxy generation, Android Canvas/accessibility-super calls and
  overlay-window permission prompts have explicit unsupported scopes. Scalar
  boxing helpers are separately documented as data operations.

<details>
<summary>Source anchors, admission contracts and all 666 authored member rows</summary>

## Shared source files

<!-- files:begin -->
| Key | Repository path |
| --- | --- |
| PM | swift/PluginHost/Sources/PluginHost/PluginModel.swift |
| PH | swift/PluginHost/Sources/PluginHost/PluginHost.swift |
| BS | swift/PluginHost/Sources/PluginHost/BridgeServices.swift |
| ST | swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift |
| EP | swift/PluginHost/Sources/PluginHost/ExtensionPoints.swift |
| RP | swift/PluginHost/Sources/PluginHost/PluginRuntimeProtocol.swift |
| WD | swift/PluginHost/Sources/PluginHost/PluginWatchdog.swift |
| SI | swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift |
| OB | swift/PluginHost/Sources/PluginHost/NativeServiceOpenBarrier.swift |
| IM | swift/PluginHost/Sources/PluginHost/NativeServiceInterceptionModels.swift |
| RT | telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift |
| MC | telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginManagerController.swift |
| SC | telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift |
| SM | telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsModel.swift |
| UH | telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginUIHelpers.swift |
| UB | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift |
| UM | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIMenuModel.swift |
| MN | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIMenus.swift |
| UV | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIModel.swift |
| UR | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIResources.swift |
| WC | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIWidgetContainer.swift |
| CF | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift |
| RC | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginRuntimeRecovery.swift |
| NS | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift |
| OH | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/NativeServiceOpenHooks.swift |
| TB | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift |
| TT | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLTransformIntegration.swift |
| TE | telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLMediaEditServices.swift |
| TN | telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift |
| TS | telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNativeServices.swift |
| AI | telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIPluginReviewController.swift |
| AT | swift/ExteralessCore/Sources/ExteralessCore/AIPluginReview.swift |
| PY | python/exteraless_runtime/__init__.py |
| PF | python/exteraless_runtime/_facades.py |
| PP | python/exteraless_runtime/_platform.py |
| PS | python/exteraless_runtime/_settings.py |
| PR | python/exteraless_runtime/_registrations.py |
| PQ | python/exteraless_runtime/_scheduling.py |
| PU | python/exteraless_runtime/_ui.py |
| PT | python/exteraless_runtime/_tl.py |
| SL | python/sdk/extera_utils/plugin_loader.py |
| SS | python/sdk/ui/settings.py |
| CA | python/sdk/extera_utils/class_aliases.py |
| CS | python/sdk/extera_utils/capability_scan.py |
| AG | python/sdk/extera_utils/audit_gate.py |
| AR | python/virtualjava/arrays.py |
| VF | python/virtualjava/finder.py |
<!-- files:end -->

## Admission/lifecycle contracts

<!-- lifecycles:begin -->
| Key | Contract |
| --- | --- |
| value | Value/model mapping only. No native effect, Java method export or mutable shared-registry capability follows from this anchor. |
| sdk | Interpreter-local SDK data/function. Installed adapters and owner context govern execution; this is not by itself a native provider operation. |
| storage | Bridge requests validate the C-supplied plugin identity and immutable owner token. Settings/directory operations use PluginServiceStorage ID/key validation and locked atomic per-plugin JSON. Bulk JSON is opaque text; literal reserved keys remain data. |
| bridge-read | BridgeServices validates C-supplied identity/owner and the named query arguments, then reads PermissionsModel. The strict SDK Bool query fails closed on a malformed or unavailable native result; it allocates no presentation or callback lease. |
| logging | C supplies the log owner. The native bounded log buffer validates level/message/traceback data as applicable and appends a record. Logging creates no settings transaction or callback lease; Android rotating-file output is outside this route. |
| owner-work | The native scheduler captures the immutable interpreter owner before asynchronous hops and reserves callback ownership before publication. Work runs on that owner's mailbox; original SDK account context is carried by its wrapper. Cancellation/terminal delivery retain FIFO cleanup ownership. Named postToOwner delay is bounded to 0..86400000 ms; legacy runOnUIThread has its own nonnegative Int32 validation. |
| host | Runtime/PluginHost owns lifecycle admission, maintenance exclusion and captured interpreter handles. Native storage/manager work stays native; operations invoking Python use its captured interpreter mailbox. Native manager actions await their actual result. This does not export arbitrary manager methods to plugins. |
| settings | Native-manager reads/actions capture owner, actual Int32 account slot and revocable page/read/action permit before Task/queue hops; Host checks them on the worker. Direct SDK serialization uses its already owned worker, not a newly acquired UI action permit. Schema refresh replaces callback ledgers; current callback failure rereads storage, stale/cancelled UI work does not. |
| ui | C worker validates owner/UI permission and captures parent execution before main/readback hops. Native admission rechecks owner/account/revision; retained effects keep budget until actual drain. Presentation visibility is native; callback-producing leases deliver closed before captured-owner FIFO release. Refresh/readback need no invented user callback. |
| cleanup | Revoke only a stored resource belonging to the immutable plugin/owner token. Cleanup during retiring unload is allowed; a destroyed/stale owner fails at Host. Duplicate terminal cleanup is idempotent; no replacement-owner lookup or new effect is admitted. |
| native | NativeServices bridge requests validate operation/model and immutable owner, with operation-specific grants and account scope. Callback-producing operations reserve bounded leases before async work; interception queries inspect existing stored registrations. Actual callback execution rechecks control, terminal delivery precedes FIFO retirement, and cancellation has an explicit winner. |
| menu | Menu registration/replacement commits under the native lease-store lock with captured owner/account/execution. Gesture delivery rechecks source controller, context, revision and owner; five native placements and the bounded condition grammar are authoritative. |
| tl | TL provider captures C owner, actual account, grants and parent execution guard before main/network work. Schema/peer namespaces, source-file access, recursion and commit permits are revalidated. Response/error is terminal and released in owner FIFO; enqueue is not upload/server delivery. |
| transform | Host awaiting event queue captures interpreter generations and account. SDK exact/substr priority ledger selects callbacks; native schema normalizes each replacement, preserves prior valid input on failure and enforces cancel/final semantics before request/update application. |
| renderer | MainActor native rendering projects a validated snapshot. Table/gesture/layout methods are counterpart roles, not Android View/Canvas implementations. Settings actions additionally require the captured settings permit. No recorded-frame equivalence is claimed. |
| ai | Native AI review reads only the selected bounded source snapshot, checks cancellation/account lifetime, and uses the configured provider plus source-revision cache. Read/decode tools never execute the plugin. |
<!-- lifecycles:end -->

## Resolved source anchors

<!-- anchors:begin -->
| Key | File | Line | Symbol | Role | Operation | Owner | Lifecycle |
| --- | --- | --- | --- | --- | --- | --- | --- |
| alias | CA | 139 | resolve | value-helper | resolve exact/prefix name with nested suffix | SDK | sdk |
| strategy | EP | 219 | HookStrategy | enum-model | DEFAULT/CANCEL/MODIFY/MODIFY_FINAL values | PluginHost | value |
| replacement | RP | 87 | PluginRuntimeScript.applyingSendResult | result-normalizer | validate and merge send replacement | PluginHost | transform |
| json-string | UV | 72 | PluginUIJSON.string | value-accessor | optional typed string projection | PluginUI | value |
| placement | UM | 3 | PluginUIMenuPlacement | enum-model | five menu placement values | PluginUI | value |
| p.id | PM | 6 | Plugin.id | model-field | plugin identity | PluginHost | value |
| p.name | PM | 7 | Plugin.name | model-field | optional plugin name | PluginHost | value |
| p.description | PM | 8 | Plugin.description | model-field | optional description | PluginHost | value |
| p.author | PM | 9 | Plugin.author | model-field | optional author | PluginHost | value |
| p.version | PM | 11 | Plugin.version | model-field | version string | PluginHost | value |
| p.icon | PM | 13 | Plugin.icon | model-field | icon pack/index metadata | PluginHost | value |
| p.engine | PM | 15 | Plugin.engine | model-field | engine metadata | PluginHost | value |
| p.app | PM | 16 | Plugin.appVersion | model-field | app version constraint metadata | PluginHost | value |
| p.sdk | PM | 17 | Plugin.sdkVersion | model-field | SDK version constraint metadata | PluginHost | value |
| p.requirements | PM | 20 | Plugin.requirements | model-field | Python requirements list | PluginHost | value |
| p.enabled | PM | 30 | Plugin.enabled | model-field | persisted enable preference | PluginHost | value |
| p.error | PM | 38 | Plugin.loadError | model-field | transient load error | PluginHost | value |
| p.frozen | PM | 42 | Plugin.notResponding | model-field | watchdog nonresponse flag | PluginHost | value |
| p.active | PM | 139 | Plugin.isEnabled | computed-model | enabled and no loadError | PluginHost | value |
| p.title | PM | 141 | Plugin.displayName | computed-model | name or id | PluginHost | value |
| p.subtitle | PM | 143 | Plugin.subtitle | computed-model | version/author/error subtitle | PluginHost | value |
| p.pack | PM | 150 | Plugin.iconPack | computed-model | prefix before first slash | PluginHost | value |
| p.index | PM | 156 | Plugin.iconIndex | computed-model | numeric suffix or zero | PluginHost | value |
| audit-record | AG | 244 | _record | SDK-audit-counterpart | record Python audit event | SDK | sdk |
| audit-list | AG | 285 | get_journal | SDK-audit-counterpart | bounded Python audit journal | SDK | sdk |
| audit-profile | AG | 292 | get_profile | SDK-audit-counterpart | Python category counts | SDK | sdk |
| audit-clear | AG | 305 | clear_plugin | SDK-audit-counterpart | clear own audit data | SDK | sdk |
| scan | SL | 3600 | scan_capabilities_json | SDK-source-analysis | static capability scan JSON | SDK | sdk |
| obfuscation | CS | 339 | _detect_obfuscation | SDK-source-analysis | collect obfuscation evidence | SDK | sdk |
| dex-info | CS | 229 | _scan_embedded_dex | SDK-source-analysis | inspect embedded DEX data | SDK | sdk |
| log | ST | 267 | PluginServiceLogBuffer.append | native-log-provider | append bounded log entry | BridgeServices | logging |
| logs | ST | 291 | PluginServiceLogBuffer.entries | native-log-provider | snapshot plugin log entries | BridgeServices | logging |
| log-event | NS | 144 | PluginNativeServicesBridgeExtension.dispatch | native-operation | logEvent | NativeServices | logging |
| perm-kind | PM | 174 | PluginPermission | enum-model | known permission names | PluginHost | value |
| perm-danger | PM | 198 | PluginPermission.isDangerous | computed-model | hooks/native danger classification | PluginHost | value |
| perm-description | PM | 201 | PluginPermission.describe | computed-model | permission description | PluginHost | value |
| perm-sanitize | PM | 314 | PluginPermission.sanitize(rawKeys:) | value-helper | filter/deduplicate in declared order | PluginHost | value |
| grants-read | PM | 364 | PluginStore.loadGrants | native-storage-counterpart | load typed grant arrays | PluginHost | host |
| grants-write | PM | 250 | PermissionsModel.setGranted | native-storage-counterpart | sanitize/persist grants | PluginHost | host |
| grants-clear | PM | 259 | PermissionsModel.clear | native-storage-counterpart | remove grant record | PluginHost | host |
| effective | PM | 277 | PermissionsModel.effective | permission-counterpart | stored grants plus implicit UI | PluginHost | host |
| requested | PM | 287 | PermissionsModel.requested | permission-counterpart | declared requestable grants | PluginHost | value |
| permission | BS | 486 | BridgeServices.callRuntime | native-operation | hasPermission | BridgeServices | bridge-read |
| unsafe | BS | 494 | BridgeServices.callRuntime | native-operation | isUnsafeMode | BridgeServices | bridge-read |
| check-permission | PM | 300 | PermissionsModel.check | permission-counterpart | permission decision and diagnostic | PluginHost | host |
| owner | PH | 1142 | PluginHost.callbackOwner | owner-capability | capture current interpreter owner | PluginHost | host |
| mark | PP | 74 | Platform.mark | interpreter-context | enter/restore own SDK context | SDK | sdk |
| host-start | PH | 622 | PluginHost.start | native-lifecycle | start native runtime and stored plugins | PluginHost | host |
| host-stop | PH | 699 | PluginHost.stop | native-lifecycle | stop Host and drain/retire workers | PluginHost | host |
| runtime-start | RT | 107 | ExteralessPluginRuntime.start | application-lifecycle | account-gated composed startup | PluginHost | host |
| runtime-snapshot | RT | 360 | ExteralessPluginRuntime.snapshot | manager-provider | native plugin snapshot | PluginHost | host |
| host-list | PH | 1045 | PluginHost.pluginList | manager-provider | synchronized plugin list | PluginHost | host |
| metadata | PH | 920 | PluginHost.readPluginMetadata | manager-provider | isolated AST metadata inspection | PluginHost | host |
| import | PH | 947 | PluginHost.importPlugin | manager-provider | inspect/copy/install source | PluginHost | host |
| install | PH | 956 | PluginHost.installPlugin | manager-provider | install validated metadata/source | PluginHost | host |
| remove | PH | 997 | PluginHost.uninstallPlugin | manager-provider | unload/remove source/model/grants | PluginHost | host |
| enabled | PH | 1013 | PluginHost.setPluginEnabled | manager-provider | persist enabled flag and load/unload | PluginHost | host |
| reload | PH | 1032 | PluginHost.reloadPlugin | manager-provider | unload/reload existing stored model | PluginHost | host |
| settings-read | PH | 1069 | PluginHost.settingsJSON | native-settings-provider | captured-owner create_settings read | PluginHost | settings |
| settings-change | PH | 1095 | PluginHost.updateSetting | native-settings-provider | validate/persist setting and callback | PluginHost | settings |
| settings-click | PH | 1107 | PluginHost.clickSetting | native-settings-provider | invoke owned callback ID | PluginHost | settings |
| set-grants | PH | 1051 | PluginHost.setGrantedPermissions | manager-provider | update installed plugin grants | PluginHost | host |
| settings-get | BS | 525 | BridgeServices.callRuntime | native-operation | getSettings | BridgeServices | storage |
| settings-write | BS | 530 | BridgeServices.callRuntime | native-operation | setSettings/updateSettings | BridgeServices | storage |
| settings-clear | BS | 536 | BridgeServices.callRuntime | native-operation | clearSettings | BridgeServices | storage |
| directory | BS | 540 | BridgeServices.callRuntime | native-operation | getPluginsDir/getFilesDir/getCacheDir | BridgeServices | storage |
| refresh | UB | 273 | PluginUIBridgeExtension.call | native-operation | uiRefreshSettings | PluginUI | ui |
| present | UB | 158 | PluginUIBridgeExtension.call | native-operation | uiPresent | PluginUI | ui |
| update-ui | UB | 172 | PluginUIBridgeExtension.call | native-operation | uiUpdate | PluginUI | ui |
| navigate | UB | 249 | PluginUIBridgeExtension.call | native-operation | uiNavigate | PluginUI | ui |
| ui-cleanup | UB | 321 | PluginUIBridgeExtension.cleanup | revoke-only-provider | uiDismiss/menuRemove | PluginUI | cleanup |
| ui-release | UB | 89 | PluginUIBridgeExtension.releaseInstances | native-retirement | retire plugin UI leases | PluginUI | cleanup |
| menu-register | UB | 214 | PluginUIBridgeExtension.call | native-operation | menuRegister | PluginUI | menu |
| menu-list | MN | 66 | PluginUIBridgeExtension.matchingMenus | native-menu-provider | placement/condition matching | PluginUI | menu |
| menu-action | MN | 79 | PluginUIBridgeExtension.invokeMenu | native-menu-provider | owned menu callback | PluginUI | menu |
| menu-context | MN | 97 | pluginUIMenuContext | native-model-producer | actual account/peer/message context | PluginUI | menu |
| menu-render | MN | 11 | PluginUIBridgeExtension.menuItems | native-renderer | context menu items | PluginUI | menu |
| menu-rows | MN | 49 | PluginUIBridgeExtension.menuRows | native-renderer | grouped main/drawer rows | PluginUI | menu |
| menu-condition | UM | 126 | PluginUIMenuCondition.matches | condition-evaluator | bounded read-only context expression | PluginUI | value |
| menu-notify | UB | 421 | PluginUIBridgeExtension.notifyMenuChanges | native-lifecycle | coalesced menu registry notification | PluginUI | menu |
| image | UR | 7 | PluginUIResources.image | native-resource | resolve bundle image/SF Symbol | PluginUI | renderer |
| schedule | NS | 149 | PluginNativeServicesBridgeExtension.dispatch | native-operation | postToOwner | NativeServices | owner-work |
| ui-schedule | BS | 651 | BridgeServices.scheduleCallback | native-operation | runOnUIThread owner-worker callback | BridgeServices | owner-work |
| file-register | NS | 160 | PluginNativeServicesBridgeExtension.dispatch | native-operation | fileRegister | NativeServices | native |
| intent-register | NS | 160 | PluginNativeServicesBridgeExtension.dispatch | native-operation | intentRegister | NativeServices | native |
| native-cleanup | NS | 134 | PluginNativeServicesBridgeExtension.dispatch | revoke-only-provider | fileRemove/intentRemove/cancelOwnerTask | NativeServices | cleanup |
| native-release | NS | 122 | PluginNativeServicesBridgeExtension.releaseInstances | native-retirement | retire scheduler/interception/subscription leases | NativeServices | cleanup |
| file-match | OB | 186 | NativeServiceInterceptions.canInterceptFile | native-interception | matching live file registration | NativeServices | native |
| file-open | OH | 52 | NativeServiceOpenHooks.interceptFile | native-open-site | chat document interception | NativeServices | native |
| intent-open | OH | 33 | NativeServiceOpenHooks.interceptURL | native-open-site | external/application URL interception | NativeServices | native |
| file-dispatch | OB | 272 | NativeServiceInterceptions.interceptFile | native-barrier | invoke matched file handler | NativeServices | native |
| intent-dispatch | OB | 283 | NativeServiceInterceptions.interceptIntent | native-barrier | ordered before/result/after URL barrier | NativeServices | native |
| intent-after | OB | 160 | NativeServiceInterceptions.IntentAfter.completeOriginal | native-barrier | after callbacks following native original | NativeServices | native |
| file-context | IM | 46 | NativeServiceFileOpenContext.init | native-model-producer | file path/name/account DTO | NativeServices | value |
| intent-context | IM | 74 | NativeServiceIntentContext.init | native-model-producer | URL ACTION_VIEW context DTO | NativeServices | value |
| file-icons | IM | 17 | NativeServiceFileRegistration.init | unsupported-boundary | reject Android file icon factory | NativeServices | native |
| tl-request | TB | 154 | PluginTLBridgeExtension.dispatch | native-operation | tlRequest | TL | tl |
| tl-edit | TB | 181 | PluginTLBridgeExtension.dispatch | native-operation | editMedia | TL | tl |
| edit-native | TE | 72 | exteralessTLEditMedia | actual-native-effect | cached cloud/scheduled media edit | TL/TelegramCore | tl |
| media-model | TE | 32 | tlStoredMediaReference | actual-native-model | local resource/filename/MIME media reference | TL/TelegramCore | tl |
| tl-transform | TT | 32 | PluginTLTransformIntegration.init | native-transform-provider | Host transformTL | TL | transform |
| network-transform | TN | 14 | exteralessTransformedRequest | actual-native-request-site | ordered request transform before submit | TL/TelegramCore | transform |
| send-hook | EP | 386 | PluginEventBus.preSendMessageResult | native-extension-point | outgoing send decision and replacement | PluginHost | transform |
| subscriptions | EP | 95 | SubscriberGate.hasSubscribers | native-gate | typed subscription presence | PluginHost | host |
| app-event | PH | 1060 | PluginHost.deliverAppEvent | native-extension-point | ordered app event delivery | PluginHost | host |
| host-load | PH | 1251 | PluginHost.loadPlugin | native-lifecycle | create/bind/load owned interpreter | PluginHost | host |
| host-unload | PH | 1323 | PluginHost.unloadPlugin | native-lifecycle | retiring SDK unload then worker cleanup | PluginHost | cleanup |
| worker | SI | 409 | SubinterpreterManager.invoke | native-worker | invoke on captured interpreter mailbox | PluginHost | host |
| watchdog-start | WD | 138 | PluginWatchdog.start | native-lifecycle | watchdog footprint/observer startup | PluginHost | host |
| watchdog-stop | WD | 160 | PluginWatchdog.stop | native-lifecycle | cancel watchdog and clear markers | PluginHost | host |
| watchdog-risk | WD | 236 | PluginWatchdog.noteRiskyOperation | native-lifecycle | generation-bound crash marker | PluginHost | host |
| watchdog-exit | WD | 253 | PluginWatchdog.scheduleMarkerClear | native-lifecycle | clear matching completed risky marker | PluginHost | host |
| watchdog-background | WD | 321 | PluginWatchdog.noteAppBackgrounded | native-lifecycle | clear background crash marker | PluginHost | host |
| watchdog-healthy | WD | 314 | PluginWatchdog.noteHealthy | native-lifecycle | reset crash strikes | PluginHost | host |
| watchdog-frozen | WD | 188 | PluginWatchdog.isNotResponding | native-state | nonresponding interpreter state | PluginHost | host |
| watchdog-recover | WD | 292 | PluginWatchdog.recoverAfterCrash | native-lifecycle | second-strike attributed disable decision | PluginHost | host |
| watchdog-error | WD | 206 | PluginWatchdog.handlePluginError | native-diagnostic | report plugin execution error | PluginHost | host |
| recovery-start | RC | 52 | PluginRuntimeRecovery.beginStart | native-lifecycle | early-unclean-start recovery journal | PluginHost | host |
| recovery-healthy | RC | 92 | PluginRuntimeRecovery.markHealthy | native-lifecycle | clear early-start marker/count | PluginHost | host |
| recovery-notice | RC | 108 | PluginRuntimeRecovery.acknowledgeNotice | native-lifecycle | explicit recovery notice acknowledgement | PluginHost | host |
| controls | RT | 611 | ExteralessPluginRuntime.managerControls | manager-provider | engine/safe/developer/compact/pin/mute controls | PluginHost | host |
| config-read | CF | 68 | PluginConfigBridgeExtension.dispatch | native-operation | getPluginConfig | PluginUI/PluginHost | host |
| config-write | CF | 101 | PluginConfigBridgeExtension.dispatch | native-operation | setPluginConfig bounded queued admission | PluginUI/PluginHost | host |
| config-art | CF | 63 | PluginConfigBridgeExtension.dispatch | unsupported-boundary | reject compatibilityMode ART Profile Saver | PluginUI/PluginHost | host |
| mode | RT | 820 | ExteralessPluginRuntime.setRuntimeMode | manager-provider | nonterminal engine/safe maintenance transition | PluginHost | host |
| runtime-change | RT | 589 | ExteralessPluginRuntime.changed | native-lifecycle | prune callbacks/schemas and notify observers | PluginHost | host |
| facade-own | PF | 35 | Controller.getPlugin | SDK-facade | own loaded BasePlugin instance | SDK | sdk |
| facade-list-gap | PF | 38 | Controller.getPlugins | explicit-unavailable | reject cross-plugin registry | SDK | sdk |
| facade-open | PF | 53 | Controller.openPluginSettings | SDK-facade | own root settings; reject target alias | SDK | sdk |
| settings-export | PS | 41 | export_raw | SDK-adapter | preserve JSON-string setting export envelope | SDK | storage |
| settings-import | PS | 44 | import_raw | SDK-adapter | decode and merge setting values | SDK | storage |
| settings-replace | PS | 48 | replace_raw | SDK-adapter | decode and replace setting values | SDK | storage |
| hook-facade | PP | 177 | Platform.addRequestHook | explicit-partial | ownership-only direct hook facade | SDK | sdk |
| hook-ledger | PY | 241 | _matching_priorities | SDK-ledger | exact/substr/group priority matching | SDK | transform |
| dispatch | PY | 273 | dispatch_json | SDK-dispatch | owned SDK hook protocol dispatch | SDK | transform |
| py-cleanup | PY | 137 | _cleanup | SDK-retirement | clear record callbacks/leases/mirrors | SDK | cleanup |
| py-instance | SL | 2928 | get_plugin_instance | SDK-model | loaded per-interpreter plugin instance | SDK | sdk |
| py-settings | SL | 3420 | get_settings_json | SDK-schema-producer | create_settings serialization and callback ledger | SDK | settings |
| py-mirror | SL | 3503 | invalidate_settings_mirror | SDK-cache | invalidate BasePlugin and module settings mirrors | SDK | sdk |
| py-custom | SL | 3532 | _build_custom_view | SDK-factory | build explicit view/item/factory content | SDK | sdk |
| ui-custom | PU | 498 | show_settings | SDK-native-adapter | materialize portable custom widget and present settings | SDK/PluginUI | ui |
| factory | PU | 582 | PluginItemFactory | SDK-data-factory | create ui.settings.Custom descriptor | SDK | sdk |
| scalar | AR | 30 | PRIMITIVES | scalar-model | explicit primitive converters/descriptors | SDK | value |
| settings-kind | SM | 101 | PluginSetting.type | model-field | setting kind discriminator | PluginUI | value |
| settings-key | SM | 103 | PluginSetting.key | model-field | persisted setting key | PluginUI | value |
| settings-text | SM | 104 | PluginSetting.text | model-field | row/header/divider text | PluginUI | value |
| settings-subtext | SM | 105 | PluginSetting.subtext | model-field | row explanatory text | PluginUI | value |
| settings-hint | SM | 106 | PluginSetting.hint | model-field | input hint | PluginUI | value |
| settings-default | SM | 108 | PluginSetting.defaultValue | model-field | typed default value | PluginUI | value |
| settings-items | SM | 109 | PluginSetting.items | model-field | selector options | PluginUI | value |
| settings-accent | SM | 113 | PluginSetting.accent | model-field | accent row style | PluginUI | value |
| settings-red | SM | 114 | PluginSetting.red | model-field | destructive row style | PluginUI | value |
| settings-multiline | SM | 115 | PluginSetting.multiline | model-field | multiline input flag | PluginUI | value |
| settings-length | SM | 116 | PluginSetting.maxLength | model-field | input maximum length | PluginUI | value |
| settings-callback | SM | 117 | PluginSetting.callbackId | model-field | opaque action callback ID | PluginUI | value |
| settings-long | SM | 118 | PluginSetting.longCallbackId | model-field | opaque long-action callback ID | PluginUI | value |
| settings-subpage | SM | 119 | PluginSetting.subPage | model-field | nested native setting rows | PluginUI | value |
| custom-model | SS | 85 | Custom | SDK-model | custom view/factory/callback descriptor | SDK | value |
| factory-model | SS | 126 | SimpleSettingFactory | SDK-model | create/bind/clickability factory descriptor | SDK | value |
| settings-render | SC | 228 | PluginSettingsController.render | native-renderer | validated settings sections/rows | PluginUI | renderer |
| settings-row | SC | 288 | PluginSettingsController.makeRow | native-renderer | typed controls and callback actions | PluginUI | renderer |
| settings-custom-gap | SC | 346 | PluginSettingsController.makeRow | explicit-partial | unsupported unknown/custom manager row | PluginUI | renderer |
| settings-page | SC | 419 | PluginSettingsController.openSubpage | native-navigation | owner-scoped identifier page path | PluginUI | settings |
| settings-refresh | SC | 174 | PluginSettingsController.refresh | native-lifecycle | captured-read settings refresh | PluginUI | settings |
| settings-init | SC | 122 | PluginSettingsController.init | native-lifecycle | bind settings observations and scope | PluginUI | settings |
| settings-deinit | SC | 150 | PluginSettingsController.deinit | native-lifecycle | close action scope/remove observer | PluginUI | cleanup |
| settings-appearance | SC | 159 | PluginSettingsController.viewWillAppear | native-lifecycle | begin permitted initial read lifetime | PluginUI | settings |
| settings-update | SC | 370 | PluginSettingsController.update | native-settings-action | captured key/value mutation | PluginUI | settings |
| settings-action | SC | 391 | PluginSettingsController.click | native-settings-action | captured callback/subpage mutation | PluginUI | settings |
| settings-decode | SM | 163 | PluginSettingsDocument.decode | native-schema | bounded typed settings decoding | PluginUI | value |
| list-create | UH | 132 | PluginListController.loadDisplayNode | native-renderer | construct grouped native table | PluginUI | renderer |
| list-layout | UH | 181 | PluginListController.containerLayoutUpdated | native-layout | safe/input/navigation insets | PluginUI | renderer |
| list-sections | UH | 213 | PluginListController.setSections | native-renderer | reload rows and preserve input focus | PluginUI | renderer |
| list-action | UH | 339 | PluginListController.tableView(didSelectRowAt:) | native-gesture | invoke enabled row action | PluginUI | renderer |
| cell | UH | 521 | PluginListCell.configure | native-renderer | bind labels/style/toggle/slider/input | PluginUI | renderer |
| cell-accessibility | UH | 607 | PluginListCell.configureAccessibility | native-accessibility | VoiceOver roles/actions for native rows | PluginUI | renderer |
| cell-switch | UH | 644 | PluginListCell.switchChanged | native-gesture | request toggle; retain confirmed display | PluginUI | renderer |
| slider-preview | UH | 652 | PluginListCell.sliderChanged | native-gesture | preview normalized slider label | PluginUI | renderer |
| slider-commit | UH | 662 | PluginListCell.sliderCommitted | native-gesture | commit changed normalized slider value | PluginUI | settings |
| slider-range | SM | 64 | PluginSliderRange.normalize | value-helper | clamp and quantize slider value | PluginUI | value |
| long-press | UH | 675 | PluginListCell.longPressed | native-gesture | enabled row long action | PluginUI | renderer |
| widget | UV | 285 | PluginUIWidget.parse | native-model | validate portable widget DTO | PluginUI | value |
| widget-container | WC | 35 | PluginUIWidgetContainer.constrain | native-layout | constrain native widget container | PluginUI | renderer |
| manager-list | MC | 186 | PluginManagerController.renderList | native-renderer | installed plugin rows and empty state | PluginUI | renderer |
| manager-plugin | MC | 261 | PluginManagerController.renderPlugin | native-renderer | detail/settings/permission actions | PluginUI | renderer |
| manager-logs | MC | 386 | PluginManagerController.renderLogs | native-renderer | last 100 native log entries and copy | PluginUI | renderer |
| manager-runtime | MC | 399 | PluginManagerController.renderRuntime | native-renderer | engine/developer/compact/safe/recovery UI | PluginUI | renderer |
| manager-read | MC | 134 | PluginManagerController.readSnapshot | native-model-projection | compare cached snapshots before rendering | PluginUI | renderer |
| manager-enable | MC | 460 | PluginManagerController.setEnabled | native-user-action | await actual enable/disable completion | PluginUI | host |
| manager-remove | MC | 472 | PluginManagerController.confirmRemove | native-user-action | confirm then remove owned plugin | PluginUI | host |
| picker | MC | 529 | PluginManagerController.documentPicker(didPickDocumentsAt:) | native-import-site | copy selected source then native import | PluginUI | host |
| import-copy | MC | 552 | PluginImportCopy.create | native-file-provider | coordinated security-scoped .plugin/.py copy | PluginUI | host |
| ai-source | AI | 29 | ExteralessInstalledPluginReviewSource.snapshot | native-source-provider | bounded installed-plugin bytes and revision | AI | ai |
| ai-review | AI | 123 | ExteralessAIIntegration.presentReview | native-review-operation | configured-provider review/cache lifecycle | AI | ai |
| ai-cache | AT | 241 | AIPluginReviewCache.response | native-cache | expiring revision-keyed response lookup | Core/AI | ai |
| ai-definitions | AT | 230 | AIPluginReviewTools.definitions | native-tool-model | read_source/list_blobs/decode_base64 definitions | Core/AI | value |
| ai-call | AT | 84 | AIPluginReviewTools.call | native-readonly-operation | bounded selected-source tool dispatch | Core/AI | ai |
| ai-fallback | AT | 56 | AIPluginReviewTools.handler | native-tool-model | source-excerpt fallback messages | Core/AI | value |
| facade-instance | PF | 34 | Controller.getInstance | SDK-facade | create own-plugin controller facade | SDK | sdk |
| sdk-version | PF | 26 | PythonBridge.getSdkVersion | constant-model | SDK version 1.4.5.7 | SDK | value |
| warning | RT | 984 | ExteralessPluginRuntime.presentWatchdogWarning | native-ui-operation | nonresponse disable/mute warning | PluginUI/PluginHost | host |
| factory-shadow | SS | 142 | SimpleSettingFactory.is_shadow | model-field | factory shadow flag | SDK | value |
| factory-clickable | SS | 141 | SimpleSettingFactory.is_clickable | model-field | factory clickability flag | SDK | value |
| custom-click | SS | 90 | Custom.on_click | model-field | retained custom action callable | SDK | value |
| custom-long | SS | 91 | Custom.on_long_click | model-field | retained custom long-action callable | SDK | value |
| custom-subpage | SS | 92 | Custom.create_sub_fragment | model-field | custom subpage factory callable | SDK | value |
| custom-args | SS | 89 | Custom.factory_args | model-field | custom factory argument tuple | SDK | value |
| custom-factory | SS | 88 | Custom.factory | model-field | custom content factory reference | SDK | value |
| custom-item | SS | 86 | Custom.item | model-field | custom item/view descriptor reference | SDK | value |
| edit-mask | SS | 80 | EditText.mask | model-field | source mask declaration | SDK | value |
| edit-change | SS | 81 | EditText.on_change | model-field | edit-text change callable | SDK | value |
| input-change | SS | 55 | Input.on_change | model-field | input change callable | SDK | value |
| selector-change | SS | 43 | Selector.on_change | model-field | selector change callable | SDK | value |
| switch-change | SS | 30 | Switch.on_change | model-field | switch change callable | SDK | value |
| text-click | SS | 67 | Text.on_click | model-field | text action callable | SDK | value |
| text-subpage | SS | 69 | Text.create_sub_fragment | model-field | text subpage factory callable | SDK | value |
| row-alias | SS | 70 | Text.link_alias | model-field | declared row link alias | SDK | value |
| row-icon | SS | 64 | Text.icon | model-field | declared semantic row icon | SDK | value |
| factory-build | SS | 150 | SimpleSettingFactory.build_view | SDK-factory | create then bind portable view | SDK | sdk |
| reference-cast | VF | 130 | cast | reference-helper | validate compatible type then return identical reference | SDK | value |
| facade-dir | PF | 40 | Controller.getPluginsDir | SDK-facade | native directory as portable File | SDK | storage |
| facade-settings-present | PF | 49 | Controller.hasPluginSettingsPreferences | SDK-facade | own settings nonempty predicate | SDK | storage |
| facade-settings-clear | PF | 48 | Controller.clearPluginSettingsPreferences | SDK-facade | clear own settings and refresh | SDK | storage |
| facade-settings-read | PF | 45 | Controller.getPluginSettingsJson | SDK-facade | serialize own settings schema | SDK | settings |
| settings-values | PS | 12 | read_values | SDK-adapter | getSettings opaque JSON validation | SDK | storage |
| settings-set | PS | 23 | update | SDK-adapter | replace/merge/clear settings and optional refresh | SDK | storage |
| settings-refresh-adapter | PS | 36 | reload | SDK-adapter | mirror invalidation plus uiRefreshSettings | SDK | ui |
| raw-setting-get | PP | 153 | Platform.getSetting | SDK-facade | own key to JSON text/null | SDK | storage |
| raw-setting-set | PP | 162 | Platform.setSetting | SDK-facade | parse raw setting JSON and write | SDK | storage |
| raw-log | PP | 148 | Platform.log | SDK-facade | format native Runtime.log | SDK | logging |
| raw-log-stream | PF | 28 | PythonBridge.logStream | SDK-facade | level/message to logEvent | SDK | logging |
| raw-permission | PP | 127 | Platform.hasPermission | SDK-facade | own-id strict native Bool query | SDK | bridge-read |
| raw-check | PP | 131 | Platform.checkPermission | SDK-facade | permission query without Android notice | SDK | bridge-read |
| raw-unsafe | PP | 134 | Platform.isUnsafeMode | SDK-facade | native unsafe-mode Bool query | SDK | bridge-read |
| raw-directory | PP | 109 | Platform.getPluginsDir | SDK-facade | validate absolute configured plugin root | SDK | storage |
| file-adapter | PR | 102 | register_file | SDK-adapter | validate callable/icon and register file lease | SDK | native |
| file-remove-adapter | PR | 147 | services.unregisterFileHandler | SDK-adapter | own registration to fileRemove | SDK | cleanup |
| icons-adapter | PR | 148 | services.fileIconsSupported | SDK-availability | false | SDK | value |
| intent-adapter | PR | 124 | register_intent | SDK-adapter | strict before Bool and void after lease | SDK | native |
| intent-remove-adapter | PR | 150 | services.unregisterIntentHandler | SDK-adapter | own registration to intentRemove | SDK | cleanup |
| queue-adapter | PQ | 95 | services.postRunnable | SDK-adapter | named queue to Scheduler.post | SDK | owner-work |
| runnable-adapter | PQ | 96 | services.runnable | SDK-adapter | create portable Runnable | SDK | sdk |
| ui-queue-adapter | PP | 34 | _PluginServices.runOnUiThread | SDK-adapter | wrap void callback for runOnUIThread | SDK | owner-work |
| request-adapter | PT | 442 | base_plugin.PluginServices.sendRequest | SDK-adapter | explicit account to send_request/tlRequest | SDK | tl |
| factory-instance | PU | 584 | PluginItemFactory.getInstance | SDK-facade | create portable factory facade | SDK | sdk |
| factory-create | PU | 586 | PluginItemFactory.create | SDK-facade | construct Custom factory descriptor | SDK | sdk |
| request-native | TS | 43 | exteralessTLRequest | actual-native-effect | bind descriptor execution/origin and call Account.network.request | TL/TelegramCore | tl |
| log-wire | BS | 549 | BridgeServices.callRuntime | native-operation | log | BridgeServices | logging |
| ai-tools-consumer | AI | 130 | ExteralessAIIntegration.presentReview | native-consumer | constructs selected-source tool helper | AI | ai |
<!-- anchors:end -->

### Exact operation projections for shared dispatcher anchors

These narrow shared switch-case anchors to the actual operation/field used by the
listed members. A projection does not change its member's partial disposition.

<!-- operations:begin -->
| Ordinals | Native operation |
| --- | --- |
| 86,290,291 | hasPermission(permission) for the C-bound plugin; Android trust/notice differences remain in member limitations |
| 89,90 | PermissionsModel.check(pluginId, permission, what:) native decision/diagnostic counterpart; no direct Java class facade |
| 88,143,293 | isUnsafeMode() read of PermissionsModel |
| 109,110,352,353 | fileRegister(extension/filename-filter model, owned callback); callback-free overload is unavailable |
| 111,354 | fileRemove(owned registration id) |
| 113,360 | intentRegister(before/priority/URL-filter model, owned callback) |
| 114,361 | intentRemove(owned registration id) |
| 116,199 | postToOwner(owned void callback, delayMs, queue name); exact Java executor semantics are limited |
| 117 | tlRequest(account-scoped schema request, response/error callback) -> exteralessTLRequest -> Account.network.request |
| 118 | AndroidUtilities.runOnUIThread(owned void callback, delayMs) -> captured PluginHost mailbox |
| 137,294 | getPluginsDir() -> portable File/path projection |
| 138 | getPluginConfig(named field) is a closed subset; no arbitrary manager SharedPreferences operation |
| 139 | getPluginConfig(engineEnabled) |
| 140 | setPluginConfig(engineEnabled, Bool) -> queued Runtime engine maintenance transition |
| 141 | getPluginConfig(safeMode) |
| 142 | setPluginConfig(safeMode, Bool) -> queued Runtime safe-mode maintenance transition |
| 145 | getPluginConfig(developerMode) |
| 146 | setPluginConfig(developerMode, Bool) -> authority-checked manager writer/development-server update |
| 147 | getPluginConfig(compactView) |
| 148 | setPluginConfig(compactView, Bool) -> authority-checked manager writer |
| 151 | getPluginConfig(pinned) -> local membership of the requested installed id |
| 152 | managerControls.pin(id, Bool); Config additionally exposes atomic setPluginConfig(pinned, ids) |
| 172,214,215,216,277 | getSettings() -> local key lookup/coercion/JSON-text projection specified by the member |
| 173,217,278 | updateSettings(opaque JSON text containing the decoded key/value); optional uiRefreshSettings() |
| 174 | getSettings() -> own settings nonempty predicate |
| 175,211 | clearSettings(); optional uiRefreshSettings(), subject to the exact facade overload limitation |
| 176,279 | getSettings() -> SDK encode_values compatibility export |
| 177,281 | setSettings(opaque JSON text of decoded compatibility object), or clearSettings() for empty replacement |
| 181,207,208,226,296 | uiRefreshSettings() -> captured native settings invalidation |
| 183 | uiPresent(settings, materialized own rows, owned callbacks) |
| 188,280 | updateSettings(opaque JSON text of decoded compatibility object); optional uiRefreshSettings() |
| 189 | PluginHost.settingsJSON(id, account, expectedOwner, shouldExecute) is the native-manager counterpart; own Java facade serializes locally |
| 210 | getSettings() typed own-plugin object is only a counterpart to raw SharedPreferences values |
| 218,222,326 | PluginHost.updateSetting -> setting_changed_json -> SDK persistence/registered on_change; extra supplied callback is not implemented |
| 223,328 | PluginHost.clickSetting -> setting_click_json -> registered callback id; no Android View argument |
| 249,288 | menuRegister(model, owned callback) through BasePlugin; direct Java/raw JSON facade is missing |
| 250,289 | menuRemove(owned id) through BasePlugin; direct Java facade is missing |
| 265 | managerControls.snapshot().warningMuted membership |
| 266 | managerControls.muteWarning(id, Bool) |
| 267 | ExteralessPluginRuntime.presentWatchdogWarning(pluginId:) |
| 282 | Runtime.log(message) -> PluginServiceLogBuffer.append |
| 283 | logEvent(level/message/phase=sdk) -> bounded native log buffer |
| 591 | AIPluginReviewTools.call(name, arguments:) selected-snapshot helper; not a Java facade |
<!-- operations:end -->

## Member ledger

Columns are ordinal, `name@original-line`, disposition/category, resolved anchor
keys, original body plus counterpart contract, and remaining limitation. Source
file headings are relative to `java/app/exteraless/plugins/`.

<!-- members:begin -->

### ClassAliases.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 1 | resolve@75 | member-body/helper | alias | Preserve null; resolve exact name, outer-class alias and ordered prefix while retaining the nested suffix. SDK resolve supplies the name-only counterpart. | Name resolution neither creates the target class nor supplies its members; finite Config aliases do not expand this guarantee. |

### HookResult.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 2 | fromString@8 | partial/helper | strategy | Android returns DEFAULT for null or unknown strategy strings; native HookStrategy has the same four valid values. | Native result decoding rejects an unknown strategy rather than implementing this forgiving Java parser. |
| 3 | replacement@34 | partial/helper | replacement | Return a typed replacement only for MODIFY/MODIFY_FINAL and compatible Class; native normalizes and merges a JSON send replacement. | No arbitrary Java Class.isInstance/cast replacement; TL replacements have a separate schema normalizer. |
| 4 | isCancel@39 | member-body/model | strategy | Test strategy equality with CANCEL; native .cancel is the corresponding result discriminator. | Value comparison only; cancellation authority remains with the native operation. |
| 5 | isFinal@43 | member-body/model | strategy | Test strategy equality with MODIFY_FINAL; native .modifyFinal terminates the relevant transform chain. | Does not execute a Java hook or bypass native replacement validation. |

### JsonUtils.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 6 | optStringOrNull@23 | partial/helper | json-string | JSONObject/key helper returns null for null container/key/value or empty string; native JSON has an optional typed string projection. | No exact JSONObject optString coercion/empty-to-null helper is exported. |
| 7 | optStringOrNull@35 | partial/helper | json-string | JSONArray/index helper returns null for null/missing/empty value; native typed JSON string projection can represent absence. | Array bounds and optString coercion are not this native accessor's contract. |

### MenuItemRecord.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 8 | fromString@18 | partial/helper | placement | Parse menu enum, defaulting invalid/null names to MESSAGE_CONTEXT_MENU; native defines the five actual placements. | Native menu admission rejects invalid placement instead of silently defaulting. |

### Plugin.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 9 | getId@23 | member-body/model | p.id | Return the stored plugin id; mapped to native Plugin.id. | Field model, not a registered Java Plugin getter. |
| 10 | getEngine@88 | member-body/model | p.engine | Return engine metadata; native Plugin.engine defaults to python. | Metadata does not select another runtime implementation. |
| 11 | setEngine@92 | member-body/model | p.engine | Assign engine metadata; native struct has the same field. | Host metadata admission accepts only python; assignment is not runtime installation. |
| 12 | setName@96 | member-body/model | p.name | Assign the optional display-name field. | Mutating a value model does not publish a Host registry change. |
| 13 | setDescription@100 | member-body/model | p.description | Assign optional plugin description. | Native value field only; no Java instance mutation bridge. |
| 14 | setAuthor@104 | member-body/model | p.author | Assign optional author text. | Native value field only; no registry publication. |
| 15 | setVersion@108 | partial/model | p.version | Assign Android nullable version metadata; native stores a version String. | Native field is nonoptional; null assignment is not represented. |
| 16 | setIcon@112 | member-body/model | p.icon | Assign optional icon pack/index metadata. | Assignment does not load a sticker or create a drawable. |
| 17 | setAppVersion@116 | member-body/model | p.app | Assign optional application-version constraint text. | This setter itself performs no version validation. |
| 18 | setSdkVersion@120 | member-body/model | p.sdk | Assign optional SDK-version constraint text. | This setter itself performs no compatibility validation. |
| 19 | setRequirements@124 | member-body/model | p.requirements | Copy the provided requirement list; Android null becomes an empty list, native uses value-array storage. | Requirements remain data; runtime package installation is not supplied. |
| 20 | getName@128 | member-body/model | p.name | Return optional plugin name. | Native field read only; no Java getter export. |
| 21 | getDescription@132 | member-body/model | p.description | Return optional plugin description. | Native field read only. |
| 22 | getAuthor@136 | member-body/model | p.author | Return optional author. | Native field read only. |
| 23 | getVersion@140 | partial/model | p.version | Return version metadata. | Native String has a default and cannot preserve Java null. |
| 24 | getIcon@144 | member-body/model | p.icon | Return optional icon specification. | An icon string is not proof of an installed native sticker-image provider. |
| 25 | getAppVersion@148 | member-body/model | p.app | Return application-version constraint metadata. | No live compatibility check is performed by the getter. |
| 26 | getSdkVersion@152 | member-body/model | p.sdk | Return required SDK-version metadata. | Distinct from the runtime's current SDK version. |
| 27 | getRequirements@156 | partial/model | p.requirements | Return requirement list; native carries the same values. | Android returns a mutable list reference; Swift value-array identity differs. |
| 28 | isEnabled@160 | member-body/model | p.active | Compute enabled AND loadError == null; native computed property matches that predicate. | Does not imply loaded or responsive. |
| 29 | setEnabled@164 | member-body/model | p.enabled | Assign the persisted-enable field on the model. | Actual enable/disable effects require PluginHost.setPluginEnabled. |
| 30 | getError@168 | member-body/model | p.error | Return transient loadError. | No exception throwing or log lookup is implied. |
| 31 | setError@172 | member-body/model | p.error | Assign transient loadError. | Struct mutation is not a Host failure publication. |
| 32 | hasError@176 | member-body/model | p.error | Return whether loadError is non-null. | Empty non-null text still counts as an error; model predicate only. |
| 33 | isNotResponding@180 | member-body/model | p.frozen | Read watchdog nonresponse state. | The native watchdog owns updates to published plugin values. |
| 34 | setNotResponding@184 | member-body/model | p.frozen | Assign the nonresponse flag. | This field assignment does not abandon or recover an interpreter. |
| 35 | getPack@189 | member-body/model | p.pack | Return null for absent icon, otherwise the prefix before its first slash or the entire icon. | String parsing only; no sticker-pack fetch. |
| 36 | getIndex@198 | partial/model | p.index | Parse the icon suffix after the first slash, falling back to zero on absence or invalid input. | Java Int32 overflow falls back to zero; Swift Int can accept a wider value. |
| 37 | getDisplayName@213 | member-body/model | p.title | Return name when non-null, otherwise id. | Empty name remains empty in this model property; renderer may choose an additional fallback. |
| 38 | getSubtitle@217 | partial/model | p.subtitle | Build v-version plus optional author and error marker. | Native also substitutes 1.0 for an empty version; Android substitutes only for null. |

### PluginAuditJournal.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 39 | record@70 | partial/audit-operation | audit-record | Delegate audit recording with no stack; stock Python audit records are a data counterpart. | No native Java/Python merged journal provider accepting these five arguments. |
| 40 | record@75 | partial/audit-operation | audit-record,log-event | Trim detail to 200, coalesce equal consecutive entries and increment allowed/denied category counters. | Native logEvent is a log entry, not this stack-aware/coalescing Java audit store. |
| 41 | entries@111 | partial/audit-operation | audit-list,logs | Copy matching Java audit entries, or all for null plugin id. | Native log snapshots and own Python audit entries do not expose this merged cross-plugin Entry list. |
| 42 | profile@124 | partial/audit-operation | audit-profile | Return copied allowed/denied counters per category, empty when absent. | Python counters exist; no native manager profile bridge or Java profile-copy method. |
| 43 | forget@138 | partial/audit-operation | audit-clear | Remove one plugin's Java profile and entries; SDK can clear its own audit data. | No native authority-bound merged-journal erase operation. |
| 44 | merged@149 | partial/audit-operation | audit-list | Merge Java entries with decoded Python journal, normalize count and sort by timestamp. | Native log buffers do not implement merged Java/Python audit ordering or Entry fields. |

### PluginCapabilityScan.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 45 | scan@42 | partial/source-analysis | scan | Ask stock SDK static scanner for JSON and parse capability evidence; failures produce an empty map. | SDK source analysis exists, but no native manager/Java scan(File) provider is connected. |
| 46 | store@85 | partial/storage-operation | - | Serialize permission-to-evidence lists under the plugin capability preference key. | Missing native capability-evidence cache write, distinct from per-plugin user settings. |
| 47 | load@105 | partial/storage-operation | - | Read and parse cached capability evidence, returning an empty map for absent inputs. | Missing native manager capability-cache read. |
| 48 | ensureScanned@125 | partial/lifecycle | scan | Skip invalid/already-cached plugin; scan on global queue, persist result and notify UI only for nonempty evidence. | No native scan-once/cache/onReady manager lifecycle. |
| 49 | obfuscationEvidence@145 | member-body/model | obfuscation | Read the obfuscation evidence list; SDK scanner produces that named data bucket. | No native cache getter or automatic consent display follows from scanner data. |
| 50 | isObfuscated@149 | member-body/model | obfuscation | Test whether the obfuscation evidence bucket is nonempty. | Static evidence classification only, not runtime enforcement or complete code analysis. |
| 51 | dexInfo@160 | partial/model | dex-info | Parse size/loaded/class/more evidence strings into a DexInfo model, ignoring malformed numbers. | SDK inspects embedded DEX bytes as data; no native DexInfo adapter or DEX execution. |
| 52 | evidenceOf@195 | member-body/model | scan | Return the requested map bucket, or a new empty list when absent. | Dictionary/list projection only; Java reference semantics are not exported. |
| 53 | clear@200 | partial/storage-operation | - | Remove one plugin's cached capability preference. | Missing native capability-cache deletion operation. |
| 54 | ordered@211 | partial/helper | perm-sanitize | List present capability keys in requestable-permission order. | Native sanitize supplies permission order but no exact capability-map projection helper. |

### PluginDenialNotice.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 55 | didReceivedNotification@53 | partial/platform-lifecycle | - | On passcode dismissal remove the observer and schedule pending unconsented notices. | No native passcode-to-plugin-consent-notice queue. |
| 56 | note@65 | partial/ui-operation | check-permission | Ignore UI grants, deduplicate plugin/permission notices and retain failed presentations for retry. | Native permission diagnostics do not provide this deduplicated denial-notice presenter. |
| 57 | noteOverlay@85 | unsupported/android-ui | - | Schedule the Android overlay-permission notice on supported Android versions. | SYSTEM_ALERT_WINDOW/Settings.canDrawOverlays and its grant UI have no iOS provider. |
| 58 | noteUnconsented@115 | partial/ui-operation | - | Add a plugin once to the unconsented set and schedule its consent notice. | Missing native deferred unconsented-plugin notice operation. |
| 59 | flush@174 | partial/platform-lifecycle | - | Retry unconsented notices and the oldest pending plugin/permission notice after the flush delay. | No native pending-denial FIFO/retry lifecycle. |
| 60 | reset@254 | partial/platform-lifecycle | - | Remove the plugin's shown/overlay/pending denial markers. | Native grant changes do not maintain or reset an equivalent notice-state collection. |

### PluginInstallHelper.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 61 | isPluginUri@83 | partial/file-operation | import-copy | Android resolves plugin suffix from Context/Uri; native import validates a selected regular .py/.plugin file URL. | No Android content-URI resolution; Elyx/EAF install formats are unavailable. |
| 62 | handleMessageTap@100 | partial/ui-operation | import | Check downloaded nonempty message document and open plugin installation UI. | Native manager can import source, but no matching plugin-document message-tap install site was found. |
| 63 | handleViewIntent@135 | partial/ui-operation | picker,import-copy | Resolve/copy incoming plugin URI to cache, then show install UI or read error. | Native Files picker is connected; equivalent incoming VIEW/content-URI plugin installer is missing. |
| 64 | confirmAndInstall@209 | partial/ui-operation | import | Wrap File in install parameters and delegate to consent/install flow. | Native import does not implement this preview/permission-consent overload. |
| 65 | confirmAndInstall@214 | partial/ui-operation | metadata,import | Offer engine enable, inspect metadata, scan capabilities and show consent sheet before install. | Native import supplies AST/install providers, but no equivalent capability/trust/consent sheet or install-parameter flags. |

### PluginLog.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 66 | append@38 | partial/log-operation | log-event,log | Capture timestamp/thread and queue a disk log write; native appends a bounded structured entry. | Native buffer is not the rotating Android disk/thread log format. |
| 67 | files@81 | partial/log-operation | logs | Return existing previous/current log files in rotation order. | Native entries() returns values, not an ordered pair of rotating disk files. |
| 68 | export@100 | partial/log-operation | manager-logs | Drain writes and concatenate rotated logs with app/device header into a shareable file. | Native log UI copies its bounded displayed lines; missing drained disk-log export operation. |
| 69 | clear@129 | partial/log-operation | - | Queue deletion of the current and previous plugin log files. | No equivalent native persistent-log clear operation is connected. |

### PluginMediaServices.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 70 | prepareDocument@34 | partial/media-operation | media-model | Validate a local file and produce document size/date/MIME/filename metadata with empty file_reference. | Native media preparation builds its own resource model; no Java TL_document-returning prepareDocument facade. |
| 71 | editMedia@49 | partial/media-operation | tl-edit,edit-native | Require message/account ownership, derive video/document kind, retain caption/entities when omitted and start real media replacement. | Native editMedia requires explicit typed peer/message namespace; no MessageObject overload. Secret/rich/paid and some reference-upload edit targets are rejected. |

### PluginPermissions.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 72 | isKnown@74 | member-body/model | perm-kind | Test membership of a non-null permission name in the fixed permission set. | Enum/model check only; unknown names cannot acquire provider capabilities. |
| 73 | isDangerous@82 | member-body/model | perm-danger | Classify hooks/native as dangerous. | Classification does not implement Java hooking/native library loading. |
| 74 | describe@87 | partial/model | perm-description | Map known permission names to descriptions; null becomes unknown and unknown text passes through. | Native enum descriptions match known cases but do not expose the nullable/unknown string helper. |
| 75 | sanitize@106 | member-body/helper | perm-sanitize | Remove unknown/duplicate permissions while retaining canonical ALL order. | Native typed output is an enum array, not Java string-list identity. |
| 76 | prefsKey@125 | partial/storage-model | grants-read | Construct the Android plugin-permission preference key. | Native grants.json is keyed by plugin id; Android preference-prefix compatibility is absent. |
| 77 | hasRecord@137 | partial/storage-operation | grants-read | Distinguish a stored consent record from no consent record. | Native internal map preserves absence, but no public hasRecord or Java SharedPreferences lookup is exported. |
| 78 | getStored@143 | partial/storage-operation | grants-read | Decode comma-separated grants, remove unknowns/duplicates and preserve null for no record. | Native stores enum arrays; no nullable raw-grant read facade or Android comma-string persistence. |
| 79 | setGranted@166 | partial/permission-operation | set-grants,grants-write | Native host can sanitize/persist granted permissions for an installed plugin; Android additionally resets denial caches. | No plugin-callable Java grant mutation or equivalent denial-cache reset. |
| 80 | grant@183 | partial/permission-operation | grants-write | Add a known permission to effective grants and persist through setGranted. | Native manager builds a replacement grant array; no atomic named grant method or trust-cap migration. |
| 81 | revoke@193 | partial/permission-operation | grants-write | Preserve implicit UI, remove another permission and persist the remaining set. | Native replacement-grant path exists; direct Java revoke and notice reset are absent. |
| 82 | clear@204 | partial/permission-operation | grants-clear | Delete the stored consent record and clear per-plugin denial caches. | Host owns deletion; no signed preference/denial-notice cleanup equivalence. |
| 83 | getEffective@228 | partial/permission-operation | effective | Apply ISOLATED UI-only or GATED hooks/native removal after reading raw grants. | Native effective() has no trust-level cap; focused P2 counterexample above. |
| 84 | getEffectiveRaw@246 | partial/permission-operation | effective | Return stored grants plus implicit UI; no record means UI only and a legacy diagnostic. | Native effective() includes unsafe-mode override and has no separate raw-grants-without-trust facade. |
| 85 | getRequested@262 | member-body/model | requested | Sanitize plugin-declared permissions and omit implicit UI. | Metadata projection only; scan-derived consent expansion is separate and absent. |
| 86 | has@271 | partial/permission-operation | permission,effective | UI or unsafe mode permits; otherwise require a known grant for the plugin. | Native query is owner-bound and lacks Android trust-level filtering. |
| 87 | invalidateCache@308 | platform-lifecycle/permission-cache | effective | Android advances cache generation and drops cached effective grants; native reads the synchronized current grant set. | Native has no equivalent memoized generation cache to invalidate or Java invalidation method. |
| 88 | isUnsafeMode@325 | partial/permission-operation | unsafe | Original queries controller unsafe mode and returns false on exception; native Runtime has a strict Bool query counterpart. | The PluginPermissions Java class/getter is not registered; supported PythonBridge/SDK queries use the actual native flag instead. |
| 89 | check@337 | partial/permission-operation | check-permission | Return permission decision and diagnose denial. | Native does not reproduce once-per-pair logs, trust cap or queued denial notices. |
| 90 | check@351 | partial/permission-operation | check-permission | Include the attempted operation in denial diagnostics. | No exact three-string Java call route or operation-keyed notice deduplication. |

### PluginRuntime.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 91 | enter@31 | platform-lifecycle/interpreter-context | mark,owner | Save prior thread-local plugin id and enter the current plugin; native uses an immutable owner plus scoped SDK context. | Native context cannot be retargeted to another plugin by this Java setter. |
| 92 | exit@38 | platform-lifecycle/interpreter-context | mark | Restore/remove the previous plugin context on scope exit. | Context-manager finalization replaces Java ThreadLocal mutation; no cross-owner restoration authority. |
| 93 | current@47 | platform-lifecycle/interpreter-context | owner | Read current plugin attribution; native captured CallbackOwner carries the immutable plugin identity. | No writable Java ThreadLocal or ambient replacement-owner lookup. |
| 94 | enterPython@56 | platform-lifecycle/interpreter-context | worker | Increment Android thread-local Python nesting depth; native mailbox owns interpreter/GIL entry. | No public native nesting-counter API or Python-on-main contract. |
| 95 | exitPython@65 | platform-lifecycle/interpreter-context | worker | Decrement/remove Python nesting depth; native worker finishes its captured invocation. | Not an exposed native counter or interpreter-destruction command. |
| 96 | isPythonActive@76 | partial/interpreter-context | worker | Test positive Android Python-depth counter. | Native worker ownership exists, but this thread-local Bool query has no provider. |

### PluginServices.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 97 | hookMethod@38 | unsupported/xposed | - | Check hooks permission and register a Java member hook with handler/priority/filter JSON. | No Xposed/ART java.lang.reflect.Member executor on iOS. |
| 98 | hookAllMethods@47 | unsupported/xposed | - | Check hooks permission and register all named Java method overloads. | No JVM method enumeration/patching provider; native typed TL hooks are a different surface. |
| 99 | hookAllConstructors@56 | unsupported/xposed | - | Check hooks permission and register hooks on every Java constructor. | No Xposed constructor interception on native Swift/CPython objects. |
| 100 | unhook@64 | unsupported/xposed | - | Remove the Xposed unhook-id registration. | No Xposed registration or unhook token exists in this native runtime. |
| 101 | invokeOriginalMethod@69 | unsupported/xposed | - | Invoke a hooked Java member's original implementation with receiver/arguments. | No Java original-method trampoline provider. |
| 102 | deoptimizeMethod@73 | unsupported/art | - | Require hooks permission before ART method deoptimization. | iOS has no Android ART method optimizer/deoptimization API. |
| 103 | allocateInstance@80 | unsupported/jvm | - | Require hooks permission and allocate a Java class without its constructor. | No Java Class allocation-without-constructor provider. |
| 104 | generateProxyClass@90 | unsupported/dex | - | Require current plugin and UI/hooks according to superclass, then generate a proxy class from JSON. | DEX bytecode generation/loading and Java subclass execution are unavailable. |
| 105 | getProxyError@106 | partial/diagnostic-model | - | Return ClassProxyFactory's last error string. | Missing proxy-generator error-cache provider; named unsupported errors are not this stored diagnostic. |
| 106 | newProxyInstance@111 | unsupported/dex | - | Check proxy superclass permission and instantiate a generated Java class with constructor signature and Python peer. | No generated DEX class/constructor/peer-binding runtime. |
| 107 | getProxyClass@125 | unsupported/dex | - | Return the generated class associated with a class key. | No DEX generated-class registry or Java Class return value. |
| 108 | invokeSuper@130 | unsupported/dex | - | Resolve owning plugin from class key, check hooks and call the generated superclass trampoline. | No Java-super trampoline; portable widget composition does not implement it. |
| 109 | registerFileHandler@152 | partial/file-operation | file-register | Five-argument overload delegates with null callback. | Portable adapter requires a callable on_click; this null-callback registration is not admitted. |
| 110 | registerFileHandler@160 | source-routed/file-operation | file-adapter,file-register,file-open | Validate extension/filename filters, require files permission and retain the callback for the native chat-document opener. | Only composed document sites; no Android icon factory or Activity/BaseFragment object context. |
| 111 | unregisterFileHandler@169 | source-routed/file-operation | file-remove-adapter,native-cleanup | Own SDK registration resolves its native id; fileRemove revokes that captured lease. | SDK unknown-id errors differ from Android's silent rejected secret/extension removal. |
| 112 | fileIconsSupported@173 | member-body/availability | icons-adapter,file-icons | Report false; original FilesControllerJava also reports no icon support. | No Android document-icon callback site is advertised. |
| 113 | registerIntentHandler@180 | source-routed/intent-operation | intent-adapter,intent-register,intent-open | Retain ordered before/after callback with validated URL filters and intents grant. | Actual sites expose ACTION_VIEW URLs; unsupported Android MIME/categories/nonzero required flags fail admission. |
| 114 | unregisterIntentHandler@188 | source-routed/intent-operation | intent-remove-adapter,native-cleanup | Resolve own handler id and revoke the stored native intent lease. | Native lifetime identity replaces Java plugin/id-only removal; no replacement owner cleanup. |
| 115 | runnable@207 | partial/scheduling-helper | runnable-adapter | Wrap a callback as zero-argument work; actual native scheduling is a separate later operation. | Null handling and Java runWhenUnfrozen wrapper are not exact; this helper alone enqueues no task. |
| 116 | postRunnable@230 | source-routed/scheduling-operation | queue-adapter,schedule | Map the named SDK queue and callback to a generation-bound owner task with delay. | Native owner worker rather than arbitrary Android DispatchQueue thread; delay 0..86400000 ms. |
| 117 | sendRequest@242 | source-routed/tl-operation | request-adapter,tl-request,request-native | Route explicit account/TL request to native Network provider and deliver callback(response,error) on its captured worker. | Schema-backed TL values only; result means native request admission, with cancellation/terminal cleanup, not network delivery. |
| 118 | runOnUiThread@258 | source-routed/scheduling-operation | ui-queue-adapter,ui-schedule | Schedule a zero-argument void callback using the captured native owner and delay. | Python executes on its interpreter worker, not UIKit/main; no Android asynchronous Message object. |

### PluginSinkGate.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 119 | install@126 | unsupported/xposed | - | Install Java process/network/overlay/reflection/messenger/grant/Python callback sink hooks through Aliuhook. | No Java sink patching on iOS; native provider admission and Python audit checks are separate mechanisms. |
| 120 | allowDatabaseAccess@1018 | unsupported/android-storage | - | Attribute Java database access and gate it on messages.read/unsafe while recording the decision. | No raw Android SQLite/Postbox database handle access provider; bounded native account snapshots are not equivalent. |
| 121 | callingPlugin@1044 | platform-lifecycle/interpreter-context | owner,mark | Determine plugin attribution during Java/Python calls; native bridge uses its C-bound immutable owner. | No Java stack inspection or caller-controlled owner inference. |
| 122 | refuseForeign@1055 | partial/admission-operation | owner | Reject cross-plugin mutations unless hooks is granted; native operations bind their stored owner independently. | Native does not implement a hooks-grant bypass for arbitrary cross-plugin Java operations. |
| 123 | refuseFromPlugin@1068 | partial/admission-operation | owner | Reject plugin-origin manager calls, optionally allowing trusted hooks callers. | Native host-only management/owner admission does not expose this general trusted-caller predicate. |

### PluginTrustLevel.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 124 | prefsKey@45 | partial/storage-model | - | Construct the plugin trust-level preference key. | Missing native trust-level storage namespace. |
| 125 | getLevel@59 | partial/permission-operation | - | Read/clamp stored trust or migrate/persist a default level. | No native ISOLATED/GATED/TRUSTED value, migration or getter. |
| 126 | setLevel@93 | partial/permission-operation | grants-write | Persist/clamp trust, invalidate grants and remove all non-UI or dangerous grants according to level. | Native grant replacement exists, but missing trust-level state and atomic level-plus-grant policy. |
| 127 | allows@114 | partial/permission-operation | effective | UI/unsafe always allow; ISOLATED denies other permissions, TRUSTED allows dangerous permissions. | Native effective() has no level argument or corresponding trust cap. |
| 128 | allows@127 | partial/permission-operation | - | Load a plugin's trust level then apply the level/permission predicate. | Missing native trust lookup and composed allows operation. |
| 129 | clear@132 | partial/permission-operation | - | Remove stored trust level after caller gate and invalidate effective grants. | Native uninstall clears grants but has no trust-level record to clear. |

### PluginsBackup.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 130 | export@56 | partial/backup-operation | - | ZIP installed plugin sources plus id/name/version/enabled/settings manifest with bounded entry copies. | Missing plugin-source archive exporter; data-only Tools settings backup is not this operation. |
| 131 | read@108 | partial/backup-operation | - | Read/validate archive manifest and canonical plugins/id.ext entries, preserving enabled/settings data. | No native reader for this Android plugin-source archive format. |
| 132 | importAll@152 | partial/backup-operation | import | Extract selected source entries, replace their settings, install with enabled flags and report success count. | Native single-source import exists; missing archive selection/extraction/batch restore/callback-count operation. |

### PluginsController.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 133 | peekInstance@61 | platform-lifecycle/manager-lifecycle | runtime-snapshot | Return the existing controller without creating it; native runtime retains an optional Host and exposes a snapshot. | No public Java peekInstance facade; snapshot is not a controller reference. |
| 134 | getInstance@65 | partial/manager-lifecycle | facade-instance | Android lazily returns a singleton manager; SDK Controller.getInstance creates an own-plugin facade. | Facade identity is not singleton manager identity and exposes only its reviewed members. |
| 135 | init@126 | platform-lifecycle/manager-lifecycle | runtime-start,host-start | Initialize storage/grants/watchdog, recover startup and load enabled plugins when engine policy allows. | Native startup is account/main-app gated; Android Context, Aliuhook and three-level consent migration are not reproduced. |
| 136 | getWatchdog@179 | partial/manager-operation | watchdog-start | Return the controller's watchdog object. | Native Host owns a watchdog, but no Java getWatchdog object facade is exported. |
| 137 | getPluginsDir@183 | source-routed/storage-operation | facade-dir,raw-directory,directory | Return the native installed-plugin directory as the SDK's portable File facade. | Scoped native Application Support path replaces Android Context/files/plugins. |
| 138 | getPreferences@194 | partial/storage-operation | config-read | Return Android manager SharedPreferences; native exposes only named manager configuration fields. | No arbitrary native manager SharedPreferences handle/read/write interface. |
| 139 | isEngineEnabled@198 | partial/manager-operation | config-read | Read persisted engine-enabled state from the actual native manager snapshot. | getPluginConfig(engineEnabled) is wired through Config; PluginsController.isEngineEnabled itself is absent from Controller facade. |
| 140 | setEngineEnabled@202 | partial/manager-operation | config-write,mode | Persist engine enable and load/unload according to policy; native mode transition uses maintenance and preserves enabled choices. | Direct controller setter and Android native-hook marker reset are absent; Config setter reports admission before completion. |
| 141 | isSafeMode@223 | partial/manager-operation | config-read | Read native manager safe-mode state. | Available as getPluginConfig(safeMode), not this Java controller method. |
| 142 | setSafeMode@227 | partial/manager-operation | config-write,mode | Native safe-mode control suspends/resumes execution through nonterminal Host maintenance. | Android method merely writes a preference; direct Java setter and synchronous completion are not provided. |
| 143 | isUnsafeMode@234 | partial/manager-operation | unsafe | Android lazily caches signed unsafe-mode state; native BridgeServices can return the actual permission model flag. | Controller facade getter and signed-store cache semantics are missing. |
| 144 | setUnsafeMode@248 | partial/manager-operation | - | Persist unsafe mode in the grant store, update cache and push the value into Python. | Missing composed native public unsafe-mode writer/persistence/broadcast operation. |
| 145 | isDeveloperMode@263 | partial/manager-operation | config-read | Read native developer-mode preference. | Config projection exists; direct PluginsController getter is not registered. |
| 146 | setDeveloperMode@267 | partial/manager-operation | config-write,controls | Change native developer mode using current manager authority and update its development server. | Native queued authority-bound operation is not the Android direct preference setter. |
| 147 | isCompactView@273 | partial/manager-operation | config-read | Read native compact-list mode. | getPluginConfig(compactView) exists; this controller getter is missing. |
| 148 | setCompactView@277 | partial/manager-operation | config-write,controls | Persist native compact-list preference and refresh the manager projection. | No direct Java setter; asynchronous Config admission is not synchronous completion. |
| 149 | isCompatibilityMode@287 | unsupported/art | config-art | Read Android ART compatibility preference. | Native explicitly rejects compatibilityMode because ART Profile Saver is absent. |
| 150 | setCompatibilityMode@292 | unsupported/art | config-art | Store the Android ART compatibility preference. | No native ART optimization mode to apply; provider explicitly rejects this field. |
| 151 | isPluginPinned@302 | partial/manager-operation | config-read | Query whether plugin id belongs to the native pinned installed-id set. | Missing direct static Java predicate; Config exposes the entire filtered set. |
| 152 | setPluginPinned@307 | partial/manager-operation | controls,config-write | Native manager can pin/unpin one id; Config can atomically replace the installed-id pinned set. | No static PluginsController setter facade; absent/uninstalled-id behavior differs from arbitrary preference keys. |
| 153 | isPlugin@330 | partial/file-operation | import-copy | Require existing nonempty file with a recognized source extension; native import validates regular file URL and source suffix. | No File/MessageObject predicate overload; original Elyx/EAF formats are not native install formats. |
| 154 | isPlugin@335 | partial/file-operation | import-copy | Resolve a message document path after checking its extension. | Missing native MessageObject-to-plugin-file predicate; manager picker is not message resolution. |
| 155 | getPluginsSnapshot@347 | partial/manager-operation | host-list | Native Host returns a synchronized copied plugin list. | Java getPluginsSnapshot facade is absent; plugins cannot enumerate the native manager this way. |
| 156 | getPlugins@356 | partial/manager-operation | host-list,facade-list-gap | Android returns the mutable plugin map; native manager has a value snapshot. | SDK Controller.getPlugins explicitly raises; no cross-plugin registry or mutable-map provider. |
| 157 | getPluginsMap@360 | partial/manager-operation | host-list | Android returns its backing plugin map. | Native snapshot is not a live mutable map and this Java method is not exposed. |
| 158 | getPlugin@364 | partial/manager-operation | facade-own,host-list | Android looks up a Plugin metadata object; native manager can find it in a snapshot. | SDK facade checks own id and returns the loaded BasePlugin instance, not the cross-plugin Java Plugin model. |
| 159 | rescanPlugins@426 | partial/manager-operation | host-list,import | Scan supported files, reconcile metadata/enabled state, remove disappeared plugins and unload them. | Native manager persists/imports a catalog; no equivalent directory reconciliation/rescan operation. |
| 160 | checkVersionConstraint@646 | partial/helper | - | Parse optional comparison operator, compare numeric version parts; empty/non-numeric constraints allow. | No exact native public two-string version-constraint helper was found. |
| 161 | rescanAndLoadEnabled@706 | partial/manager-lifecycle | host-start | Rescan then load enabled/error-free/unloaded plugins unless safe mode is set. | Host startup loads its stored catalog, not this Android directory-rescan operation. |
| 162 | setPluginEnabled@813 | partial/manager-operation | enabled | Native Host persists enabled state and loads/unloads the captured installed plugin. | Direct Java Bool-returning controller facade is absent; native operation throws/awaits and differs for unchanged flags. |
| 163 | setPluginEnabled@839 | partial/manager-operation | manager-enable,enabled | Queue enable/disable, collect toggle trace and callback with null or failing id. | Native async completion exists; no Utilities.Callback<String> overload or Android UI-thread callback. |
| 164 | rescanPlugins@860 | partial/manager-operation | - | Run directory reconciliation on engine executor then notify onDone on Android UI thread. | Missing native rescan operation and matching callback overload. |
| 165 | reloadPlugin@869 | partial/manager-operation | reload | Queue reload and notify completion. | Native reload exists but no Runnable overload; Host reload does not reread metadata as the delegated Android body does. |
| 166 | reloadPlugin@878 | partial/manager-operation | reload | Unload old instance, reread source metadata, update fields and load it again. | Host reload reuses the stored Plugin model; direct Java route and metadata refresh are missing. |
| 167 | readMetadataAsync@951 | partial/manager-operation | metadata | Inspect metadata asynchronously without executing the plugin body. | Native uses an isolated no-threads inspector and throws errors; Java callback/null-on-failure signature is not exported. |
| 168 | installPlugin@971 | partial/manager-operation | import | Default install enables the selected plugin and delegates to the fuller overload. | Native source import exists; no File/InstallCallback Java facade. |
| 169 | installPlugin@975 | partial/manager-operation | install | Install with explicit enabled flag, defaulting keepEnabledState to false. | Native install consumes a Plugin model; no exact enable/callback overload. |
| 170 | installPlugin@979 | partial/manager-operation | install | Inspect/copy source, reconcile duplicate extensions, preserve enable flag when requested, unload/replace and report installation. | Missing Java keepEnabledState/installer-trust/extension cleanup semantics; only .py/.plugin native source import is supported. |
| 171 | uninstallPlugin@1069 | partial/manager-operation | remove | Unload, remove catalog/source/grants and clear plugin-associated state. | Native Host removal does not implement all Android settings-file/capability/trust/audit/pin cleanup or Bool return semantics. |
| 172 | getPluginSettingJson@1141 | partial/storage-operation | settings-get | Read one stored setting as JSON text; PythonBridge adapter provides that own-plugin operation. | PluginsController getter name is absent; bulk native storage is typed JSON rather than SharedPreferences strings. |
| 173 | setPluginSettingJson@1148 | partial/storage-operation | settings-write,refresh | Decode/store one JSON value, invalidate SDK mirror and optionally refresh its settings UI. | Existing PythonBridge path supplies it; exact controller alias is missing and invalid JSON errors are not swallowed. |
| 174 | hasPluginSettingsPreferences@1169 | source-routed/storage-operation | facade-settings-present,settings-values,settings-get | Own-plugin facade returns whether stored settings object is nonempty. | Tests content, not file existence or create_settings availability. |
| 175 | clearPluginSettingsPreferences@1174 | source-routed/storage-operation | facade-settings-clear,settings-set,settings-clear,refresh | Own-plugin facade clears values, invalidates mirrors and requests settings refresh. | Does not remove native callback owner or a physical Android preferences file. |
| 176 | exportPluginSettings@1183 | source-routed/storage-operation | settings-get,settings-export | Export stored values in the original JSON-string-per-key compatibility envelope. | Export is own-plugin only; native opaque bulk transport preserves literal keys. |
| 177 | replacePluginSettings@1198 | source-routed/storage-operation | settings-write,settings-replace | Decode the compatibility envelope and replace the entire per-plugin settings object. | Native write failures propagate; malformed input is not silently logged and ignored. |
| 178 | addXposedHook@1218 | unsupported/xposed | - | Register an owned XC_MethodHook.Unhook object after foreign-caller gating. | No Xposed Unhook objects/registry exist on iOS. |
| 179 | addXposedHooks@1226 | unsupported/xposed | - | Iterate and register a Java ArrayList of Xposed unhook handles. | No native Java Xposed collection/handle admission. |
| 180 | removeXposedHook@1239 | unsupported/xposed | - | Remove an owned Xposed unhook object. | Native TL/UI leases are not Xposed unhook objects. |
| 181 | loadPluginSettings@1247 | source-routed/settings-operation | settings-refresh-adapter,refresh | Facade aliases loadPluginSettings(id) to real settings mirror invalidation and native UI refresh. | Own-plugin only; it does not instantiate Android setting views. |
| 182 | getEngines@1255 | partial/manager-operation | host-start | Return the engine-name-to-Python-engine map. | Native has one CPython Host composition, not a public Java engine-object registry. |
| 183 | openPluginSettings@1261 | source-routed/ui-operation | facade-open,ui-custom,present | Own-plugin facade materializes its settings DTO and presents native settings. | Uses SDK presenter, not an Android fragment or cross-plugin manager settings action. |
| 184 | settingsLink@1265 | partial/navigation-operation | - | Build the t.me/exteraSettings link with plugin id and optional URI-encoded setting alias. | No native original-link generator/resolver contract; pagePath is a different addressing model. |
| 185 | isSettingsLink@1270 | partial/navigation-operation | - | Recognize exterasettings/exteraless path and require nonempty p query parameter. | No equivalent native plugin-settings URL recognizer was found. |
| 186 | openSettingsLink@1276 | partial/navigation-operation | settings-page | Resolve p/s URL parameters, diagnose engine/plugin/settings absence and open the target row. | Native identifier-based subpages exist; original alias URL parsing/resolution and its error actions are missing. |
| 187 | openPluginSettings@1306 | partial/navigation-operation | facade-open,settings-page | Open own plugin root or target setting on the UI thread. | SDK rejects non-null target before native presentation; no original targetSetting-to-pagePath resolver. |
| 188 | importPluginSettings@1323 | source-routed/storage-operation | settings-write,settings-import,refresh | Merge decoded compatibility values, invalidate mirror and optionally request native refresh. | Own-plugin only; malformed inputs/write failures surface explicitly. |
| 189 | getPluginSettingsJson@1348 | source-routed/settings-operation | facade-settings-read,py-settings,settings-read | Own facade serializes create_settings; native manager uses its captured-owner Host read counterpart. | Dynamic display schema is not immutable backup authority; no cross-plugin facade read. |
| 190 | init@1354 | platform-lifecycle/manager-lifecycle | runtime-start | Start manager using current safe-mode policy. | Java init() is not exported; application account/bootstrap owns native startup. |
| 191 | init@1361 | partial/manager-lifecycle | runtime-start | Initialize under current safe policy, then notify the supplied Runnable. | No equivalent Java completion-callback entry; native startup awaits its own Task. |
| 192 | init@1368 | partial/manager-lifecycle | host-start,mode | Initialize with an explicit safe-mode choice. | Native application startup/mode controls exist but not this direct Java overload. |
| 193 | init@1375 | partial/manager-lifecycle | runtime-start,mode | Set safe mode, initialize application context when available and schedule onDone. | Missing boolean/Runnable Java startup composition; no Android Context ownership. |
| 194 | getInitialized@1388 | partial/manager-operation | host-start | Read manager initialization state. | Native Host running/startup phases are not the Android initialized-before-engine flag; no exact getter. |
| 195 | restart@1392 | partial/manager-lifecycle | mode | Delegate restart using current safe-mode value. | Native nonterminal maintenance/mode transitions exist; no Java restart method with the same unload/rescan contract. |
| 196 | restart@1399 | partial/manager-lifecycle | mode,host-start | Change safe mode, unload all and rescan/reload if execution is enabled. | Native mode transition does not implement source-directory rescan or this direct overload. |
| 197 | shutdown@1415 | partial/manager-lifecycle | host-stop | Delegate Android unload-all shutdown. | Host.stop is terminal runtime teardown, not Android's still-started engine unload-all command. |
| 198 | shutdown@1422 | partial/manager-lifecycle | host-stop | Unload all and notify onDone on UI thread. | Native stop/drain exists; no matching unload-only/Runnable callback signature. |
| 199 | runOnPluginsQueue@1432 | partial/scheduling-operation | schedule | Execute non-null work on the plugin file executor. | Native postToOwner is generation-bound interpreter work, not a global file executor or direct controller alias. |
| 200 | getPluginPath@1438 | partial/manager-operation | host-list | Find plugin metadata path or null. | Native snapshot carries path; no cross-plugin Java path lookup provider. |
| 201 | getPluginEngine@1443 | partial/manager-operation | host-start | Return the shared Python engine regardless of id. | Native per-plugin interpreters have no shared PythonPluginsEngine object facade. |
| 202 | engineForFile@1447 | partial/manager-operation | import-copy | Select Python engine for .plugin/.py/.elyx/.eaf suffix, otherwise null. | Native accepts .plugin/.py only and returns no engine object. |
| 203 | isPluginEngineAvailable@1459 | partial/manager-operation | host-start | Report Python engine started state. | Native runtime exposes status/isRunning to its owner, not this Java getter. |
| 204 | isPluginEngineSupported@1463 | member-body/availability | runtime-start | Original returns true; native composition explicitly requires main app and available native runtime/account. | No unconditional Java support predicate is installed; support is not readiness or plugin compatibility. |
| 205 | notifyPluginsChanged@1467 | platform-lifecycle/manager-lifecycle | runtime-change | Notify native manager observers after state changes. | NotificationCenter name/payload differs from Android pluginsUpdated; not exported as Java method. |
| 206 | deletePlugin@1472 | partial/manager-operation | remove | Uninstall then callback with null or failed id. | Native async removal exists; no string-callback overload and Android file-deletion Bool semantics differ. |
| 207 | loadPluginSettings@1479 | partial/settings-operation | refresh | Request settings refresh for every installed plugin. | Facade supports only explicit own-plugin id; no no-argument all-plugin refresh operation. |
| 208 | invalidatePluginSettings@1485 | partial/settings-operation | refresh | Delegate settings-screen invalidation for one plugin. | Native refresh exists through supported adapter; exact Java alias is absent. |
| 209 | hasPluginSettings@1489 | partial/settings-operation | py-settings | Serialize settings and test nonempty/non-[] JSON. | No Java facade method; native Plugin.hasSettings reflects loader capability, not this dynamic JSON predicate. |
| 210 | getPluginSettingsPreferences@1494 | partial/storage-operation | settings-get | Return all raw per-plugin preference entries or an empty map for invalid context. | Native typed settings object exists; raw SharedPreferences values and this Java method are absent. |
| 211 | clearPluginSettingsPreferences@1501 | partial/storage-operation | settings-clear,refresh | Clear stored values and invalidate mirror, refreshing only when requested. | Current Controller facade accepts one id only and always refreshes; boolean overload is missing. |
| 212 | getPluginSettingsList@1512 | partial/settings-operation | settings-decode,py-settings | Decode create_settings JSON into a recursive list of values, logging invalid JSON. | Native typed document decoder exists; no generic Java List<Object> getter or swallowed-error semantics. |
| 213 | getSettings@1529 | partial/settings-operation | - | Build plugin-id to settings-list map for every installed plugin. | No native cross-plugin dynamic settings enumeration; layout/backup must not implicitly execute all plugins. |
| 214 | getPluginSettingBoolean@1537 | partial/storage-operation | settings-get | Read Boolean or nonzero Number, otherwise supplied default. | Missing controller Bool coercion facade; typed native store does not implement this Java coercion itself. |
| 215 | getPluginSettingInt@1548 | partial/storage-operation | settings-get | Read Number.intValue or Boolean 1/0, otherwise supplied default. | Missing controller Int coercion facade, including Java narrowing semantics. |
| 216 | getPluginSettingString@1559 | partial/storage-operation | settings-get | Return default for absent value, otherwise Java String.valueOf. | Native typed bulk read is available; this Java stringification/default method is absent. |
| 217 | setPluginSetting@1564 | partial/storage-operation | settings-write,refresh | Convert arbitrary accepted value to JSON, persist and refresh. | Supported settings adapter exists; no exact controller Object overload or arbitrary Java-object serialization. |
| 218 | setPluginSettingAndTriggerOnChange@1568 | partial/settings-operation | settings-change | Persist, reload, notify the registered on_change and additionally call the supplied callback(value). | Host mutation invokes its registered callback; extra supplied-PyObject callback overload is missing. |
| 219 | dispatchSettingsCustomClick@1629 | partial/settings-operation | settings-action,settings-custom-gap | Delegate custom row click/long-click to its factory. | Native manager lacks Custom factory dispatch; generic callback IDs work only through supported row/presenter paths. |
| 220 | getPluginSettingsCustomContent@1635 | partial/settings-operation | ui-custom,settings-custom-gap | Retrieve/build custom setting view or UItem content by view id. | Portable widget materialization exists in SDK presenter; manager custom-content provider is missing. |
| 221 | getPluginSettingsCustomView@1640 | unsupported/android-ui | - | Return custom content only if it is an Android View. | No Android View-returning native operation; portable widget DTOs are a separate representation. |
| 222 | notifySettingChanged@1646 | partial/settings-operation | settings-change | Invalidate cached schema, persist parsed value and call registered setting change handler. | Host operation exists with owner/account/page guard; direct Java alias is absent. |
| 223 | dispatchSettingClick@1653 | partial/settings-operation | settings-click | Dispatch a callback id with the clicked Java view. | Native callback ID path exists but does not pass Android View; direct controller facade is absent. |
| 224 | addSettingsReloadListener@1662 | platform-lifecycle/settings-lifecycle | settings-init | Add a per-plugin reload listener; native settings controller retains a scoped refresh observation. | Native observation token replaces arbitrary Java Runnable listener registration. |
| 225 | removeSettingsReloadListener@1671 | platform-lifecycle/settings-lifecycle | settings-deinit | Remove listener and empty bucket; native teardown revokes page scope and observation ownership. | No Java listener-list manipulation or cross-plugin removal API. |
| 226 | reloadSettingsScreen@1685 | source-routed/settings-operation | settings-refresh-adapter,refresh | Invalidate own SDK settings mirror and notify actual open native settings screens. | Native refresh is owner/account scoped; no Android TTL cache or UI-thread Runnable fanout. |
| 227 | registerSendMessageHook@1698 | partial/hook-operation | send-hook,dispatch | Android checks messages.send and records plugin priority in the send ledger. | Native executes BasePlugin's send ledger; direct controller registration and raw PythonBridge add do not mutate it. |
| 228 | registerRequestHook@1712 | partial/hook-operation | hook-ledger,tl-transform | Partition exact request/update/container or substring hooks and retain maximum matching priority. | Native BasePlugin ledger implements selection; direct Java controller/raw bridge registration is missing. |
| 229 | unregisterRequestHook@1768 | partial/hook-operation | hook-ledger,hook-facade | Remove name from every hook group and invalidate target caches. | Direct facade removal only checks owner; BasePlugin.remove_hook must mutate the actual SDK ledger. |
| 230 | unregisterSendMessageHook@1792 | partial/hook-operation | dispatch,hook-facade | Remove plugin send hook and invalidate send targets. | Direct Java/raw bridge removal does not clear the SDK send-registration flag. |
| 231 | unregisterPluginHooks@1826 | platform-lifecycle/hook-lifecycle | py-cleanup,native-release,ui-release | Unregister all plugin hooks, menus, file/intent handlers and generated classes. | Native unload retires supported leases/ledgers; Java generated-class/Xposed portions are unsupported and no standalone controller method is exposed. |
| 232 | removeHooksByPluginId@1841 | partial/hook-operation | py-cleanup | Remove send/request/update registrations and all Xposed handles for one plugin. | SDK unload clears its ledger; no standalone native all-hook removal command or Xposed operation. |
| 233 | cleanupPlugin@1867 | platform-lifecycle/plugin-lifecycle | py-cleanup,ui-release,native-release | Clear supported hook/resource registrations and invalidate settings during retirement. | Native lifecycle owns cleanup; not a plugin-id-only API for cleaning another live interpreter. |
| 234 | addEventHook@1876 | partial/hook-operation | hook-ledger,send-hook | Route exact send-message hook specially; other registrations use request/substr grouping. | Existing BasePlugin API supplies the ledger; direct Java addEventHook facade is absent. |
| 235 | removeEventHook@1888 | partial/hook-operation | hook-ledger | Select send-hook or named-request removal based on hook name. | Missing direct Java selector/removal route; SDK-specific removal remains required. |
| 236 | executeOnAppEvent@1902 | platform-lifecycle/app-event | app-event,dispatch,watchdog-background | Deliver app lifecycle to loaded interested plugins and clear background/crash-health markers. | Native awaiting event queue/owner checks replace Java engine executor; exact public controller method is not exposed. |
| 237 | hasSendMessageHooks@1940 | partial/hook-state | subscriptions | Test nonempty send ledger; native has typed send subscribers. | Native capability gate can include loaded handler capability before name registration; no exact Java-ledger predicate. |
| 238 | hookName@1946 | partial/helper | hook-ledger | Cache Java Class.getSimpleName for a hook object's class. | Native uses schema canonical/hook-name aliases, not arbitrary Java reflection names. |
| 239 | hasAnyRequestHooks@1957 | partial/hook-state | subscriptions | Test exact request or substring ledger nonemptiness. | Native typed subscriber gate is not the exact registration-map query and no Java facade is provided. |
| 240 | executeOnSendMessageHook@1962 | platform-lifecycle/send-transform | send-hook,dispatch | Run interested plugins in chain, apply compatible modifications, stop on CANCEL or MODIFY_FINAL. | Native uses JSON send snapshots and commit admission, not mutable Java SendMessageParams objects. |
| 241 | executePreRequestHook@1992 | platform-lifecycle/tl-transform | tl-transform,network-transform,dispatch | Resolve request targets, carry valid replacement to later plugins and stop on cancel/final. | Native schema/account/origin rules restrict replacement and cancellation; no arbitrary TLObject cast. |
| 242 | executePostRequestHook@2023 | platform-lifecycle/tl-transform | tl-transform,dispatch | Deliver response plus error and carry validated response modifications through the chain. | Native schema/error DTO and cancellation policy replace Java object/error handles. |
| 243 | hasAnyUpdateHooks@2059 | partial/hook-state | subscriptions | Test exact-update or substring ledger nonemptiness. | Native subscriber gate does not expose this exact Java registry-state predicate. |
| 244 | hasAnyUpdatesContainerHooks@2063 | partial/hook-state | subscriptions | Test updates-container or substring ledger nonemptiness. | Native gate is a typed capability projection, not the Java map query. |
| 245 | executeOnUpdateHook@2068 | platform-lifecycle/tl-transform | tl-transform,dispatch | Resolve cached single-update targets and chain compatible update replacements/cancel/final. | Native update schema and state-application policy are authoritative; not arbitrary TLRPC.Update casting. |
| 246 | executeOnUpdatesHook@2099 | platform-lifecycle/tl-transform | tl-transform,dispatch | Chain updates-container callbacks with replacement/cancel/final semantics. | Native preserves protocol-state invariants and applies only allowed schema transformations. |
| 247 | getMenuItemsFor@2130 | platform-lifecycle/menu-projection | menu-list | Snapshot menu records for a placement and order by descending priority. | Native lease registry supplies owned records; no Java MenuItemRecord list facade. |
| 248 | dispatchMenuClick@2146 | platform-lifecycle/menu-action | menu-action | Resolve plugin/item callback and invoke it with actual menu context while tracking errors/lifetime. | Native requires captured source/owner/account/revision and uses a portable context DTO. |
| 249 | registerMenuItem@2174 | partial/menu-operation | menu-register | Parse menu model, reuse same logical id, replace prior item and retain priority/context callback. | BasePlugin menu route is connected; direct controller/raw PythonBridge.addMenuItem facade is absent. |
| 250 | removeMenuItem@2230 | partial/menu-operation | ui-cleanup | Remove owned menu item and notify registry changes. | BasePlugin uses menuRemove; direct Java Bool-returning controller method is missing. |
| 251 | removeMenuItemsByPluginId@2243 | platform-lifecycle/menu-lifecycle | ui-release | Retire all menu items for the captured retiring plugin generation and update native menus. | Host lifecycle owns bulk retirement; no cross-plugin Java removal capability. |
| 252 | notifyMenuItemsUpdated@2264 | platform-lifecycle/menu-lifecycle | menu-notify | Coalesce repeated menu-change notifications. | Native main-queue coalescing does not promise Android's exact 50 ms debounce. |

### PluginsWatchdog.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 253 | getPluginId@126 | member-body/model | owner | Return ExecutionInfo's plugin attribution; native owner carries pluginId. | Owner capability is immutable and generation-bound, not a Java ExecutionInfo instance. |
| 254 | start@176 | platform-lifecycle/watchdog | watchdog-start | Start watchdog scheduling and execution observation. | Native samples footprint/dispatch deadlines; no Android main-thread budget sweeper. |
| 255 | stop@223 | platform-lifecycle/watchdog | watchdog-stop | Cancel sweeps, clear execution/nonresponse state and remove crash marker. | Native state collections differ; no arbitrary Java thread map is exposed. |
| 256 | notePluginEnter@255 | platform-lifecycle/watchdog | worker | Enter ordinary plugin execution without a risky marker. | Native invocation/mailbox accounting replaces Java nested frame stack. |
| 257 | notePluginEnter@266 | platform-lifecycle/watchdog | worker,watchdog-risk | Track nested execution and optionally mark the active plugin before risky work. | Native marker is generation-bound; Java main-thread nanosecond accounting is unavailable. |
| 258 | onAppBackgrounded@311 | platform-lifecycle/watchdog | watchdog-background | Clear crash attribution on background transition. | Native app lifecycle supplies the transition, not a Java static callback. |
| 259 | noteHealthy@316 | platform-lifecycle/watchdog | watchdog-healthy | Remove accumulated crash strikes for a healthy plugin. | Native watchdog persists its own journal, not SharedPreferences keys. |
| 260 | notePluginExit@327 | platform-lifecycle/watchdog | worker,watchdog-exit | Pop matching frame, finish execution, recover frozen state and defer crash-marker clearing. | No Java main-thread budget accrual; abandoned native workers are not automatically reused. |
| 261 | isNotResponding@437 | platform-lifecycle/watchdog-state | watchdog-frozen | Query native watchdog nonresponse state. | Native timed-out interpreter state replaces scanning frozen Java thread entries. |
| 262 | recoverAfterCrash@537 | partial/watchdog-recovery | watchdog-recover | Read bounded active-plugin marker, increment strikes and disable on the configured threshold. | Native second-strike path exists; Android legacy loading-key migration and exact notice persistence differ. |
| 263 | handlePluginError@599 | platform-lifecycle/watchdog-error | watchdog-error,worker | Diagnose execution failure and finish its invocation accounting. | Native errors are transported to Host state; no Java Throwable stack or direct notePluginExit call. |
| 264 | forceDisablePlugin@611 | partial/watchdog-operation | enabled | Persist disable and stop future plugin execution. | Android forcibly restarts Activity/process; native does not implement that restart effect. |
| 265 | isWarningMuted@631 | partial/watchdog-operation | controls | Read the native manager's muted-warning set. | No Java watchdog object getter; warning preference is distinct from execution limits. |
| 266 | setWarningMuted@636 | partial/watchdog-operation | controls | Native manager can persist warning mute/unmute for one plugin. | No direct Java setter or Android alertedSlow cache reset. |
| 267 | showNotRespondingAlert@659 | partial/watchdog-ui | warning,watchdog-frozen | Present nonresponse warning with disable/mute/cancel choices when unmuted. | Native Runtime owns warning presentation; no Activity overload or forced process restart. |
| 268 | showSlowingDownAlert@682 | partial/watchdog-ui | - | Display main-thread milliseconds-per-second warning with disable and mute actions. | Missing native Java-main-thread slowdown metric/presenter; worker deadlines are not this signal. |
| 269 | getMainThreadMillis@715 | unsupported/android-threading | - | Return accumulated Java main-thread plugin milliseconds. | Python is confined to native interpreter workers; this Android-main-thread metric has no counterpart. |
| 270 | onUncaughtException@720 | unsupported/android-lifecycle | - | Attribute a Java uncaught exception using the existing controller/watchdog. | No Java Throwable/Android uncaught-exception hook; native startup journal does not prove exception attribution. |
| 271 | consumeEarlyCrashLoop@793 | partial/watchdog-recovery | recovery-start | Consume repeated early-crash count once threshold is reached. | Native journal counts unclean starts and separately confirms safe mode; no exact destructive count getter. |
| 272 | scheduleEarlyCrashReset@802 | platform-lifecycle/watchdog-recovery | recovery-healthy | Clear early-start count after healthy process lifetime. | Native uses its own 15-second healthy-start task/background path, not Android elapsed-process time. |
| 273 | consumeAutoSafeMode@811 | partial/watchdog-recovery | recovery-notice | Read-and-remove the automatic-safe-mode notification flag. | Native recovery notice uses explicit acknowledgement rather than destructive Bool getter. |
| 274 | consumeStartupNotice@819 | partial/watchdog-recovery | recovery-notice,manager-runtime | Prefer automatic-safe-mode notice, otherwise crashed-plugin notice. | Native snapshot/acknowledgement UI exists; no exact localized consume-on-read string operation. |
| 275 | consumeCrashedPlugin@836 | partial/watchdog-recovery | recovery-notice | Read-and-remove the attributed crashed plugin id. | Native journal stores/acknowledges recovery notice; no exact consumptive id getter. |
| 276 | getExecutingPlugins@845 | partial/watchdog-state | worker | Return Android's live Thread-to-ExecutionInfo map. | Native worker/mailbox state is private; no raw cross-interpreter thread map provider. |

### PythonBridge.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 277 | getSetting@28 | source-routed/storage-operation | raw-setting-get,settings-values,settings-get | Own-plugin adapter returns the requested value encoded as JSON text, or null when absent. | Raw settings keys/objects are transported as opaque bulk JSON, not interpreted as bridge handles. |
| 278 | setSetting@32 | source-routed/storage-operation | raw-setting-set,settings-set,settings-write,refresh | Decode JSON value, persist one key, invalidate mirror and optionally refresh native settings. | Invalid JSON and native persistence failure propagate instead of silent Android preference failure. |
| 279 | exportSettings@37 | source-routed/storage-operation | settings-get,settings-export | Return original-compatible JSON object containing each setting's encoded JSON text. | Own plugin only; not a file archive or immutable schema receipt. |
| 280 | importSettings@41 | source-routed/storage-operation | settings-write,settings-import,refresh | Merge decoded imported values and optionally notify native settings refresh. | Values must form a valid JSON object; malformed input is rejected. |
| 281 | replaceSettings@46 | source-routed/storage-operation | settings-write,settings-replace | Replace all stored values after decoding the compatibility envelope. | Own-plugin atomic replacement; no global/native client settings namespace. |
| 282 | log@52 | source-routed/log-operation | raw-log,log-wire,log | Format plugin message and append it through native Runtime.log. | Native log buffer replaces Android FileLog/AppUtils broadcast destinations. |
| 283 | logStream@58 | source-routed/log-operation | raw-log-stream,log-event | PythonBridge.logStream checks own id then sends level/message with sdk phase to native logEvent. | Native severity/length validation applies; rotating Android log files are not implied. |
| 284 | addRequestHook@64 | partial/hook-operation | hook-facade,hook-ledger | Original mutates request/update/substr ledger via controller; normal BasePlugin registration mutates the native-consumed SDK ledger. | Direct Platform.addRequestHook only checks owner, so this public Java call alone is inert. |
| 285 | addSendMessageHook@68 | partial/hook-operation | dispatch | Original inserts send-hook priority; native dispatch reads BasePlugin's send-registration flag. | Direct facade checks owner but does not set that flag or native priority registration. |
| 286 | removeRequestHook@72 | partial/hook-operation | hook-facade,hook-ledger | Original removes named registration from controller groups. | Direct facade leaves SDK _exteraless_request_hooks unchanged; BasePlugin removal is required. |
| 287 | removeSendMessageHook@76 | partial/hook-operation | dispatch | Original unregisters the send hook. | Direct facade leaves the SDK send-registration flag unchanged. |
| 288 | addMenuItem@83 | partial/menu-operation | menu-register | Original parses JSON menu and returns logical item id through controller. | Native BasePlugin.add_menu_item works, but Platform has no raw addMenuItem facade accepting this JSON/PyObject signature. |
| 289 | removeMenuItem@88 | partial/menu-operation | ui-cleanup | Original removes the plugin/item id through controller. | Native BasePlugin removal is wired; raw PythonBridge.removeMenuItem is not supplied by Platform. |
| 290 | hasPermission@94 | source-routed/permission-operation | raw-permission,permission | Check exact own plugin id and return strict native hasPermission Bool. | Effective trust-cap difference remains in native grants; unknown/broken native queries do not grant permission. |
| 291 | checkPermission@98 | partial/permission-operation | raw-check,permission | Adapter returns the own-plugin permission decision. | Platform.checkPermission ignores what and does not reproduce Android denial logging/notices. |
| 292 | noteOverlayDenied@102 | unsupported/android-ui | - | Request Android overlay-denial prompt. | No SYSTEM_ALERT_WINDOW settings/prompt provider; method is not emulated. |
| 293 | isUnsafeMode@106 | source-routed/permission-operation | raw-unsafe,unsafe | Return strict native unsafe-mode Bool. | Read-only query; no claim of a public unsafe-mode setter. |
| 294 | getPluginsDir@111 | source-routed/storage-operation | raw-directory,directory | Return native plugin directory as an absolute path and verify it matches configured root. | Android filesystem layout is not retained. |
| 295 | getSdkVersion@116 | member-body/model | sdk-version | Original returns PluginsConstants.SDK_VERSION; Python facade explicitly returns 1.4.5.7. | SDK version constant, not native app version or whole-SDK parity. |
| 296 | reloadSettingsScreen@121 | source-routed/settings-operation | settings-refresh-adapter,refresh | Invalidate own SDK mirror and notify actual native settings refresh. | Requires active owner/account UI; no Android listener object transfer. |

### PythonPluginsEngine.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 297 | getPluginInstances@47 | partial/manager-operation | py-instance | Return the backing concurrent map of loaded Python objects. | Native interpreter-local SDK can retrieve its own instance; no cross-interpreter PyObject map provider. |
| 298 | getInstance@51 | platform-lifecycle/engine-lifecycle | host-start | Android lazily creates a shared Python engine; native application owns a single Host with isolated plugin workers. | No shared Chaquopy PythonPluginsEngine object facade. |
| 299 | runOnEngine@75 | platform-lifecycle/engine-lifecycle | worker | Enqueue engine work; native executes on the captured interpreter mailbox. | No arbitrary global Runnable executor or Python-on-main execution. |
| 300 | isStarted@79 | partial/engine-state | host-start | Read the engine-started flag. | Native isRunning/startup state belongs to Host; no direct Java engine Bool getter. |
| 301 | pluginFromPythonStack@90 | partial/attribution-helper | owner | Ask loader to attribute the current Python frame, returning null on failure. | Native immutable C owner replaces stack guessing; no Java stack-attribution operation exported. |
| 302 | debugPythonStacks@102 | partial/diagnostic-operation | - | Ask loader for Python thread-stack diagnostics when started. | Stock SDK debug_python_stacks exists, but no captured-owner native/Java diagnostic entry exposes it. |
| 303 | ensureStarted@114 | platform-lifecycle/engine-lifecycle | runtime-start,host-start | Start Python/bootstrap loader, set scheduling policy and conditionally start development service. | Native CPython bootstrap/loopback service differs from AndroidPlatform, UI thread pinning and Chaquopy singleton. |
| 304 | scanCapabilitiesJson@154 | partial/source-analysis | scan | Return stock scanner capability JSON for a source path when engine is started. | No native manager engine method/captured inspector route for this Java entry. |
| 305 | setUnsafeMode@166 | partial/permission-operation | - | Host-only push of unsafe mode into loader after engine start. | Missing composed native unsafe-mode persistence/update operation; native permission query remains separate. |
| 306 | getAuditJournalJson@183 | partial/audit-operation | audit-list | Return at most 100 Python audit events as JSON. | Stock SDK journal exists; no native manager/Java engine read route. |
| 307 | getAuditProfileJson@196 | partial/audit-operation | audit-profile | Return Python audit category counters as JSON. | No actual native manager audit-profile operation/export. |
| 308 | forgetAudit@209 | partial/audit-operation | audit-clear | Gate caller, clear Java audit store then clear Python audit data. | SDK own-data cleanup exists; no merged native/Java audit erase operation. |
| 309 | readMetadataJson@230 | platform-lifecycle/metadata-operation | metadata | Read metadata JSON using AST parser without executing plugin body. | Native isolated inspector returns typed Plugin/errors, not the shared Java engine nullable string API. |
| 310 | loadPlugin@245 | platform-lifecycle/engine-lifecycle | host-load,watchdog-risk | Clear cached settings, mark risky entry and load/remember plugin instance. | Native binds owner before SDK load and isolates interpreters; Java sink hooks and shared instance map are absent. |
| 311 | loadPlugins@297 | partial/manager-operation | - | Despite its name, original only rescans plugins and invokes callback if Runnable. | No native directory-rescan/callback operation; Host startup loading is not this body. |
| 312 | unload@313 | platform-lifecycle/engine-lifecycle | host-unload,py-cleanup | Mark the exact plugin as unloading, call unloadPlugin and clear that marker in finally. | Native retirement is handle/generation-bound rather than a Java unloadingPlugins map. |
| 313 | unloadPlugin@330 | platform-lifecycle/engine-lifecycle | host-unload,py-cleanup | Resolve unloading plugin, drop settings cache, invoke unload callback, clear loaded/instance state and notify menus. | Native SDK cleanup runs on captured worker; no shared-engine id retargeting or Java object handles. |
| 314 | uninstallPlugin@372 | platform-lifecycle/engine-lifecycle | remove,py-cleanup | Run loader uninstall cleanup for the gated plugin. | Native Host owns source/model/grants removal; direct Java loader-only API is absent. |
| 315 | callAppEvent@388 | platform-lifecycle/app-event | app-event,dispatch | Call SDK app-event handler for the selected plugin and event. | Native event names are validated and dispatch uses captured owner; no direct public Java engine invocation. |
| 316 | callSendMessageHook@392 | platform-lifecycle/send-transform | send-hook,dispatch | Invoke SDK send callback with account/params and decode HookResult. | Native JSON snapshot/replacement semantics replace arbitrary Java params. |
| 317 | callPreRequestHook@397 | platform-lifecycle/tl-transform | tl-transform,dispatch | Invoke pre-request callback with actual account/name/request and decode strategy/value. | Native schema DTO and origin/cancellation guard govern execution. |
| 318 | callPostRequestHook@402 | platform-lifecycle/tl-transform | tl-transform,dispatch | Invoke post-request with response and error, then decode hook decision. | Error/response are schema DTOs, not Chaquopy object references. |
| 319 | callUpdateHook@407 | platform-lifecycle/tl-transform | tl-transform,dispatch | Invoke the selected single-update hook with its account and name. | Native schema/state-policy validation remains authoritative. |
| 320 | callUpdatesHook@412 | platform-lifecycle/tl-transform | tl-transform,dispatch | Invoke the selected updates-container hook and decode its decision. | Native does not expose arbitrary mutable Android Updates objects. |
| 321 | invalidateSettingsJson@423 | platform-lifecycle/settings-cache | py-mirror,refresh | Drop cached settings JSON so the next settings read refreshes. | Native display/schema invalidation replaces Android time-to-live cache; no exact Java entry. |
| 322 | getSettingsJson@433 | platform-lifecycle/settings-operation | settings-read,py-settings | Call create_settings and serialize rows; Android also caches briefly and wraps watchdog entry. | Native reads pin owner/account/page before queueing; no identical shared Java TTL cache or null-on-error contract. |
| 323 | getSettingsCustomView@458 | unsupported/android-ui | - | Return custom content only when it is an Android View. | Native portable widgets do not supply android.view.View objects. |
| 324 | getSettingsCustomContent@464 | partial/settings-operation | ui-custom,settings-custom-gap | Build custom view/factory content and attach its setting to a UItem when applicable. | SDK portable widget presenter works; native manager custom factory/content materialization is missing. |
| 325 | dispatchSettingsCustomClick@497 | partial/settings-operation | settings-click,settings-custom-gap | Resolve CustomSetting factory and dispatch its click or long click under watchdog tracking. | Native opaque callback-ID route does not provide manager CustomSetting.Factory/UItem dispatch. |
| 326 | notifySettingChanged@522 | platform-lifecycle/settings-operation | settings-change | Drop cached schema, persist JSON value and invoke registered change callback. | Native Host pins expected owner/account/action permit; no Java engine-object method. |
| 327 | invalidateSettingsMirror@527 | platform-lifecycle/settings-cache | py-mirror | Drop settings JSON and invalidate BasePlugin/module mirrors. | SDK interpreter-local mirror operation, not cross-interpreter Java cache mutation. |
| 328 | dispatchSettingClick@539 | partial/settings-operation | settings-click | Drop cached schema and invoke callback id with clicked view. | Native callback invocation omits Android View; extra view-dependent plugin behavior is unavailable. |

### PythonThreadState.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 329 | pinCurrentThread@17 | platform-lifecycle/interpreter-thread | worker | Pin Chaquopy thread state once Python has started; native interpreter mailbox owns its dedicated C thread state. | No arbitrary/current-main-thread Chaquopy pinning method. |
| 330 | onCall@29 | platform-lifecycle/interpreter-thread | worker | Count Java-to-Python calls and pin after the threshold. | Native dedicated worker needs no threshold heuristic; no same Java ThreadLocal counter. |

### SignedGrantPreferences.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 331 | getAll@165 | partial/grant-storage | grants-read | Return preference entries excluding signature keys and invalid signed grant values. | Native typed grants.json has no signed-entry validation/filtering or arbitrary preference map. |
| 332 | getString@180 | partial/grant-storage | grants-read | Return stored String only when non-null and signature-valid, otherwise default. | Missing signed String grant/preference getter; native enum arrays are not this primitive store. |
| 333 | getStringSet@186 | partial/grant-storage | grants-read | Return default for grant keys, delegate StringSet reads only for non-grant keys. | Native has no equivalent mixed signed/non-grant StringSet API. |
| 334 | getInt@191 | partial/grant-storage | - | Require key presence and valid signature before returning Int, otherwise default. | Missing native signed Int preference read, including trust levels. |
| 335 | getLong@200 | partial/grant-storage | - | Require presence and valid signature before returning Long/default. | Missing native signed Int64 preference operation. |
| 336 | getFloat@209 | partial/grant-storage | - | Require presence and valid signature before returning Float/default. | Missing native signed Float preference operation. |
| 337 | getBoolean@218 | partial/grant-storage | unsafe | Return present signature-valid Boolean or supplied default. | Native unsafe Bool query is not a signed arbitrary-key getter. |
| 338 | contains@227 | partial/grant-storage | grants-read | For grant keys, count presence only when the stored value validates; ordinary keys use delegate presence. | Native grant-map presence lacks per-entry signature/seal validation. |
| 339 | edit@239 | partial/grant-storage | - | Construct a SignedEditor wrapping the underlying preference editor. | No native transaction/editor object for this signed preference format. |
| 340 | registerOnSharedPreferenceChangeListener@244 | partial/grant-storage | - | Delegate preference-change listener registration. | Missing signed-store native listener API; Runtime state notifications are not arbitrary preference callbacks. |
| 341 | unregisterOnSharedPreferenceChangeListener@249 | partial/grant-storage | - | Delegate preference-change listener removal. | No corresponding registered signed-store listener token/provider. |
| 342 | putString@274 | partial/grant-storage | grants-write | Stage String value and signature, or remove value/signature for null. | Native typed grant replacement does not sign arbitrary String keys. |
| 343 | putStringSet@280 | partial/grant-storage | - | Stage a StringSet only for non-grant keys and return the same editor. | Missing mixed preference editor and fluent Java reference semantics. |
| 344 | putInt@288 | partial/grant-storage | - | Stage Int and its grant signature, returning the editor. | No native signed trust-level/arbitrary Int editor operation. |
| 345 | putLong@294 | partial/grant-storage | - | Stage Long and signature, returning the same editor. | No native signed Int64 editor operation. |
| 346 | putFloat@300 | partial/grant-storage | - | Stage Float and signature. | No native signed Float preference writer. |
| 347 | putBoolean@306 | partial/grant-storage | - | Stage Boolean and its signature. | No native signed arbitrary-key Boolean/unsafe-mode editor. |
| 348 | remove@312 | partial/grant-storage | grants-clear | Remove value and its signature when the key is a grant. | Native grant deletion exists only by plugin id and has no corresponding signature entry. |
| 349 | clear@321 | partial/grant-storage | - | Clear all staged preferences but restore the sealed marker. | No native signed-preference clear/seal operation. |
| 350 | commit@328 | partial/grant-storage | grants-write | Commit the wrapped editor synchronously and return its persistence Bool. | Native grant writer has no SignedEditor commit result or HMAC format. |
| 351 | apply@333 | partial/grant-storage | grants-write | Apply staged signed preferences asynchronously. | Native grant persistence is not Android SharedPreferences asynchronous apply semantics. |

### files/FilesControllerJava.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 352 | register@72 | partial/file-operation | file-register | Delegate registration with null onClick callback. | Native SDK requires callable on_click; this no-callback Java registration is unavailable. |
| 353 | register@82 | partial/file-operation | file-register | Normalize extension, prevent another owner taking it, replace own handler and return secret id. | Actual SDK PluginServices path is connected; FilesControllerJava class/method itself is not registered. |
| 354 | unregister@101 | partial/file-operation | native-cleanup | Validate extension/plugin/secret before removing the matching handler. | SDK native-id revoke exists, but direct Java class/secret API is absent and SDK unknown ids raise. |
| 355 | unregisterAllForPlugin@115 | platform-lifecycle/file-lifecycle | native-release | Remove all file-handler registrations at plugin retirement. | Native captured-lease cleanup replaces plugin-id-only Java collection removal. |
| 356 | isIconsSupported@122 | member-body/availability | file-icons | Original returns false and native explicitly rejects icon factories. | No Android icon provider is promised; direct FilesControllerJava facade is absent. |
| 357 | hasHandlers@129 | partial/file-state | file-match | Test whether any file handler exists. | Native can test a particular filename; no public all-handler Bool enumeration method. |
| 358 | dispatchOpenFile@142 | platform-lifecycle/file-open | file-open,file-context | Build filename/path/file/MIME/account/place/message context and invoke extension handler. | Native only intercepts composed chat-document site; Activity/parent_fragment are null and message is a bounded DTO. |
| 359 | dispatchOpen@177 | platform-lifecycle/file-open | file-dispatch | Match extension/filename filters, invoke callback once and treat successful return as handled. | Native async barrier/owner control replaces Java synchronous Bool; arbitrary successful Python return values are ignored. |

### intents/IntentsDispatcher.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 360 | registerHandler@89 | partial/intent-operation | intent-register | Parse schemes/hosts/template/query/categories/flags and insert descending-priority before/after handler. | Native SDK PluginServices path exists; direct class export is absent and unsupported Android-only filters fail early. |
| 361 | unregisterHandler@137 | partial/intent-operation | native-cleanup | Remove matching plugin/id handler. | Native revoke is captured-owner bound; direct IntentsDispatcher method is not exposed. |
| 362 | unregisterAllForPlugin@144 | platform-lifecycle/intent-lifecycle | native-release | Retire all URL/intent registrations owned by the unloaded plugin generation. | No public cross-plugin id-only removal capability. |
| 363 | hasHandlers@153 | partial/intent-state | intent-dispatch | Test nonempty handler registry. | Native internal barrier has registrations, but no matching public Java predicate/provider. |
| 364 | hasBeforeHandlers@157 | partial/intent-state | intent-dispatch | Test whether any before handler is registered. | No direct native before-handler enumeration Bool. |
| 365 | hasAfterHandlers@166 | partial/intent-state | intent-after | Test whether any after handler is registered. | No direct native after-handler enumeration Bool. |
| 366 | dispatchBefore@178 | platform-lifecycle/intent-open | intent-open,intent-dispatch | Invoke matching before handlers in priority order until one consumes the opening. | Native requires strict Bool result and asynchronous controlled callback; no arbitrary Android Intent object. |
| 367 | dispatchAfter@203 | platform-lifecycle/intent-open | intent-after | Invoke matching after handlers, discarding callback results. | Native after phase follows the actual original-open continuation and rechecks captured lease authority. |
| 368 | buildIntentContext@227 | partial/intent-model | intent-context | Preserve from_intent/account plus action/flags/type/categories/data and parsed URI fields. | Native URL sites only produce supported ACTION_VIEW data; Java Intent object/hardware dispatch is not supplied. |
| 369 | buildUriContext@262 | member-body/intent-model | intent-context | Build URL context with ACTION_VIEW, zero flags, empty categories and parsed URI fields. | Native bounded URLComponents parsing/DTO, not android.net.Uri object identity. |

### menus/MenuInjector.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 370 | releaseMessageMenu@87 | platform-lifecycle/menu-lifecycle | menu-render | Clear message-menu context/entries only when owned by the closing fragment. | Native context-menu closures weakly retain source and recheck it; no static Java fragment cache. |
| 371 | isVisible@106 | partial/menu-condition | menu-condition | Compile/cache safe read-only condition and evaluate against menu context, hiding on failure. | Native supports an explicit bounded expression grammar; arbitrary MVEL functions/reflection are unsupported. |
| 372 | resolveIcon@165 | partial/resource-operation | image | Resolve named icon for menu display. | Native accepts semantic bundle/SF Symbol names, not Android drawable resource identifiers or integer zero fallback. |
| 373 | fillMessageMenu@193 | platform-renderer/menu-renderer | menu-render,menu-context | Build actual message/chat/user/account context and expose available plugin menu items. | Native ContextMenuItem adaptation replaces Android icons/items/options parallel arrays and submenu grouping. |
| 374 | expandMessagePluginsOption@244 | platform-renderer/menu-renderer | menu-render | Replace Android plugin submenu placeholder with visible concrete menu actions. | Native constructs context actions directly; no Android option-index mutation. |
| 375 | createMessagePluginsMenu@272 | platform-renderer/menu-renderer | menu-render | Create a message-plugin submenu with context and closing callback. | Native ContextMenu items replace PopupSwipeBackLayout/PluginsMenuWrapper View. |
| 376 | closeMenu@278 | platform-lifecycle/menu-action | menu-render | Anonymous wrapper invokes its captured closeMenu Runnable. | Native menu action dismisses its own ContextController before invoking the plugin; no Java Runnable export. |
| 377 | handleMessageMenuOption@290 | platform-lifecycle/menu-action | menu-action | Translate an Android option index to stored record/context and dispatch that item. | Native uses lease UUID/revision rather than integer option-base arithmetic. |
| 378 | appendDrawerItems@310 | platform-renderer/menu-renderer | menu-rows | Add visible drawer plugin rows, close the drawer and invoke callback with actual account. | Native grouped rows replace LinearLayout/DrawerMenuItemView and Android customization guard. |
| 379 | refresh@374 | platform-renderer/menu-renderer | menu-list,menu-notify | Rebuild submenu when items exist and update its visibility. | Native projects current registry via coalesced notifications; no ActionBarMenuItem object. |
| 380 | attachSwipeBackMenu@383 | platform-renderer/menu-renderer | menu-render | Reuse/rebuild submenu for the same header host and attach visible plugin actions. | Native chat/profile menu insertion is a counterpart role, not Android swipe-back popup recreation. |
| 381 | closeMenu@403 | platform-lifecycle/menu-action | menu-render | Anonymous header wrapper toggles the owning submenu closed. | Native context-menu dismissal replaces ActionBarMenuItem.toggleSubMenu. |
| 382 | mainMenuItems@431 | platform-renderer/menu-renderer | menu-rows,menu-list | Combine MAIN_MENU and DRAWER_MENU, evaluate conditions and retain account/source for actions. | Native explicitly includes drawer placement in main; returns native rows/actions, not MainMenuHelper objects. |
| 383 | appendMainMenuItems@461 | platform-renderer/menu-renderer | menu-rows | Add grouped plugin entry when visible items exist and Android layout has not already placed it. | Native insertion uses its own menu layout; no ItemOptions/MainMenuLayout object contract. |

### menus/PluginsMenuWrapper.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 384 | getSwipeBack@88 | platform-renderer/menu-renderer | menu-render | Return the wrapper's swipe-back content view. | Native menu items have no equivalent LinearLayout return object. |
| 385 | hasItems@93 | platform-renderer/menu-state | menu-list | Test whether current filtered menu items are nonempty. | Native source/owner/placement filtering replaces Java wrapper state. |
| 386 | closeMenu@102 | member-body/lifecycle-hook | menu-render | Original base hook is intentionally empty; subclasses provide close behavior. | Native dismissal belongs to the action's ContextController; no claim of a missing original effect. |
| 387 | rebuildMenu@109 | platform-renderer/menu-renderer | menu-render | Rebuild visible action rows with title/icon/subtext, heights and close-then-click behavior. | Native menu typography/layout and UUID callbacks replace Android child Views and dp heights. |
| 388 | onNestedScroll@203 | platform-renderer/menu-layout | list-layout | Delegate scrolling and redraw when the content becomes vertically scrollable. | Native scroll/inset rendering is a counterpart role; no exact Android nested-scroll callback/visual parity. |

### models/CustomSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 389 | create@31 | member-body/factory-hook | factory-build | Original base Factory.create returns null; a subclass is expected to supply UItem content. | SDK create/bind factory is the portable counterpart; no Android UItem subclass dispatch or default content is invented. |
| 390 | onClick@35 | member-body/factory-hook | custom-click | Original factory click hook is empty; optional SDK Custom.on_click stores the corresponding action. | No default click effect; manager Custom factory dispatch remains unavailable. |
| 391 | onLongClick@38 | member-body/factory-hook | custom-long | Original factory long-click hook is empty; SDK keeps an optional long-action callable. | No default long-click effect or Java UItem/View callback. |
| 392 | isShadow@42 | partial/model | factory-shadow | Return factory shadow flag; SDK SimpleSettingFactory stores is_shadow. | The flag is data; portable native renderer does not implement arbitrary Android shadow-factory semantics. |
| 393 | isClickable@47 | member-body/model | factory-clickable | Return factory clickability flag; mapped to SDK is_clickable. | Does not by itself install a native action or make an Android factory callable. |
| 394 | isShadowValue@51 | partial/model | factory-shadow | Read the backing shadow flag directly. | SDK retains the flag, but native shadow rendering/factory method is not supplied. |
| 395 | setShadowValue@55 | partial/model | factory-shadow | Assign the factory shadow flag. | Data mutation does not create a native shadow-row provider. |
| 396 | isClickableValue@59 | member-body/model | factory-clickable | Read the factory clickability value. | Value-only counterpart; native action admission remains separate. |
| 397 | setClickableValue@63 | member-body/model | factory-clickable | Assign the factory clickability value. | No Java method export or immediate native row update. |
| 398 | cleanup@100 | platform-lifecycle/settings-resource | py-cleanup | Close/null own click/subpage/factoryArgs references plus inherited long callback. | Native SDK clears records and owned leases on retirement; no PyObject.close object emulation. |
| 399 | getOnClickCallback@110 | member-body/model | custom-click | Return stored custom click callable reference. | Callback remains interpreter-local; native receives an opaque callback id/lease, not PyObject. |
| 400 | setOnClickCallback@114 | member-body/model | custom-click | Replace the stored custom click callable. | Model assignment alone does not refresh an admitted native callback map. |
| 401 | getCreateSubFragmentCallback@118 | member-body/model | custom-subpage | Return stored subpage-creation callable. | Native rows contain materialized sub_page data, not a callable Java fragment factory. |
| 402 | setCreateSubFragmentCallback@122 | member-body/model | custom-subpage | Replace subpage factory callback reference. | Schema must be rebuilt before native subpage content changes. |
| 403 | getFactoryArgs@126 | member-body/model | custom-args | Return factory argument object. | SDK tuple/value arguments replace Chaquopy PyObject identity. |
| 404 | setFactoryArgs@130 | member-body/model | custom-args | Assign factory argument object. | No arbitrary Java-object argument bridge or automatic factory execution. |
| 405 | getFactory@134 | member-body/model | custom-factory | Return associated custom factory reference. | Only SDK portable view factories can materialize native content. |
| 406 | setFactory@138 | member-body/model | custom-factory | Assign the custom factory reference. | Generated Android Factory subclasses remain unsupported. |
| 407 | getItem@142 | partial/model | custom-item | Return the retained UItem. | SDK item/view descriptor exists; no native UItem object or manager custom-item getter. |
| 408 | setItem@146 | partial/model | custom-item | Store a UItem as custom content. | Portable descriptor can be retained; arbitrary Android UItem cannot be rendered or bridged. |

### models/DividerSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 409 | getText@12 | member-body/model | settings-text | Return divider text; native maps it to section footer text. | Nullable value mapping, not Android DividerSetting class export. |
| 410 | setText@16 | member-body/model | settings-text | Assign divider text for next schema serialization. | Native immutable row is replaced on refresh rather than mutated through a Java setter. |

### models/EditTextSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 411 | cleanup@28 | platform-lifecycle/settings-resource | py-cleanup | Close/null onChange and inherited long-click references. | Interpreter-local record/lease cleanup replaces PyObject.close. |
| 412 | getKey@34 | member-body/model | settings-key | Return edit-text persistence key. | Typed row field, not a storage read. |
| 413 | setKey@38 | member-body/model | settings-key | Assign edit-text key. | Requires new validated row publication; does not rename persisted data. |
| 414 | getHint@42 | member-body/model | settings-hint | Return edit-text hint. | Native field mapping only. |
| 415 | setHint@46 | member-body/model | settings-hint | Assign edit-text hint. | Native display changes on schema/model refresh, not Java object mutation. |
| 416 | getDefaultValue@50 | member-body/model | settings-default | Return default String for edit-text input. | Default is data, not necessarily current stored value. |
| 417 | setDefaultValue@54 | member-body/model | settings-default | Assign edit-text default String. | Does not overwrite native persisted setting. |
| 418 | getMultiline@58 | member-body/model | settings-multiline | Return multiline editing flag. | Native input control semantics replace Android EditText behavior. |
| 419 | setMultiline@62 | member-body/model | settings-multiline | Assign multiline flag for input schema. | No arbitrary Android input widget mutation. |
| 420 | getMaxLength@66 | partial/model | settings-length | Read Android maximum-length integer. | Native optional bound and Unicode-scalar input limit differ from Android UTF-16/InputFilter semantics. |
| 421 | setMaxLength@70 | partial/model | settings-length | Assign maximum-length integer. | Native validates nonnegative limits; negative Java values are not blindly preserved. |
| 422 | getMask@74 | partial/model | edit-mask | Return stored text mask declaration. | SDK carries mask, but native manager/portable widget parser has no mask formatter operation. |
| 423 | setMask@78 | partial/model | edit-mask | Assign edit-text mask. | Missing native mask application/formatting provider; assignment is only SDK data. |
| 424 | getOnChangeCallback@82 | member-body/model | edit-change | Return retained edit-text change callable. | Native receives validated key/value callback flow, not PyObject reference. |
| 425 | setOnChangeCallback@86 | member-body/model | edit-change | Replace edit-text change callable in the model. | Callback ledger is rebuilt by settings serialization; no immediate native replacement implied. |

### models/HeaderSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 426 | getText@18 | member-body/model | settings-text | Return header text; native section title is its rendering role. | No Android header-cell identity. |
| 427 | setText@22 | member-body/model | settings-text | Assign header text for future schema publication. | Native sections update through document refresh. |

### models/InputSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 428 | cleanup@25 | platform-lifecycle/settings-resource | py-cleanup | Close/null input onChange and inherited long callback. | SDK record/lease retirement, not Java PyObject lifetime API. |
| 429 | getKey@31 | member-body/model | settings-key | Return input persistence key. | Field read only. |
| 430 | setKey@35 | member-body/model | settings-key | Assign input persistence key. | Does not migrate existing stored value. |
| 431 | getText@39 | member-body/model | settings-text | Return input row label. | Native row text mapping only. |
| 432 | setText@43 | member-body/model | settings-text | Assign input row label. | A new native row snapshot is required for display change. |
| 433 | getDefaultValue@47 | member-body/model | settings-default | Return nullable default input String. | Distinct from stored current value. |
| 434 | setDefaultValue@51 | member-body/model | settings-default | Assign nullable default input String. | Does not persist user setting. |
| 435 | getSubtext@55 | member-body/model | settings-subtext | Return explanatory input subtext. | No rendering/effect performed by getter. |
| 436 | setSubtext@59 | member-body/model | settings-subtext | Assign explanatory input subtext. | Native immutable row refresh replaces direct View mutation. |
| 437 | getOnChangeCallback@63 | member-body/model | input-change | Return optional input change callable. | Interpreter-local callable, native callback ids are separate. |
| 438 | setOnChangeCallback@67 | member-body/model | input-change | Assign optional input change callable. | Settings serialization/admission owns its eventual invocation. |

### models/PluginItemFactory.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 439 | getInstance@24 | partial/factory-operation | factory-instance | Android returns/setup singleton UItemFactory; SDK exposes its concrete PluginItemFactory facade. | SDK getInstance creates a facade value; no Android singleton/setup identity. |
| 440 | create@36 | partial/factory-operation | factory-create,custom-model | Store Python factory/args and clickability as custom setting content. | SDK returns Custom descriptor, not UItem with object/object2 fields; manager Custom rendering is incomplete. |
| 441 | createView@62 | platform-renderer/settings-renderer | widget-container | Create a match-width/wrap-height container for custom content. | Native container constraints replace Android FrameLayout/RecyclerView parameters. |
| 442 | bindView@72 | partial/settings-renderer | factory-build,ui-custom | Invoke build_view, retain matching child, otherwise detach old parent and attach rebuilt view. | Portable SDK widget path exists; no Android View reparenting or native manager Custom bindView implementation. |
| 443 | isShadow@101 | member-body/factory-policy | factory-shadow | Original factory policy returns false. | Native no-shadow default is a rendering policy; SDK flag declaration does not guarantee custom shadow effects. |
| 444 | isClickable@106 | partial/factory-policy | factory-clickable | Original factory policy returns true even though individual items carry their own enabled flag. | SDK/native use per-descriptor action availability; no identical UItemFactory policy method. |
| 445 | equals@111 | partial/renderer-identity | settings-decode | Compare UItem id and factory-object identity. | Native stable row identifiers replace object identity; no exact comparator. |
| 446 | contentsEquals@116 | platform-renderer/renderer-invalidation | list-sections | Original always returns false to force rebinding. | Native refresh reloads section snapshots; no Android adapter comparator is called. |

### models/SelectorSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 447 | cleanup@25 | platform-lifecycle/settings-resource | py-cleanup | Close/null selector change callable and inherited long callback. | SDK owned-record cleanup replaces PyObject.close. |
| 448 | getKey@31 | member-body/model | settings-key | Return selector persistence key. | Not a settings-store read. |
| 449 | setKey@35 | member-body/model | settings-key | Assign selector key. | Does not rename stored settings. |
| 450 | getText@39 | member-body/model | settings-text | Return selector label. | Native value projection only. |
| 451 | setText@43 | member-body/model | settings-text | Assign selector label. | Requires schema refresh for display. |
| 452 | getDefaultValue@47 | member-body/model | settings-default | Return default selected option index. | Default is not a fabricated current selection. |
| 453 | setDefaultValue@51 | member-body/model | settings-default | Assign default selector index. | Native document validates numeric integral selection; no automatic persistence. |
| 454 | getItems@55 | member-body/model | settings-items | Return option strings. | Swift/SDK value arrays replace Java String[] reference identity. |
| 455 | setItems@59 | member-body/model | settings-items | Assign selector option array. | Native bounds limit options; display updates through new row data. |
| 456 | getOnChangeCallback@63 | member-body/model | selector-change | Return optional selector change callable. | Native callback carries validated selected index, not PyObject. |
| 457 | setOnChangeCallback@67 | member-body/model | selector-change | Assign selector change callable. | Ledger refresh/admission is separate from data assignment. |

### models/SettingItem.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 458 | cleanup@26 | platform-lifecycle/settings-resource | py-cleanup | Close and null retained long-click callback. | Native interpreter-record/lease retirement replaces Java close method. |
| 459 | getLink@41 | partial/navigation-helper | row-alias | Return null for missing plugin/alias; otherwise build p/s URL with optional prefix:alias. | SDK retains aliases, but original link generation/resolution has no native provider. |
| 460 | getType@49 | member-body/model | settings-kind | Return the stored setting type discriminator. | Native parser supports its explicit kinds, not arbitrary renderer classes. |
| 461 | setType@53 | member-body/model | settings-kind | Assign setting type discriminator. | Unknown types remain unsupported at native rendering/admission. |
| 462 | getIcon@57 | member-body/model | row-icon | Return optional semantic icon string. | No Android numeric drawable object is returned. |
| 463 | setIcon@61 | member-body/model | row-icon | Assign semantic icon string for row serialization. | Native resource resolver must recognize it; assignment alone does not load an image. |
| 464 | getOnLongClickCallback@65 | member-body/model | settings-long,custom-long | Return retained long-action callable; native row stores its opaque callback id. | Callable stays interpreter-local and requires current row/owner admission. |
| 465 | setOnLongClickCallback@69 | member-body/model | settings-long,custom-long | Assign retained long-action callable before callback-ledger serialization. | No direct native PyObject field or immediate UI callback replacement. |
| 466 | getLinkAlias@73 | partial/model | row-alias | Return stored row alias. | SDK has link_alias; manager PluginSetting does not retain/resolve the original alias. |
| 467 | setLinkAlias@77 | partial/model | row-alias | Assign row link alias. | Missing manager alias navigation; SDK presenter can only project its local id field. |

### models/SwitchSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 468 | cleanup@25 | platform-lifecycle/settings-resource | py-cleanup | Close/null switch onChange and inherited long callback. | Native record/lease retirement, not Java PyObject.close. |
| 469 | getKey@31 | member-body/model | settings-key | Return switch persistence key. | Field read only. |
| 470 | setKey@35 | member-body/model | settings-key | Assign switch key. | Does not change stored value or rename storage. |
| 471 | getText@39 | member-body/model | settings-text | Return switch row label. | Native row-model projection only. |
| 472 | setText@43 | member-body/model | settings-text | Assign switch row label. | Requires refreshed native row snapshot. |
| 473 | getDefaultValue@47 | member-body/model | settings-default | Return default switch Bool. | Native currentValue prefers stored value over default. |
| 474 | setDefaultValue@51 | member-body/model | settings-default | Assign default switch Bool. | No persistence or toggle action occurs. |
| 475 | getSubtext@55 | member-body/model | settings-subtext | Return switch explanatory subtext. | Field read, not rendered-frame proof. |
| 476 | setSubtext@59 | member-body/model | settings-subtext | Assign switch explanatory subtext. | Model replacement/refresh owns native display updates. |
| 477 | getOnChangeCallback@63 | member-body/model | switch-change | Return switch change callable. | Native invokes it through validated key/Bool callback flow. |
| 478 | setOnChangeCallback@67 | member-body/model | switch-change | Assign switch change callable. | Callback identity is published by the SDK ledger, not copied as Java object. |

### models/TextSetting.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 479 | cleanup@39 | platform-lifecycle/settings-resource | py-cleanup | Close/null click and subpage callbacks plus inherited long action. | Native SDK clears owned records/leases; no Java reference-count API. |
| 480 | getText@47 | member-body/model | settings-text | Return text-row label. | Native field mapping only. |
| 481 | setText@51 | member-body/model | settings-text | Assign text-row label. | Does not directly mutate a displayed cell. |
| 482 | getSubtext@55 | member-body/model | settings-subtext | Return text-row secondary description. | Native row data only. |
| 483 | setSubtext@59 | member-body/model | settings-subtext | Assign text-row secondary description. | Native schema refresh is separate. |
| 484 | getAccent@63 | member-body/model | settings-accent | Return accent style flag. | A semantic color role, not Android color/resource identity. |
| 485 | setAccent@67 | member-body/model | settings-accent | Assign accent style flag. | Native renderer applies current theme on refreshed row. |
| 486 | getRed@71 | member-body/model | settings-red | Return destructive/red style flag. | Semantic native destructive color replaces exact Android red. |
| 487 | setRed@75 | member-body/model | settings-red | Assign destructive style flag. | No independent destructive action or permission is granted. |
| 488 | getOnClickCallback@79 | member-body/model | text-click,settings-callback | Return text action callable; native row references its callback id. | PyObject remains local; native event requires current settings scope. |
| 489 | setOnClickCallback@83 | member-body/model | text-click,settings-callback | Assign text action callable for future serialization. | Replacing model field alone does not replace an admitted native lease. |
| 490 | getCreateSubFragmentCallback@87 | member-body/model | text-subpage,settings-subpage | Return subpage factory; SDK serializes its rows into native sub_page. | Native consumes materialized rows and identifier paths, not Java BaseFragment factory objects. |
| 491 | setCreateSubFragmentCallback@91 | member-body/model | text-subpage,settings-subpage | Assign subpage factory reference. | New create_settings serialization is required to publish changed nested rows. |

### ui/PluginActivityLogActivity.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 492 | createView@84 | partial/audit-renderer | manager-logs | Build per-plugin activity-journal UI with search and export. | Native manager log list exists, but lacks this merged audit journal/profile/search/export surface. |
| 493 | onItemClick@94 | partial/audit-ui-action | manager-logs | Back closes screen; export creates/shares the audit journal. | Native logs support copy, not original audit export. |
| 494 | onSearchCollapse@107 | partial/audit-ui-action | - | Clear audit search query and rebuild results. | Missing native audit-journal search/filter operation. |
| 495 | onTextChanged@113 | partial/audit-ui-action | - | Trim/lowercase audit search text, clear empty query and rebuild. | Native log viewer has no equivalent query/filter state. |

### ui/PluginIcons.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 496 | apply@45 | partial/resource-operation | p.icon,image | Parse pack/index, request sticker set, guard reused view tag and display the chosen sticker. | Native named-image resolver is not a pack/index sticker fetcher; plugin manager sticker-icon provider is missing. |

### ui/PluginInstallBottomSheet.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 497 | createObfuscationWarning@400 | partial/consent-renderer | - | Build obfuscation warning from localized title/info and evidence strings. | No native install-consent evidence panel; SDK static scan alone does not provide it. |
| 498 | createWarningBox@408 | partial/consent-renderer | cell | Build red rounded warning box with optional footnote. | Native error-row style is a visual role only; missing install warning-box/footnote composition. |

### ui/PluginPermissionCell.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 499 | applyColors@140 | platform-renderer/permission-renderer | cell | Apply title/subtitle/evidence background and expand-icon colors. | Native cells use semantic theme roles; no Android four-ARGB color or exact expand-evidence widget claim. |
| 500 | setOnExpandChanged@148 | partial/permission-ui-action | - | Store callback fired after animated evidence expansion. | Missing native permission-evidence expand callback/provider. |
| 501 | setOnToggle@153 | platform-renderer/permission-ui-action | cell-switch | Bind optional toggle action and selectable row background. | Native UISwitch/row actions replace View.OnClickListener and selector drawable. |
| 502 | getPermission@159 | member-body/permission-model | perm-kind | Return bound permission string. | Native permission enum/row id replaces Java cell field access. |
| 503 | isChecked@163 | platform-renderer/permission-state | cell | Read checkbox or switch state; native cell reflects the confirmed row.toggle value. | No exposed Android CheckBox/Switch object or synchronous Java getter. |
| 504 | setChecked@170 | platform-renderer/permission-state | cell | Set checkbox/switch display state with optional animation. | Native configure uses confirmed value; exact Android animation argument is not preserved. |
| 505 | setEnabledState@178 | platform-renderer/permission-state | cell | Enable controls and adjust label/control alpha. | Native row.enabled and semantic disabled styling replace exact Android 0.5 alpha. |
| 506 | set@195 | partial/permission-renderer | manager-plugin,cell | Bind permission/title/subtitle/evidence/divider and initially collapse evidence. | Native permission rows exist, but no capability-evidence/divider/expansion cell contract. |
| 507 | setExpanded@215 | partial/permission-ui-action | - | Toggle evidence visibility, rotate chevron, notify animated expansion and request layout. | Missing native evidence-expansion state and animation operation. |
| 508 | isExpanded@229 | partial/permission-state | - | Return current evidence expansion flag. | No native permission-evidence expansion model/getter. |

### ui/PluginPermissionsActivity.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 509 | titleOf@80 | partial/permission-model | perm-description | Return localized permission title with unknown-name fallback. | Native describes known enum cases; exact localized Android titles/null fallback are not mapped. |
| 510 | shortTitleOf@108 | partial/permission-model | perm-description | Return compact localized permission title or ordinary title fallback. | Missing distinct native compact-title mapping. |
| 511 | infoOf@126 | partial/permission-model | perm-description | Return detailed localized information for known permission, empty otherwise. | Native short descriptions do not supply every original permission-info string. |
| 512 | isEnforced@158 | partial/permission-policy | permission | Original reports every permission except settings as enforced. | Native settings/config calls do enforce settings; this display predicate is neither exported nor equivalent. |
| 513 | requestedFor@169 | partial/permission-policy | requested,scan | Offer declared permissions unless undeclared/obfuscated, then expand with scanned capability keys. | Native manager lists requestable grants without the same declaration/obfuscation/scan-derived offering policy. |
| 514 | createView@194 | partial/permission-renderer | manager-plugin | Build plugin permission page and live rows. | Native detail page has actual grant toggles; no separate trust-level/capability-evidence activity. |
| 515 | onItemClick@205 | platform-lifecycle/permission-navigation | list-create | Back button closes the permission page. | Native navigation back owns dismissal; no ActionBar item id API. |
| 516 | onTouchEvent@369 | partial/permission-ui-action | - | Hit-test trust-level label area and show level information, otherwise delegate touch. | Missing native three-level trust selector, label hit-test and info operation. |
| 517 | onResume@550 | platform-lifecycle/permission-lifecycle | manager-read | Refresh displayed permission state when page resumes. | Native snapshot/poll lifecycle replaces Android adapter.update(false). |

### ui/PluginSettingsActivity.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 518 | newInstance@121 | platform-lifecycle/settings-navigation | settings-init | Create settings page bound to plugin id. | Native page additionally captures owner/account scope; no Android fragment object. |
| 519 | newInstance@127 | partial/settings-navigation | settings-init,settings-page | Create page with a target-setting alias. | Native initializer accepts identifier pagePath, not original targetSetting alias. |
| 520 | newSubPage@133 | partial/settings-navigation | settings-page | Create subpage with JSON/title/index path/owner arrays and callback context. | Native sub_page tree and stable row identifiers replace JSON/index/owner-array arguments. |
| 521 | createView@149 | platform-renderer/settings-renderer | list-create,settings-render | Construct settings list/navigation and root reset affordance. | Native typed rows/navigation render the supported subset; original reset icon/activity layout are not guaranteed. |
| 522 | onItemClick@155 | platform-lifecycle/settings-navigation | list-create | Back action closes the settings screen. | Native navigation owns back dismissal; no ActionBar id mapping. |
| 523 | onFragmentCreate@223 | platform-lifecycle/settings-lifecycle | settings-init | Register plugin-specific reload listener during page creation. | Native scoped observation replaces Java Runnable list membership. |
| 524 | onFragmentDestroy@229 | platform-lifecycle/settings-lifecycle | settings-deinit | Remove reload listener and destroy page. | Native closes action/read authority and observation lifecycle. |
| 525 | onResume@235 | platform-lifecycle/settings-lifecycle | settings-appearance,settings-refresh | Rebuild from engine only when current page rows changed. | Native captured reads/current-schema gates differ from Android lastJson equality optimization. |
| 526 | updateItems@275 | platform-lifecycle/settings-lifecycle | refresh,settings-refresh | Schedule settings rows rebuild on the UI thread. | Native owner-captured refresh notification precedes guarded settings read. |
| 527 | fillItems@369 | platform-renderer/settings-renderer | settings-render,settings-decode | Reload rows, emit empty/not-loaded placeholder or build stable row items. | Native typed schema validates bounds/identity; no UItem/UniversalAdapter construction. |
| 528 | getTitle@531 | member-body/settings-model | p.title,settings-render | Prefer subpage title, otherwise plugin display name or settings fallback. | Native pageTitle is supplied at page construction; no Android getter export. |
| 529 | createView@694 | platform-renderer/custom-renderer | widget-container | Create full-width/wrap-height container for an already-created custom view. | Native container role only; manager Custom row support remains a separate gap. |
| 530 | bindView@704 | partial/custom-renderer | ui-custom,widget-container | Reuse same child or detach it from prior parent before attaching. | Native portable widget composition exists; arbitrary Android View reparenting and manager custom binding do not. |
| 531 | equals@723 | member-body/renderer-identity | settings-decode | Compare row ids for custom-content item identity. | Native stable identifiers replace Java UItem ids. |
| 532 | contentsEquals@728 | partial/renderer-identity | settings-decode,list-sections | Compare id, exact view identity and enabled flag. | Native immutable row equality/reload has no Android view-reference comparator. |
| 533 | onLongClick@788 | partial/settings-ui-action | settings-action,long-press | Prefer long callback, then custom factory long click, then copy setting link. | Native opaque long callback works; custom manager factory and original link-alias fallback are missing. |
| 534 | onClick@811 | partial/settings-ui-action | settings-row,settings-update,settings-action | Dispatch permission/warning row or switch/selector/input/custom/text action and subpage. | Supported native typed rows route correctly; custom factory and original ancillary-row semantics are incomplete. |

### ui/PluginSliderCell.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 535 | onProgressChanged@43 | partial/slider-ui-action | slider-preview,slider-range | Quantize user progress, update label and either retain pending value or notify outside tracking. | Native previews on valueChanged and commits on end/accessibility; no exact immediate-outside-tracking Android callback. |
| 536 | onStartTrackingTouch@60 | platform-renderer/slider-lifecycle | slider-preview | Enter tracking and discard prior pending value. | UIKit control tracking/preview owns this transient state; no explicit Java tracking callback export. |
| 537 | onStopTrackingTouch@66 | partial/slider-ui-action | slider-commit,settings-update | Commit last pending value and request settings refresh after tracking stops. | Native commits only changed normalized value and rereads via guarded mutation; unconditional Android reload differs. |
| 538 | createView@107 | platform-renderer/slider-renderer | cell | Construct native row's stepped slider control counterpart. | UISlider/PluginListCell is not PluginSliderCell or RecyclerView. |
| 539 | bindView@113 | platform-renderer/slider-renderer | cell,slider-range | Bind slider row JSON to range/value/labels. | Native validated PluginSliderRange and row snapshot replace unchecked JSONObject cast. |
| 540 | isClickable@118 | member-body/slider-policy | settings-row | Original slider factory is not row-clickable; native slider is controlled through its own control action. | No generic cell tap action is invented. |
| 541 | equals@123 | member-body/renderer-identity | settings-decode | Compare slider item ids. | Native stable row identity, not Java object identity. |
| 542 | contentsEquals@128 | partial/renderer-identity | slider-range,list-sections | Compare id and slider value/min/max/step/integral/text/subtext/key fields. | Native typed model equality/reload differs; integral display is derived and no Java JSON comparator is exported. |

### ui/PluginUiItem.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 543 | createView@74 | platform-renderer/toggle-renderer | cell | Construct bold checkbox-style permission/toggle row. | Native UISwitch cell uses semantic theme/accessibility; Android ripple and 56 dp height are not claimed. |
| 544 | bindView@85 | platform-renderer/toggle-renderer | cell | Bind enabled/title/checked/divider and clear icon. | Native toggle row fields replace TextCheckCell methods and drawable state. |
| 545 | equals@94 | member-body/renderer-identity | settings-decode | Compare row ids. | Native row identifier counterpart only. |
| 546 | contentsEquals@99 | partial/renderer-identity | list-sections | Compare id, checked, enabled and text content. | Native snapshot reload does not expose this Java UItem comparator. |

### ui/PluginsActivity.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 547 | createView@85 | partial/manager-renderer | manager-list,list-create | Build manager list, search, info/import/export/log controls and empty state. | Native installed list/import/runtime/log views exist; search/source-archive export/import and log-clear controls are missing. |
| 548 | onItemClick@91 | partial/manager-ui-action | manager-runtime,manager-logs,picker | Handle back/info/log export/plugin archive export/import/log clear menu actions. | Native info/log copy/single-source picker exist; archive and rotating-log operations are not supplied. |
| 549 | onSearchCollapse@117 | partial/manager-ui-action | - | Clear manager search query and rebuild rows. | Missing native plugin-list search/filter operation. |
| 550 | onTextChanged@123 | partial/manager-ui-action | - | Store edited manager query and update visible rows. | Native manager readSnapshot has no query filter. |
| 551 | onClick@329 | partial/manager-ui-action | - | Open the author's t.me username URL from a clickable text span. | Native metadata label has no corresponding author-link span action. |
| 552 | updateDrawState@334 | platform-renderer/text-renderer | cell | Draw username span without underline. | Native labels use their own attributed/text styling; no Android TextPaint/span method equivalence. |
| 553 | togglePlugin@359 | platform-lifecycle/manager-ui-action | manager-enable,enabled | Delegate row toggle to actual plugin enable/disable operation. | Native completion/error and captured Host lifecycle replace Java View callback. |
| 554 | sharePlugin@364 | partial/manager-ui-action | - | Delegate sharing installed plugin source. | Native manager has no selected-plugin source share/export operation. |
| 555 | pinPlugin@369 | platform-lifecycle/manager-ui-action | controls,manager-list | Toggle native pin state and refresh ordering. | Native semantic pinned rows replace Android pin/unpin bulletin and View callback. |
| 556 | openPluginSettings@384 | platform-lifecycle/manager-ui-action | manager-plugin,settings-init | Open the selected running plugin's owner-scoped settings page. | Native page object/lifetime replaces Java engine.openPluginSettings(fragment). |
| 557 | copyPluginSettingsLink@389 | partial/manager-ui-action | - | Copy generated plugin settings URL and optionally show copied bulletin. | Native manager lacks original plugin-settings URL generation/copy action. |
| 558 | openPluginPermissions@397 | platform-lifecycle/manager-ui-action | manager-plugin,set-grants | Open native detail-page grant controls. | No separate Android permissions activity or three-level trust selector. |
| 559 | deletePlugin@402 | platform-lifecycle/manager-ui-action | manager-remove,remove | Ask for deletion then execute actual native remove. | Native async error handling replaces Android delete dialog implementation. |
| 560 | openInExternalApp@407 | member-body/disabled-ui-hook | - | Original method body intentionally does nothing. | No external-editor launch is required or claimed by this empty hook. |
| 561 | canOpenInExternalApp@411 | member-body/disabled-ui-policy | - | Original returns false, disabling external-app editor action. | Native manager likewise supplies no such action; no Android editor integration claimed. |
| 562 | onActivityResultFragment@668 | partial/import-lifecycle | picker,import-copy | Handle plugin-archive picker or single-plugin URI picker result and install/import selection. | Native document picker connects single .py/.plugin import only; Android archive/Intent result branch is missing. |
| 563 | onResume@742 | partial/manager-lifecycle | manager-read,manager-runtime | Consume recovery notices, refresh list and asynchronously rescan installed sources. | Native snapshot/recovery acknowledgement exists; no consumptive notice getters or directory rescan. |
| 564 | isSupportEdgeToEdge@775 | platform-renderer/manager-layout | list-layout | Original opts into edge-to-edge layout. | Native navigation/safe-area layout is the counterpart role, not Android inset policy. |
| 565 | onInsets@780 | platform-renderer/manager-layout | list-layout | Apply bottom list padding and allow scrolling into padding. | Native safe/input/navigation insets replace Android bottom-only padding and clipping flag. |

### ui/PluginsEmptyCell.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 566 | hasOverlappingRendering@118 | member-body/renderer-policy | manager-list | Original returns false as a drawing optimization for empty cell. | Native empty state is an ordinary grouped row; no Android compositor hint or frame equivalence. |

### ui/PluginsInfoActivity.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 567 | createView@62 | platform-renderer/runtime-renderer | manager-runtime | Build runtime-info/settings page with back navigation and live rows. | Native engine/developer/compact/safe/recovery controls explicitly describe unsupported ART/Xposed mechanisms. |
| 568 | onItemClick@68 | platform-lifecycle/runtime-navigation | list-create | Back action closes runtime information page. | Native navigation owns back behavior; no ActionBar id contract. |
| 569 | onResume@226 | platform-lifecycle/runtime-lifecycle | manager-read | Refresh runtime settings/info rows on resume. | Native snapshot/poll lifecycle replaces Android UniversalAdapter update. |
| 570 | isSupportEdgeToEdge@234 | platform-renderer/runtime-layout | list-layout | Original enables edge-to-edge layout. | Native safe-area/nav integration role only. |
| 571 | onInsets@239 | platform-renderer/runtime-layout | list-layout | Apply bottom padding and disable clip-to-padding for info list. | Native full layout/input inset calculation differs from Android flag semantics. |

### ui/components/PluginAiReview.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 572 | canReview@51 | partial/ai-review-operation | ai-source | Allow bounded review-tool input, or readable text fallback when tools are disabled. | Native bounded snapshot/source-mode checks exist; no exact File/disableTools Boolean predicate or identical limits. |
| 573 | isCached@58 | partial/ai-review-operation | ai-cache | Check nonempty cached review for selected source file. | Native cache key includes revision/language/provider/model/mode and expires; no Java file-only cache predicate. |
| 574 | review@62 | platform-lifecycle/ai-review-operation | ai-review,ai-source | Read selected source, choose excerpt/tools mode, use cached review or configured AI generation. | Native review is account/cancellation bounded and source-only; no Android sheet/role object or provider/network execution verified here. |

### ui/components/PluginCell.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 575 | didReceivedNotification@87 | platform-lifecycle/plugin-cell-lifecycle | manager-read,manager-plugin | Update settings-action visibility when matching plugin settings register/unregister. | Native snapshot hasSettings/loaded state replaces Android notification ids and args. |
| 576 | createView@147 | platform-renderer/plugin-cell-renderer | cell | Create native plugin row control counterpart. | No Android PluginCell/RecyclerView instance. |
| 577 | bindView@153 | platform-renderer/plugin-cell-renderer | manager-list,cell | Bind plugin and row delegate/model to its displayed cell. | Native row closures/snapshots replace PluginCellDelegate and UItem object/object2. |
| 578 | equals@162 | member-body/renderer-identity | p.id | Compare model plugin ids when both models exist. | Native Plugin.id/row id identity, not Java model references. |
| 579 | contentsEquals@169 | platform-renderer/renderer-invalidation | manager-read | Compare row model content to avoid unnecessary redraw. | Native compares plugin/presentation snapshots before render; exact Android Model.sameContent comparator is not exported. |
| 580 | asPlugin@175 | platform-renderer/plugin-row-model | manager-list | Produce row using plugin data, pin state, compact mode and delegate. | Native PluginListRow carries closures and semantic styles, not UItem factory output. |
| 581 | onTouch@356 | platform-renderer/plugin-gesture | long-press | Track press, dispatch long action and suppress following tap when handled. | Native gesture recognizer replaces delayed View runnable and Android scale/overshoot animation; exact touch choreography unverified. |
| 582 | setDelegate@409 | platform-renderer/plugin-row-model | manager-plugin | Retain action delegate and expose permission action when supported. | Native optional action closures/permission provider replace Java interface-instance test. |
| 583 | set@426 | partial/plugin-cell-renderer | manager-list,cell | Bind plugin metadata/error/pin/enable/settings state and update layout/icon when identity changes. | Native supported labels/state controls exist; pack/index sticker icons and Android username formatting are incomplete. |
| 584 | setChecked@497 | platform-renderer/plugin-state | cell | Update enable checkbox display. | Native confirmed UISwitch row state replaces Android animated checkbox mutation. |
| 585 | hasOverlappingRendering@508 | member-body/renderer-policy | cell | Original returns false to avoid overlap-rendering overhead. | Native cell compositing is independent; no exact Android renderer optimization claim. |

### ui/components/PluginFileViewer.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 586 | canOpen@33 | partial/source-viewer-operation | ai-source | Check bounded regular file and readable source representation. | Native review can read source, but no matching standalone source-viewer canOpen provider. |
| 587 | open@40 | partial/source-viewer-operation | - | Read source, create article-viewer message and open it, otherwise show error bulletin. | Missing native plugin source ArticleViewer operation; AI review is not a source viewer. |

### ui/components/PluginReviewTools.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 588 | definitions@224 | member-body/ai-tool-model | ai-definitions | Declare read_source, list_blobs and decode_base64 tool schemas. | Native typed tool definitions preserve operations with bounded selected-snapshot semantics, not Java JSONArray identity. |
| 589 | describe@262 | partial/ai-tool-model | - | Format readable tool-call label including source line range or selected blob/entry. | No exact native describe(name,JSONObject) formatter operation. |
| 590 | fallback@279 | member-body/ai-tool-model | ai-fallback | Return retained fallback conversation messages when tool use is unavailable. | Native handler builds source-excerpt messages from the selected snapshot; no Java mutable List<Message> identity. |
| 591 | call@284 | member-body/ai-tool-helper | ai-call,ai-tools-consumer | Dispatch the three read/decode tools against selected source data using the native AI tool helper. | This is the native review helper counterpart, not a Java PluginReviewTools facade; unknown tools throw and DEX bytes are inspected without execution. |

### ui/components/templates/UniversalFragment.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 592 | getDelegate@75 | partial/platform-model | - | Return the fragment delegate reference. | No native UniversalFragmentDelegate object model; portable callbacks have explicit event schemas. |
| 593 | setDelegate@79 | partial/platform-model | - | Replace fragment delegate reference. | Missing native equivalent for arbitrary Java fragment delegate method set. |
| 594 | getActionBarMenu@83 | unsupported/android-ui | - | Create/return Android ActionBarMenu. | Native navigation items/menu DTOs do not expose an Android ActionBarMenu object. |
| 595 | setTitle@87 | partial/ui-operation | update-ui | Set title immediately or animate it using requested/default 300 ms duration. | Native model title can update; no exact ActionBar title animation/duration overload. |
| 596 | createView@96 | partial/platform-renderer | present | Allow delegate beforeCreateView replacement, otherwise create base view then optionally wrap it. | Native page presentation accepts validated widget DTOs; before/after arbitrary Android View interception is missing. |
| 597 | onItemClick@107 | partial/platform-ui-action | navigate | Back consults delegate then closes; other ids invoke delegate menu action. | Native explicit back/menu actions exist but no arbitrary delegate/id callback contract. |
| 598 | getTitle@128 | partial/platform-model | - | Return delegate title or null. | Native page title field exists, but no delegate-driven getter provider. |
| 599 | fillItems@133 | partial/platform-renderer | settings-render | Ask delegate to fill UItem list and adapter. | Native validated rows replace UItem/UniversalAdapter mutation; arbitrary delegate fillItems is not callable. |
| 600 | onClick@140 | partial/platform-ui-action | list-action | Forward row/view/position/x/y click to delegate when present. | Native row action lacks Android View, adapter index and raw touch-coordinate callback contract. |
| 601 | onLongClick@147 | partial/platform-ui-action | long-press | Return delegate's long-click result, false without delegate. | Native settings long action is void/owned callback; no matching Java Bool-returning delegate API. |
| 602 | onFragmentCreate@152 | partial/platform-lifecycle | settings-init | Notify delegate of fragment creation, then call base lifecycle. | Native scoped page lifecycle exists; no arbitrary UniversalFragment creation callback provider. |
| 603 | onFragmentDestroy@160 | partial/platform-lifecycle | ui-release,settings-deinit | Notify delegate then run base destruction. | Native closes leases/page scopes; Java delegate teardown callback is not mapped. |
| 604 | onBackPressed@168 | partial/platform-ui-action | navigate | Delegate nullable handled result overrides base back decision with inverted consumed flag. | Native explicit navigation/cancel event model lacks this exact nullable/inverted delegate contract. |

### ui/components/templates/UniversalView.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 605 | getDelegate@53 | partial/platform-model | - | Return retained UniversalView delegate. | No equivalent native arbitrary Android view-delegate object. |
| 606 | setDelegate@57 | partial/platform-model | - | Assign UniversalView delegate. | Portable widget listeners do not implement this Canvas/measure/accessibility/touch override set. |
| 607 | callSuperOnDraw@61 | unsupported/android-ui | - | Invoke Android View superclass Canvas drawing. | No Android Canvas or Java superclass draw dispatch on iOS. |
| 608 | callSuperOnInitializeAccessibilityNodeInfo@65 | unsupported/android-ui | - | Invoke superclass Android accessibility-node initialization. | Native VoiceOver accessibility is not AccessibilityNodeInfo/super dispatch. |
| 609 | callSuperOnMeasure@69 | unsupported/android-ui | - | Invoke superclass measurement with Android measure specs. | No Android MeasureSpec or Java View superclass measurement provider. |
| 610 | callSuperOnTouchEvent@73 | unsupported/android-ui | - | Invoke superclass Android touch handling and return its Bool. | Native UIGesture/UIControl events are not MotionEvent/super dispatch. |
| 611 | onInitializeAccessibilityNodeInfo@106 | unsupported/android-ui | - | Let delegate customize Android accessibility info with a callable superclass fallback. | No Android accessibility-node/callable-super bridge; native accessibility roles are implemented independently. |
| 612 | onTouchEvent@129 | unsupported/android-ui | - | Delegate Android MotionEvent handling with superclass callback or call base. | No raw MotionEvent/Java superclass callback execution; portable listeners are a narrower interface. |

### utils/ClassProxyFactory.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 613 | getLastError@113 | partial/diagnostic-model | - | Return the proxy generator's stored lastError. | Native has no proxy-generator last-error cache; thrown unsupported error is not this getter. |
| 614 | setLastError@118 | partial/diagnostic-model | - | Replace stored proxy-generator lastError. | No native mutable proxy-error cache operation. |
| 615 | generateProxyClass@127 | unsupported/dex | - | Generate/cache DEX proxy class; on failure log and store type/message, returning null. | No DEX emission/loading, Java class cache or generated subclass runtime. |
| 616 | needsHooks@140 | unsupported/jvm | - | Parse superclass name, resolve Java Class and decide hooks requirement; errors conservatively require hooks. | Java superclass resolution/policy for generated classes has no native provider. |
| 617 | classNeedsHooks@151 | unsupported/jvm | - | Look up generated class and classify its superclass; missing record requires hooks. | No generated Java Class registry/superclass policy. |
| 618 | newProxyInstance@170 | unsupported/dex | - | Select/coerce constructor, instantiate generated Java class, bind Python peer and initialize fields. | No DEX constructor/reflection/PyObject peer instance provider. |
| 619 | getProxyClass@200 | unsupported/dex | - | Return generated class for key, or null. | No Java generated-class object registry. |
| 620 | invokeSuper@205 | unsupported/dex | - | Select generated method/trampoline by signature/arity and invoke superclass with coerced args. | No Java superclass trampoline execution or default-return fallback. |
| 621 | releaseProxyInstance@247 | unsupported/dex | - | Reflectively clear generated instance's Python-peer field. | Native callback leases are not DEX peer fields and cannot accept this proxy object. |
| 622 | releaseAllForPlugin@263 | unsupported/dex | - | Remove all generated class records owned by plugin id. | No DEX class records to release; native SDK unload cleanup is a different operation. |
| 623 | dispatch@279 | unsupported/dex | - | Execute generated MVEL/Python method body, else superclass trampoline, else type default. | No generated Java method dispatcher, arbitrary MVEL runtime or silent Java return-default emulation. |
| 624 | preConstruct@320 | unsupported/dex | - | Call Python preconstructor hook and coerce its result to Java Object[] before generated construction. | No generated Java constructor interception/argument-array provider. |
| 625 | box@364 | partial/scalar-helper | scalar | Box Java byte into Object; SDK has an explicit signed-byte descriptor/converter. | Scalar data mapping only; no Java Byte object identity or ClassProxyFactory method export. |
| 626 | box@365 | partial/scalar-helper | scalar | Box Java char into Object; SDK represents one UTF-16 code unit with jchar. | No Java Character boxing object or DEX helper execution. |
| 627 | box@366 | partial/scalar-helper | scalar | Box Java double into Object; SDK carries a floating scalar with double descriptor. | No Java Double object identity or exact factory helper. |
| 628 | box@367 | partial/scalar-helper | scalar | Box Java float into Object; SDK has distinct float descriptor. | Python float storage is binary64; Java Float boxing/rounding identity is not reproduced here. |
| 629 | box@368 | partial/scalar-helper | scalar | Box Java int into Object; SDK jint enforces signed 32-bit data range. | Conversion is not Java Integer allocation or generated-class execution. |
| 630 | box@369 | partial/scalar-helper | scalar | Box Java long into Object; SDK jlong represents signed 64-bit scalar data. | No Java Long box identity or direct helper call. |
| 631 | box@370 | member-body/scalar-helper | reference-cast | Object overload returns the identical reference without conversion; compatible portable cast likewise returns its input reference. | Pure identity body, with no DEX execution; cast additionally validates target compatibility. |
| 632 | box@371 | partial/scalar-helper | scalar | Box Java short into Object; SDK jshort preserves signed 16-bit descriptor/range. | No Java Short wrapper allocation/identity. |
| 633 | box@372 | partial/scalar-helper | scalar | Box Java boolean into Object; SDK has a distinct boolean scalar descriptor. | No Java Boolean object identity or generated-class helper. |
| 634 | unboxBool@374 | partial/scalar-helper | scalar | Return true only for a Java Boolean true, otherwise false. | SDK jboolean uses Python truth conversion; exact instanceof-Boolean fallback helper is missing. |
| 635 | unboxByte@375 | partial/scalar-helper | scalar | Narrow Number.byteValue or return zero for non-Number. | SDK explicit byte conversion/range checks do not implement the silent non-number-zero helper. |
| 636 | unboxChar@376 | partial/scalar-helper | scalar | Accept Character or narrow Number to char, otherwise NUL. | SDK jchar enforces one UTF-16 unit; Java Number/Character fallback semantics are not exported. |
| 637 | unboxDouble@381 | partial/scalar-helper | scalar | Convert Number.doubleValue, otherwise 0.0. | Native/Python float conversion may reject invalid input instead of zero fallback. |
| 638 | unboxFloat@382 | partial/scalar-helper | scalar | Convert Number.floatValue, otherwise 0.0f. | Exact Java float32 narrowing and non-number fallback are not this SDK converter. |
| 639 | unboxInt@383 | partial/scalar-helper | scalar | Narrow Number.intValue, otherwise zero. | SDK jint has explicit range/truncate semantics, not this permissive Object helper. |
| 640 | unboxLong@384 | partial/scalar-helper | scalar | Convert Number.longValue, otherwise zero. | SDK jlong conversion is explicit; Java Number test/zero fallback missing. |
| 641 | unboxShort@385 | partial/scalar-helper | scalar | Narrow Number.shortValue, otherwise zero. | SDK jshort does not silently accept all non-number Objects as zero. |

### xposed/HookGate.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 642 | prewarm@89 | unsupported/xposed | - | Install guarded hook record/backup and temporary barrier for a concrete Java member. | No Xposed HookInfo/native hook0/Java Member patching provider. |
| 643 | guardBridge@130 | unsupported/xposed | - | Prewarm and hook XposedBridge.hookMethod itself with BridgeGuard. | No Android Xposed bridge self-hooking on iOS. |
| 644 | prewarmAllMethods@144 | unsupported/xposed | - | Enumerate declared Java methods by name and prewarm each hook. | No JVM reflected method enumeration-to-Xposed installation. |
| 645 | prewarmAllConstructors@159 | unsupported/xposed | - | Enumerate Java constructors and prewarm each one. | No Java constructor hook registry. |
| 646 | callback@203 | unsupported/xposed | - | Validate hooked primitive return, coerce Number or invoke original backup on wrong type. | No Java hook callback/original-method trampoline; native schema validation is a different boundary. |

### xposed/HookStats.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 647 | isEnabled@128 | unsupported/xposed-instrumentation | - | Return Xposed hook-profiling enabled flag. | No native Xposed instrumentation session or equivalent flag. |
| 648 | start@132 | unsupported/xposed-instrumentation | - | Reset all hook counters, enable collection and arm Python profiler if started. | Missing Java/Xposed per-hook/main-thread contention profiler, not equivalent to native watchdog. |
| 649 | armPython@143 | unsupported/xposed-instrumentation | - | Arm Python hook profiler once while hook statistics are enabled. | No composed Xposed profiling/Chaquopy arming lifecycle. |
| 650 | stop@150 | unsupported/xposed-instrumentation | - | Disable Java hook stats and stop Python profile collection. | No corresponding active native hook-profiling session to stop. |
| 651 | appendReport@168 | unsupported/xposed-instrumentation | - | Combine Java call/time/main-thread/contention counters with Python/GC snapshots into a text report. | Native logs/watchdog do not supply this Xposed performance dataset/report. |

### xposed/XposedHooks.java

| # | Original | Disposition/category | Routes | Contract | Limitations |
| --- | --- | --- | --- | --- | --- |
| 652 | ensureReady@58 | unsupported/xposed | - | Initialize native Android hook library once and return readiness. | No Aliuhook/Xposed library initialization on iOS. |
| 653 | isReady@62 | unsupported/xposed | - | Return initAttempted AND initOk for Xposed. | Native CPython readiness is not Xposed readiness. |
| 654 | activeHookCount@66 | unsupported/xposed | - | Return number of registered Xposed unhook objects. | No Xposed registry; native TL subscriber count is not an equivalent count. |
| 655 | isNativeHooksBroken@70 | unsupported/xposed | - | Read persisted native-hook broken marker. | Android hook-library failure marker has no corresponding native runtime state. |
| 656 | resetNativeHooksBroken@76 | unsupported/xposed | - | Gate caller then clear broken/stamp/strike/pending hook markers synchronously. | No Android hook-library retry markers/store to reset. |
| 657 | hookMethod@207 | unsupported/xposed | - | Validate plugin/handler/member, deny protected target, prewarm, hook and register unhook id. | No Java member interception or XC_MethodHook handler execution. |
| 658 | hookAllMethods@232 | unsupported/xposed | - | Resolve declaring shim parent, prewarm all named methods and return registered unhook ids. | No JVM shim-parent lookup/overload patching provider. |
| 659 | hookAllConstructors@281 | unsupported/xposed | - | Validate class and handler, prewarm constructors and register every hook. | No Android constructor interception on iOS. |
| 660 | addPluginUnhook@351 | unsupported/xposed | - | Reuse an existing id for identical unhook object or register it under plugin. | No XC_MethodHook.Unhook object identity registry. |
| 661 | removePluginUnhook@364 | unsupported/xposed | - | Find matching registered object and unhook, or invoke its unhook method directly. | No Xposed unhook callback/object execution. |
| 662 | unhook@384 | unsupported/xposed | - | Atomically remove unhook id, invoke unhook and remove owner/set bookkeeping. | Native captured callback leases are not Xposed hooks; no matching id operation. |
| 663 | unhookAllForPlugin@406 | unsupported/xposed | - | Remove plugin-owned hook-id set and unhook each member. | No Xposed all-hooks registry or plugin-id-only removal on iOS. |
| 664 | invokeOriginalMethod@421 | unsupported/xposed | - | Invoke original Java Member with receiver and argument array. | No Java original-method backup/trampoline provider. |
| 665 | deoptimizeMethod@425 | unsupported/art | - | Initialize hooking then deoptimize a Java Member, logging failure. | Android ART method deoptimization is unavailable. |
| 666 | allocateInstance@436 | unsupported/jvm | - | Initialize hooking then allocate Java Class instance without constructor, null on failure. | No JVM Class allocation-without-constructor operation. |
<!-- members:end -->

</details>

## Validation receipt

**PASS — bounded static checks, each command capped at 30 seconds.**

- Exact identity join: **666/666 members and 666/666 member_routes**; zero missing,
  extra or duplicate identities. Original result types and binding metadata also
  match the inventory.
- **69/69 original raw-file pins**, original module aggregate, **125/125 total
  source-file pins** and **666/666 normalized method-body pins** match actual files.
- Every route path/line resolves to its named source symbol/field or containing
  Swift method; dispatcher case anchors retain their exact operation projections.
- All 666 Markdown rows match JSON identity/disposition/contract/limitations.
  JSON parsing, required fields, evidence joins and trailing-whitespace checks pass.
- `verified: true` = **0**; `ported: true` = **0**. These checks establish the
  source receipt, not execution of plugins or production providers.

| Disposition | Members |
| --- | ---: |
| member-body | 134 |
| platform-lifecycle | 89 |
| platform-renderer | 40 |
| source-routed | 28 |
| partial | 309 |
| unsupported | 66 |
| **Total** | **666** |

The 309 partial rows include exact facade, model and lifecycle differences; they
are not a count of 309 missing native providers. The four focused P2s and remaining
semantic gaps above are preserved independently of identity coverage.

Final `plugins.json` raw SHA-256:
`1b8c2b1bb167248a741bf27bbdbb082f1dbc51f37254d686ad3385c331a3574c`.

Exact identity SHA-256:
`179676e572472dd1acaccb382378494ce56f73e861c02db1ce410b74efb519d2`.
