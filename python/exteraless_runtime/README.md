# iOS SDK loader adapter

Wave-2 API/provider coverage and integration hunks:
[SDK handoff](../../docs/wave-2/sdk.md), [wire contract](../../docs/wave-2/sdk-wire.md).
The owner host binds C's immutable random epoch with `xt_set_owner_token`, then
SDK `bind_owner_json` before load, and routes native FIFO release through
`release_handles_json`. C injects pluginId/ownerToken; Python does not author them.

`exteraless_runtime` uses the actual `python/sdk/extera_utils/plugin_loader.py`.
Canonical imports are `extera_utils.plugin_loader`, `base_plugin`, `ui.settings`
(the `python/sdk` directory is an import root). Do not separately import those
files as `sdk.*`: that creates another registry and another BasePlugin identity.

## Bootstrap / API

On the plugin's dedicated worker, after Swift has called `xt_bind` and
`virtualjava.install(BridgeBackend(service="java", manifest_path=EXPLICIT_PATH))`:

```python
import json
import exteraless_runtime as runtime
runtime.configure("demo_plugin", "/.../plugins", "/.../settings")
runtime.metadata_json("/.../plugins/demo_plugin.plugin")  # SDK metadata object
# Host already bound the native C epoch; native_owner_epoch is its captured token.
runtime.bind_owner_json(json.dumps(native_owner_epoch))
runtime.load_json("/.../plugins/demo_plugin.plugin")
# {"metadata": {...}, "handles": {"app_event": bool, "pre_request": bool,
#  "post_request": bool, "update": bool, "updates": bool, "send_message": bool},
#  "has_settings": bool}
runtime.dispatch_json("on_app_event", '{"event_type":"app_start"}')
runtime.dispatch_json("on_send_message_hook", '{"account":0,"params":{"message":"hi","peer":42}}')
# {"strategy":"DEFAULT|CANCEL|MODIFY|MODIFY_FINAL", "params": {...}}
runtime.settings_json()                                  # SDK row array
runtime.setting_changed_json("enabled", "true")           # "null"
runtime.setting_click_json("cb_<SDK id from row>")         # "null"
runtime.invoke_handle_json(123, "run", "[]")               # JSON callback result
runtime.unload()                                         # None, idempotent
```

`metadata_json` also works before configure, using the SDK's AST metadata reader;
it never imports/executes the plugin. Only source `.py` / `.plugin` is accepted.
Load errors raise `PluginLoadError` (SDK summary and `.debug` traceback), rather
than a success-shaped empty result. Metadata, callback and unload exceptions
propagate. `SystemExit` also triggers load cleanup and propagates to the engine.

Configuration is immutable per interpreter (repeat of the same arguments is OK).
`settings_dir` records the host layout; Python does not write a parallel settings
store. Swift services own persistence. `getPluginsDir` must agree with the
configured plugins directory. Calling SDK/native APIs from a foreign Python
thread is refused; callbacks re-enter via the native owner-worker queue.

`configure` discovers the sibling `python/vendor` bundle, validates its manifest
and `.dist-info` metadata, and adds that directory after the SDK in `sys.path`.
The complete approved eight-package or twelve-package bundle is supported. Plugin requirements are
checked with `packaging.Requirement` / `SpecifierSet`, actual-interpreter markers,
Requires-Python and transitive/extra requirements. Missing versions, conflicts and
URL requirements fail visibly; no dependency is installed at runtime. See
[DEPENDENCIES.md](DEPENDENCIES.md) for the pinned versions, vendoring CLI and layout.

## Exact NativeRuntime calls

All calls use `_exteraless_bridge.xt_call_host` with this envelope:

```python
{"op": "call", "fqcn": "exteraless.ios.Runtime", "member": MEMBER,
 "args": ARGS, "kwargs": {}, "instance": None, "value": None}
```

No Python-authored request includes pluginId or ownerToken. Native C state supplies both.

| MEMBER | ARGS | Native result |
| --- | --- | --- |
| `getSetting` | `[key, default_value]` | retained native single-value API |
| `setSetting` | `[key, value]` | null |
| `removeSetting` | `[key]` | bool: whether the key existed |
| `getFilesDir` | `[]` | absolute per-plugin files path string |
| `getPluginsDir` | `[]` | absolute path string |
| `getCacheDir` | `[]` | absolute per-plugin cache path string |
| `log` | `[text]` | null |
| `getVersion` | `[]` | version string |
| `getSettings` | `[]` | opaque JSON object string; used by SDK value/bulk reads |
| `setSettings` / `updateSettings` | `[json_object_string]` | atomic replace / merge |
| `clearSettings` | `[]` | reset per-plugin storage |
| `uiRefreshSettings` | `[]` | actual native settings-page refresh |
| `getProtectedPaths` | `[]` | native protected client-settings directories |
| `completeCallback` | `[positive_handle]` | true only after the last scheduled reference; called by callback cleanup |
| `hasPermission` | `[permission_name]` | actual native granted permission bool |
| `isUnsafeMode` | `[]` | actual host unsafe-mode bool |

