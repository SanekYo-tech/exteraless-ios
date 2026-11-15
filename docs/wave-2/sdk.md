# SDK adapter — wave 2 implementation and integration handoff

Base `68bb1adf`; implementation date 2026-11-15. This report describes the Python
SDK/registry work, not UIKit frames, network delivery or a full-client parity pass.

## Original sources inspected

- `third_party/exteraless-android/TMessagesProj/src/main/python/`:
  base_plugin, android_utils, client_utils, file_utils, plugin_settings,
  hook_utils, intents, markdown_utils, ui/{settings,alert,bulletin},
  extera_utils/{classes,text_formatting,plugin_loader}.
- `src/main/java/app/exteraless/plugins/PythonBridge.java`: JSON-string settings,
  import vs replace semantics, reload callback, menu click Map, SDK version 1.4.5.7.
- `PluginServices.java`: file/intent registration; Runnable callbacks with zero
  args; request callback `(response,error)`; UI/dispatch queues; JVM-only methods.
- `PluginsController.java:1141–1214,1323–1342,2174–2253`: settings merge/replace,
  reset/reload, menu replacement by item_id, same-model implicit id reuse.
- `MenuItemRecord.java`: the five actual placements and priority/condition fields.
- `PluginMediaServices.java`: local file checks, filename/MIME metadata, actual
  editing/upload path (not a fabricated completed upload).
- `org/telegram/ui/ActionBar/BottomSheet.java:2387–2521`: builder/items/click/create/show.
- Both Java **and Kotlin** trees searched for SDK service implementations.
  Kotlin `app/exteraless/{OpenExteraConfig,appearance/M3ListItems,links/UrlCleaner}.kt`
  were read: these are client policies/settings, not alternate PluginServices or
  PythonBridge implementations. Their native feature ports belong to domain agents.

## Delivered files / live callsites

- `python/virtualjava/registry.py`: explicit exact-name Python classes and lazy
  schema factories. `proxy.get_class` consults it before the original C fallback.
  The installed **C BridgeBackend object is not replaced**. Unknown members still
  raise; no Universal backend is installed. Registered app.* ancestors import as
  Java packages. Primitive casts/arrays and a working GuardedMethod descriptor
  replace the old permissive generic results for those implemented operations.
- `_java_types.py`: concrete collections, strings/numbers, file/URI, UUID/time,
  registered interface callbacks, reflection over actual Python fields/methods.
- `_settings.py`: BasePlugin and module storage use the coordinator's opaque JSON
  bulk API, including literal reserved keys, merge/replace/reset and real UI refresh.
  Dirty SDK mirror edits survive unrelated BasePlugin reads until saved.
- `_callbacks.py`: 128 leases / 1024 owned callback handles maximum; distinct
  wrappers, generation checks, admission-failure cleanup, native-owned FIFO release.
- `_registrations.py`: original menu data and logical item-id replacement; SDK
  file/intent callbacks and filters forwarded to explicit native admission APIs.
- `_ui.py`: actual SDK AlertDialogBuilder executes Python model mutations while
  native UI owns show/update/state/dismiss. Portable widgets, settings pages,
  bulletins/toasts, BottomSheet items, clipboard/share/URL intents use native effects.
  The final NativeUI SDK stitch adds logical-point layout/padding, fonts/images,
  stable live listeners and generic settings refresh callbacks; see `sdk-ui-source-handoff.md`.
- `_tl.py`: generated native TL schema and exact Android aliases; TL values are
  data, not Java handles. Native requests/peer lookup/media, scoped response/error
  callbacks and cancellation, SDK-compatible integer request tokens.
- `_scheduling.py`: SDK named queues and background-to-owner posts; no Python on
  UIKit/main and no PyGILState_Ensure. All native SDK mutations remain owner-bound.
- `_facades.py`: actual Java SDK entry names (PythonBridge/PluginServices/
  PluginsController), ApplicationLoader/AndroidUtilities/Browser facades.
- `_controllers.py`: typed asynchronous native account/cache/media/download facades,
  live availability and three real NotificationCenter event mappings.
- `_config.py`, `_config_manifest.py`: exact source-pinned Config classes/methods,
  canonical public native keys, typed access and explicit missing-schema errors.
- `_pill_types.py`: source PillInfo field/accessor dual values, creator arity,
  PillType constants, portable BasePill content and stable mutable layout ADTs.
- `_pills.py`: native wire-v1 registration, per-selection/account callbacks, persistent
  native ID aliases and atomic layout CAS; details in `sdk-pills.md`.
- `_logging.py`: SDK safe_call exception semantics with native structured errors
  and the existing native log fallback; original callback exceptions are preserved.
- `__init__.py`: begin/end callback generation, robust unload, host owner binding
  and FIFO handle-release seams. Existing load/metadata/hooks API remains available.
- `_audit_paths.py`: existing frozen-os fix retained; native protected client
  directories refreshed on owner entries, without sealing app-group/data/tmp roots.
- `_dependencies.py`: approved wave-1 eight-package and complete wave-2 twelve-
  package inventories. bs4/soupsieve and reviewed PyYAML/debugpy projections use
  their real .dist-info. Shipping debugpy is not a claim that listen/PID attach works.

TL metadata is read from **`App.app/python/tl-schema.json`**; the source-tree
fallback is `python/runtime/tl-schema.json`. Package staging owns that copy.

## Current native contracts consumed

Host binds its random per-interpreter `CallbackOwner.wireToken` with the immutable
C `xt_set_owner_token`, then calls SDK `bind_owner_json` before load. The SDK repeats
the C setter to verify agreement, with a 1–256 UTF-8 byte bound. Python request
dictionaries do not author ownerToken. C injects it into xt_call_host and all seven
BridgeBackend operations. See `native-owner-token.md` for the C contract.

`releaseCallbackHandles` now calls SDK `release_handles_json`; the actual dispatcher
orders terminal callbacks before release. Silent native retirement clears Python
lease/task/request and original file/intent registration bookkeeping. Host,
maintenance, effect validation and mailbox gates are consumed through their APIs.

The native SDK probe uses `onOwnedCallback`, validates the captured epoch before
admission and returns the actual dispatcher admission Bool. Its synchronous platform
fixture calls `PluginNativeCallLease.check()` before recording a rejected effect.
Result-bearing callbacks use `PluginCallbackDispatcher.result` / `invokeCallbackResult`.

`Runtime` reflection queries live exportedMethods metadata on every member lookup;
an exported method call still uses the installed C BridgeBackend. Removing a
provider removes its advertised member immediately.

### Native operations / composition

Exact envelopes/arguments are in **`sdk-wire.md`**, with final TL shapes in
**`tl-schema.md`**. All are real bridge calls; absence raises a named error.

| Operation | Owner / current integration dependency |
|---|---|
| getSettings/setSettings/updateSettings/clearSettings | Coordinator builtin implemented: opaque JSON strings, atomic storage |
| getProtectedPaths | Coordinator builtin implemented: `[absoluteString]`; native retains specific client directories across logout |
| getClientSetting/setClientSetting | Coordinator Core bridge implemented; redacted reads and guarded public writes |
| uiPresent/uiUpdate/uiDismiss/uiState | Native UI provider composed in Runtime; native execution/frame validation remains its gate |
| menuRegister/menuRemove | Native UI provider and common menu insertions applied by NativeUI/coordinator; same five placements |
| uiActiveFragment/uiNavigate/uiRefreshSettings | Native UI provider; actual screen/refresh registry |
| tlRequest/tlCancel/getPeer/sendMedia | Native TL provider; actual schema/Network/enqueue composition and owner token validation |
| postToOwner/cancelOwnerTask | NativeServices ready; SDK publication/close share callbacks.lock, including zero-delay completion before background admission returns; 0...86400000 ms |
| fileRegister/fileRemove | NativeServices ready at composed interception sites; portable File context; all successful return values ignored, exceptions propagate to the native opener |
| intentRegister/intentRemove | NativeServices ready; actual before Bool retained, after result discarded; silent retirement clears SDK handler dictionaries |
| logEvent | NativeServices ready; structured SDK logging and original log fallback |
| nativeGetUser/Chat/Contacts/PeerInfo/ObservePeer, nativeMessageMedia/ResourceStatus/ObserveResource/Download/NotificationSettings | Exact asynchronous account-pinned facades in `_controllers.py`; last native subscription value via nativeServiceState |
| notificationSupported/Subscribe/Unsubscribe, nativeConnectionState | Live availability for original events 25/46/137; no implicit hook-account binding in delegate callbacks |