These signatures match `BridgeServices.callRuntime` and `PluginServiceStorage`.
SDK permission checks are bound to these native results; an unavailable provider
raises instead of taking the SDK's desktop no-JVM fallback.
The SDK uses opaque JSON bulk transport, preserving literal user keys such as
`__handle__` and `__bytes__`. Reads use the native store, distinguishing missing keys
from stored JSON null and preserving the SDK's `coerce_value` rules. Python does
not cache native defaults as if they were persisted values.
Also used: `op="get"`, `fqcn="org.telegram.messenger.UserConfig"`,
`member="selectedAccount"`, `args=[]` (Int32 account **index**).
SDK `run_on_ui_thread` forwards to `org.telegram.messenger.AndroidUtilities`
`runOnUIThread(callback, delay_ms)`. Swift schedules `invoke_handle_json(handle,
"run", "[]")`; a plain Python callable is adapted to this Runnable protocol.
Explicit `"__call__"` / `""` also invokes a callable, and other names invoke an
object's actual method. Other PluginServices calls go to their real
native fqcn; unimplemented native members must raise, never return dummy values.

## Hooks / settings / ownership

Other dispatch payloads follow the SDK argument names:

- `pre_request_hook`: `account`, `request_name`, `request`;
- `post_request_hook`: `account`, `request_name`, `response`, `error`;
- `on_update_hook`: `account`, `update_name`, `update`;
- `on_updates_hook`: `account`, `container_name`, `updates`;
- `create_settings`: `{}` or `{"account": index}` (SDK row array).

Request/update hook results use `{strategy, request|response|update|updates}`.
Snapshots support mapping access and attributes for **provided fields only**;
they are not live Java TL objects. Registration uses BasePlugin's own
`add_hook`/`remove_hook` and `add_on_send_message_hook` flags, including substring
matches. `handles` are the SDK's overridden-method flags; dispatch additionally
checks current registrations. Cross-plugin priority ordering belongs to Swift.

Settings serialization and callback identifiers come from the SDK, including
Header, Divider, Switch, Input, Selector, EditText, Slider, Text and sub-pages.
SDK settings construction failures remain visible SDK error rows/logs. Custom
row descriptors can serialize, but this adapter does not instantiate Android
views. Change callbacks persist first, then run; click callbacks accept zero
arguments or receive `None` for the Android view parameter.

All module execution, constructors, lifecycle, app events, hooks, settings and
handle callbacks run inside SDK plugin context; hooks also bind account scope.
Unload clears SDK click/change/custom registries, local hook/menu refs, settings
mirrors, cached account/queue proxies and the interpreter's native handle table
even when the unload hook fails.
Reload invokes the previous instance's unload hook before the SDK loads again.

## Explicitly unsupported

- Runtime installation of dependencies, native wheels and URL requirements.
  `__requirements__` satisfied by the provided pure-Python bundle are supported.
- Elyx/EAF/bytecode archives and Java/JVM/Dex/Xposed method hooking.
- Native menu/UI/TL/owner-queue operations require the wave-2 providers and owner
  binding described in the handoff. Their absence raises instead of a fake success.
- Arbitrary Android resource/layout/Canvas APIs and synchronous unported controller
  caches: see the coverage table. Explicit asynchronous
  controller/cache/download facades and three native notifications are implemented.
- Media edits/albums/secret sends use the explicit native v1 DTO helpers; native
  validation and upload/enqueue results remain authoritative.
- Android media/cache objects; directory helpers use the real per-plugin native
  files/cache directories. `get_plugin_dir` retains the actual SDK
  `<plugins_dir>/.data/<id>` filesystem implementation; `get_plugin_cache_dir`
  retains the SDK's `plugins/<id>` suffix under the native per-plugin cache.
- Cross-plugin imports that attempt to enter another plugin's native identity.
- Arbitrary native members not implemented by BridgeServices.
- Unknown/stale handles; native callback argument handles must already exist in
  this interpreter's bridge table. JSON bytes/nonfinite-float tags match C.

## Verification

Tests live in `tools/compat/tests/test_ios_runtime.py` with four small local
fixtures. Each case runs in a fresh isolated Python subprocess with a hard timeout.
Native host services/handle transport and the dependency-case distribution
metadata are unit doubles. The adapter, virtualjava, SDK loader, BasePlugin
registration, requirement parser and settings serializer execute as real code.
These tests do not measure plugin-corpus compatibility or execute UIKit/Swift/C.

The Config mirror uses the source-pinned `_config_manifest.py`, actual native
ClientSettings keys and settings permission. Its 308 per-overload receipts are in
`docs/wave-2/sdk-config-parity.json`; unknown schema and private credentials cannot
be replaced by fabricated defaults. Pills use portable DTO classes; stable ID
mapping and rendering belong to the native Pill bridge.

The embedded audit regression additionally executes the real sealed
`python/vendor` bundle without a `files` grant, including a genuine frozen `os`
without `__file__`. See [AUDIT_PATHS.md](AUDIT_PATHS.md) for the reproduced cause,
explicit read-only path providers and foreign-file/DNS denial checks.

Run (pytest must already be installed):

```powershell
& 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' -B -m pytest tools/compat/tests/test_ios_runtime.py -q -s --basetemp='C:\Users\sasha\AppData\Local\Temp\opencode\ios-loader-check'
```

With `-s`, each case prints `IOS_RUNTIME_UNIT_OK` with actual SDK function-call
counts collected by the isolated worker's profiler and native-double call counts.

The core file's **12 scenarios passed on CPython 3.12.10 and 3.14.8**. New SDK
adapter coverage and the real native driver handoff are tracked in `sdk.md` and
`sdk-native-probe.md`. The hard timeout is 20 seconds per isolated subprocess.
The lifecycle/settings case recorded actual SDK `load_plugin` (1),
`get_settings_json` (1), `notify_setting_changed` (3), `dispatch_setting_click` (2),
`unload_plugin` (2), and 60 strict native-double calls. The hooks case recorded
`call_app_event` (4) and `call_send_message_hook` (5). Metadata inspection made
zero host calls and did not import the SDK plugin loader or the plugin module.