`getProtectedPaths` directories protect raw writes via SDK hooks policy. A `files`
grant alone, or files+settings without hooks, cannot replace client-settings.json.
Normal settings permission uses `setClientSetting` / Core setPublic. No secret is
read from Keychain through the Python settings facade.

## SDK public-function coverage matrix

Statuses: **stock** = existing real SDK Python implementation; **implemented** =
Python adapter/port with bounded behavioral tests; **native-dependency** = working
Python call/DTO/callback path whose actual effect depends on the named native
provider; **platform-blocked** = JVM/Android-only mechanism; **pending** = no honest
equivalent is currently wired. Native-dependency is not an end-to-end native pass.

### base_plugin

| Public surface | Status / semantics |
|---|---|
| HookStrategy, HookResult, AppEvent.from_java, MenuItemType, MenuItemData, PluginsConstants | stock data/constants |
| BasePlugin.on_plugin_load/on_plugin_unload/on_app_event/create_settings | stock dispatch + implemented context/cleanup |
| pre_request_hook/post_request_hook/on_send_message_hook/on_update_hook/on_updates_hook | actual SDK dispatch; TL v1 unwraps deep data for both observation/transform paths and retains immutable context outside TL fields; native mutation barriers own acceptance |
| plugin_id; client getter/setter/deleter | stock; account resolution retained |
| log | implemented native log; structured callback errors additionally emitted |
| get_setting/set_setting/export_settings/import_settings | implemented; opaque JSON, real merge/export and reload request |
| add_hook/remove_hook/add_on_send_message_hook | stock registration data + implemented local dispatch filtering; cross-plugin priority changes still need Host registration integration |
| add_menu_item/remove_menu_item | implemented + native-dependency menu insertion/removal; replacement retires prior lease |
| hook_method/hook_all_methods/hook_all_constructors/unhook_method | platform-blocked JVM/Xposed |
| BaseHook, MethodHook.before_hooked_method/after_hooked_method, MethodReplacement.replace_hooked_method | stock protocol definitions; executing Java method hooks is platform-blocked |
| UnhookId.unhook, UnhookIdList.unhook, HookParam.java, bind_hook | stock helpers around platform-blocked Xposed members |
| HookFilter.to_dict, argument_is_null/not_null/is_true/is_false/equal/not_equal/is_instance_of, result_is_null/not_null/is_true/is_false/equal/not_equal/is_instance_of, condition, or_; CamelCase aliases; hook_filters | stock descriptor/JSON behavior, not a JVM hook executor |
| reset_settings/get_client_setting/set_client_setting (additions) | implemented; native storage/Core dependency |

### android_utils

| Public function | Status / semantics |
|---|---|
| log | stock formatting → native log |
| safe_call | implemented SDK-compatible non-throwing exception log path |
| R, OnClickListener, OnLongClickListener, OnTouchListener, OnKeyListener, OnSeekBarChangeListener | stock wrappers over concrete registered Python interfaces; actual UI wiring only for supported native events |
| run_on_ui_thread | existing native owner callback path; background calls use postToOwner (native-dependency) |
| get_context | implemented iOS context facade: scoped directories, clipboard, supported intents |
| get_activity | native-dependency active-screen descriptor; None if no native screen |
| copy_to_clipboard | implemented → Runtime.addToClipboard |
| AndroidUtilities re-export | implemented dp/dpf2/native scheduling/clipboard subset, unknown members fail |
| share_text/share_file (additions), Intent ACTION_SEND/MULTIPLE/VIEW | native-dependency share/URL presentation; ordinary iOS scene presentation maps NEW_TASK |

### client_utils (AccountClient forwards retain the same status)

| Public functions | Status / constraints |
|---|---|
| get_hook_account, hook_scope, get_client, AccountClient.account/call | stock account scope |
| get_selected_account | implemented native actual slot, no fabricated account 0 |
| get_queue_by_name, run_on_queue | implemented named owner-queue mapping to ready NativeServices; Runnable is void even for arbitrary Python return objects |
| show_error_bulletin, show_info_bulletin | stock delegators → native UI |
| RequestCallback, send_request | implemented native TL admission, two-argument decoded response/error, original account scope, cancellation/terminal release |
| get_account_instance | implemented account facade; ConnectionsManager/SendMessagesHelper are real adapters |
| get_connections_manager | implemented request/cancel and actual published native connection-state mapping; Android flags/quick-ack unsupported |
| get_send_messages_helper | implemented sendMessage(params) and (peer,text) paths |
| get_user_config | native-dependency builtin account handle: actual user id/activation/current account subset |
| get_messages_controller | explicit async getUser/getChat/getPeerInfo/observePeer; getUser(0) targets the native current user; absent peer stays None |
| get_last_fragment/get_current_fragment | native-dependency uiActiveFragment; no fake visible screen |
| get_contacts_controller, get_media_data_controller, get_notifications_controller, get_file_loader, get_download_controller, get_notifications_settings, get_notification_center | explicit native facades; supported() queries live provider availability, bounded async reads/downloads and cancellable subscriptions |
| get_location_controller, get_messages_storage, get_secret_chat_helper, get_media_controller | unported members fail explicitly |
| send_text | implemented plain native send; rich text/reply uses real peer lookup + explicit messages.sendMessage TL request |
| send_message | implemented text/formatting/entities/reply/notify/searchLinks/schedule/markup subset; other fields fail by name |
| send_photo/send_video/send_document/send_audio | implemented native media models with real local file validation, caption entities, account/reply/thread; success means local native enqueue, not upload/server delivery |
| edit_message | text edit plus native editMedia for explicit peer/id/namespace/kind media replacement or spoiler-only edits |
| send_native_media/edit_native_media/send_album (additions) | exact v1 DTO path, including explicit secret identities, album items, namespace-bearing replies, spoiler/TTL fields and native validation |
| NotificationCenterDelegate.didReceivedNotification/java/start_observing/stop_observing | implemented native subscriptions, original (id,account,args) arity and no implicit hook account; unique lease per subscription |
| log/run_on_ui_thread re-exports | same statuses as android_utils |

Raw TL constructors never acquire fabricated hashes/random ids/pts. A **new send
helper transaction** generates its own random_id, while explicit TL requests must
supply theirs. Rich text paths additionally need the permissions enforced by native
getPeer/TL (including raw-network permission); a negative Android dialog id cannot
be guessed as group vs channel and requires an explicit typed peer.

### Files, settings, intents, formatting/reflection

| Public surface | Status |
|---|---|
| file_utils.get_plugins_dir/get_plugin_dir/get_plugin_cache_dir/get_files_dir/get_cache_dir | implemented native scoped paths; SDK .data/id behavior retained |
| get_images_dir/get_videos_dir/get_audios_dir/get_documents_dir | stock documented per-plugin filesystem fallback, not access to Telegram's private media cache |
| ensure_dir_exists/list_dir/write_file/read_file/delete_file/write_file_bytes/read_file_bytes | stock real filesystem operations with implemented audit providers |
| FilesController.register/unregister | implemented with ready NativeServices; actual site availability comes from its exportedMethods |
| FilesController.icons_supported | false: Android icon factories are platform-blocked; no fabricated icon support |
| plugin_settings.coerce_value/decode_values/encode_values/invalidate | stock |
| plugin_settings.get_setting/set_setting/get_settings/remove_setting | implemented native persistence and actual SDK mirror semantics |
| plugin_settings._save_settings_to_file (compatibility surface) | implemented dirty-mirror full replace and real key deletion |
| IntentsManager.new_global_before_handler/new_global_after_handler/unhandle; HandlerHandle.unhandle | stock filter/signature mapping + implemented leases and actual native result-bearing before barrier |
| IntentsManager.parse | stock urllib parsing |
| markdown_utils.parse_markdown/parse_html; ParsedText | stock parsing |
| MarkdownEntity.to_tlrpc_object; text_formatting.parse_text | stock parsing/materialization over schema-backed TL constructors |
| text_formatting.parse_raw, RawEntity, TLEntityType | stock |
| hook_utils.find_class | stock resolution/permission wrapper over explicit registry and unchanged C fallback |
| get_private_field/set_private_field/get_static_private_field/set_static_private_field; get_field/set_field aliases | stock helpers working on reflected Python ports; arbitrary native/JVM private fields are not emulated |
| extera_utils.classes.PyObj.create, JavaHelper/J/ClassHelper, JAccessAll/JNotUseGetterAndSetter/JIgnoreResult | stock Python wrappers over reflected ports; adapter implements actual JIgnoreResult return-discard while preserving method effects |
| jgetmethod/jsetmethod/jfield/joverride/joverload/jmethod/jMVELmethod/jMVELoverride/jconstructor/jpreconstructor | stock descriptor decorators; Java class generation is platform-blocked |
| classes.Base.new_instance/new_java_instance/from_java/java_class/bind/release, java_subclass, super | platform-blocked JVM/Dex class generation; no fake subclass execution |
| classes.forget_plugin_classes | stock cleanup |
| pip_controller.restore_sys_path/bundled_version/is_provided/ensure_requirements/remove_requirements/installed_packages | implemented read-only provided dependencies; runtime install/download is blocked |
| elyx_runtime archives, dev_server/debugpy.listen | platform/dependency prerequisites; no archive execution or debugger-session claim |

### ui.alert.AlertDialogBuilder

| Methods | Status |
|---|---|
| constructor (message/loading/spinner), set_title/set_message/set_view/set_items | live native model updates; loading/spinner default noncancelable; portable widgets and named item icons; Bool is not a numeric style |
| set_positive_button/set_negative_button/set_neutral_button | implemented; original `(builder,which)` callback arity |
| make_button_red | implemented native destructive-button semantic |
| set_cancelable/set_canceled_on_touch_outside/set_progress/set_dim_enabled | implemented native model/update |
| get_context/set_on_dismiss_listener/set_on_cancel_listener/set_on_back_button_listener | implemented context and original `(builder)` arity |
| create/show/dismiss/get_dialog/get_button | implemented lifecycle; create does not claim presentation, isShowing reads actual native visibility |
| set_top_animation/set_top_animation_is_new/set_top_image/set_top_drawable/set_dialog_button_color_key | platform-blocked Android resource/drawable APIs; no zero resource ids |
| set_message_text_view_clickable/set_blurred_background | native messageClickable/blurredBackground/blurBehind fields; links remain behind the native intents/scope gate and blur follows Reduce Transparency |

### ui.bulletin / ui.settings

| Surface | Status |
|---|---|
| BulletinHelper.show_info/show_error/show_success/show_simple/show_two_line | implemented native bulletin models |
| show_with_button/show_undo | implemented distinct action/undo leases and terminal cleanup |
| show_copied_to_clipboard/show_link_copied/show_file_saved_to_gallery/show_file_saved_to_downloads | implemented notifications only, as original; these do not perform the underlying file save |
| Header/Divider/Switch/Selector/Input/Text/EditText/Slider; Slider.normalize | stock declarations/normalization and SDK serialization |
| Text subpages, callbacks, long callbacks | stock identifiers + implemented native settings callback map |
| Custom, SimpleSettingFactory.build_view/getInstance/instance/java/to_item, PluginItemFactory alias | implemented factory/data bridge when it produces a portable widget; arbitrary Android View/Canvas remains blocked |
| native settings row icons | semantic string/SF Symbol references; unresolved Android numeric resource IDs fail explicitly |
| TextView/EditText/ImageView/LinearLayout + LayoutParams | logical-point padding, dimensions/margins/weight, named fonts/images and visibility; numeric Bool coercion rejected |
| live listener changes / settings refresh | stable native wrapper handles; values captured before click; refresh replaces rows and SDK callback IDs through generic callbacks |

## Config mirror and exact 308-ID receipt

`_config.py` + generated `_config_manifest.py` register ExteraConfig and the actual
Neko/Na/Kotlin Config classes. Source ConfigItem Bool/Int/Long/Float/String operations,
live field/getter aliases, enum values, inversion/percent conversions and avatar
overloads use real registered native keys. There is no source class named KTConfig.

`tools/compat/sdk_config_manifest.py` reads the pinned parity inventory, original
Java/Kotlin/field-alias sources, domain key receipts and actual typed Core definitions.
It emits **one compatibility_apis record per exact overload ID** in
[`sdk-config-parity.json`](sdk-config-parity.json): 220 mapped aliases, 44 original
compat-storage methods and 44 utility/unresolved methods. Actual registration,
type and canonical-key evidence is retained separately for each API.

Strict mirror reads omit the optional native fallback argument. Missing schemas
raise a named unsupported error, all access requires settings, native public writes
revalidate, and credential values are denied. Native defaults are not fabricated
from Android declaration defaults. `chats.showTextTranslate` is canonical.

The 44 original global compatibility-storage overloads need a native global
namespace; per-plugin storage is not equivalent. Runtime safe/engine/developer
metadata and NativeUI manager members need their actual provider contracts. Those
exact IDs retain blocked/unsupported receipts rather than fake false/zero values.
The SDK receipt supersedes Tools' 12 classification-only overload records; omit
those older records when merging both fragments to avoid conflicting owners.

Current receipt: **179 implemented SDK mappings**, **102 blocked overloads** and
**27 explicitly unsupported utilities**. The source partitions remain exactly
220/44/44; these counts describe API assembly, not new client/UI features.

Regenerate only SDK outputs after a native definition/key handoff changes:
`python -m tools.compat.sdk_config_manifest --write`; verify with `--check`.
The parity generator, original sources and main inventory remain read-only inputs.

## Concrete Java port scope

ArrayList/LinkedList list operations, HashMap/LinkedHashMap, HashSet, String UTF-16
length/substrings, Integer/Long casts, Boolean, Object reflection descriptors,
Runnable/interfaces, File paths/operations, Uri, UUID, Arrays/Collections, System
clock. These are partial class ports with defined members, not a JVM standard
library. Unimplemented members raise. No permissive __getattr__ → 0/None behavior.
Exact generated TL aliases and result-type bases are lazy-registered; unavailable
old-layer aliases are not marked as Python-supported. The count of registered
names is not a plugin compatibility statistic.

## Verification

`test_sdk_adapter_wave2.py`: registry/data/reflection; literal reserved settings
keys + dirty mirror; replacement menu leases; actual SDK dialog callbacks, widget
edits, visibility, settings, share, BottomSheet; TL response/error/account, rich text,
caption entities, cancel, media; owner queues/background handoff; real SDK file/
intent registration; admission failure, callback exceptions, handle budget, silent
replacement, stale generations; owner-binding validation; protected global settings.

`test_ios_runtime.py`: prior lifecycle/audit/permission suite, real pinned bundle
imports and genuine frozen-os regression retained. All tests use fresh processes
with 20-second hard timeouts, own source fixtures and strict native host responses.
The actual SDK/registry/adapter code executes; no external plugin corpus is run.

Accepted SDK2 focused baseline: **33 passed on Python 3.12.10 and 3.14.8** across the four
SDK/source/native-fixture Python test files, including Config permissions/overloads, live discovery,
early background task retirement, void results, controller snapshots, notifications
Pill data/layout/scoped-callback ADTs, TL transforms and the exact two native TL
Python fixture sources. The legacy Runnable assertion now checks void plus the
same owner/account side effects; an explicit echo callback independently checks JSON results.
Every scenario asserts zero fixture handles/native resources on unload. The separate
source-receipt regeneration check passed after refreshing the selected current Core
handoff snapshot. Exact commands and JUnit paths are in `tests/sdk-python-checks.json`.

Subsequent NativeUI SDK stitch: **8 distinct targeted scenarios passed on each
interpreter** (six-case run plus UI/lifecycle/callback regression recheck). This
keeps the accepted 308-ID receipt at 179 implemented / 102 blocked / 27 unsupported.
Changes, exact results and native-model assertions: `sdk-ui-source-handoff.md`.

Reviewed legacy suites: **166 passed / 4 skipped on 3.12**, including the existing
real C owner-token extension for bridge tests; **142 passed / 3 skipped on 3.14**
for the Python-only selection. Each suite runs in a fresh UTF-8 process capped at 20s.
Reports: approved-temp `sdk-legacy-slice-py312/report.json` and
`sdk-legacy-slice-py314/report.json`.

The updated real Swift+C+SDK driver, source boundaries, exact command and report
fields are in [`sdk-native-probe.md`](sdk-native-probe.md). Its newest native child
has not run on this Windows host.

### Pill binding handoff

The actual native Pill providers/header integration are owned by the Pill agent
and coordinator. SDK data classes are registered under their original app.* names
(the existing exteraGram aliases resolve to those classes). Mutable layout drafts
preserve their object identity and unsaved edits; unknown/dormant IDs survive.
BasePill supplies explicit content/phase/optional Unix-ms/progress DTOs and never
subclasses a placeholder Android View. Loading alone does not invent a ready reading.

The published `pills-wire.md` and PluginPillBridgeExtension are now consumed by
`_pills.py`; native owns persistent ID aliases, quotas, account leases, timers and
rendering. Raw layout Config fields use that original/native ID projection.
Exact supported methods and v1 enumeration/batching boundaries: `sdk-pills.md`.

### TL phase 2 handoff

`hook_priority_json(hook,name,canonical_name)` is exported. It reads the real
BasePlugin ledger and uses request/update/container routing plus common substring
registrations; empty matches return JSON null, matching priorities use max. Generated
hookNames and canonical method types drive matching. Two short-name collisions in
the generated table are retained as ambiguous aliases instead of rejecting the schema.

`snapshot.tl` is decoded for observational true **and false**; request/response/
update/container arguments retain the real TL classes/vectors. Read-only nested
context is `_exteraless_tl_context`, outside `_values` and replacement JSON. RPC
errors decode separately. DEFAULT/CANCEL preserve the original input value.

The new native driver child exercises actual Host transformTL ordering, per-plugin
schema normalization, MODIFY_FINAL, CANCEL, invalid replacement isolation, update
and container registrations, error decoding and immutable metadata. Its Foundation
normalizer consumes the real generated schema; it does not claim Telegram network
or state application. Both child processes have independent 30-second hard limits.
