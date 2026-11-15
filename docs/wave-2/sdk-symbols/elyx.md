# Elyx: 262 exact SDK source routes

**262/262 original IDs mapped, with no unknown or duplicate IDs.** The individual
contracts, ordered source routes, limitations and evidence are in
[`elyx.json`](elyx.json). All `ported`, `verified` and
`native_execution_claimed` flags are **false**.

The principal integration gap is concrete: normal iOS inspection and loading
accept only `.py/.plugin`, so the preserved `.elyx/.eaf` pipeline is not reached.
Two additional P2 source counterexamples are recorded below: generic Elyx proxy
construction and the dev-server command handoff.

## Source boundary

- Inventory: `docs/parity/sdk-surface.json`, SHA-256
  `ce7b067fdcffc440ba3640ac194c2eef8a68192a80410cbcb3a593e0d9cf64d8`.
- Working-tree source review; HEAD observed as
  `9bfce05f708fba472ca942bcfe355914847a347d`. The raw-byte hashes in JSON, rather
  than a moving HEAD or an earlier test receipt, identify the reviewed inputs.
- Original root:
  `third_party/exteraless-android/TMessagesProj/src/main/python/`.
  Runtime SDK root: `python/sdk/`.
- **36/36 Python SDK files are byte-identical to the Original tree**, including
  **12/12 Elyx files**. Original and SDK hashes for those 12 files are both pinned.
- Only the two new `elyx.json` / `elyx.md` files are authored for this scope.
  SDK, implementation, scanner and existing receipts are read-only inputs.
- This review executed data-only JSON/ID/anchor/hash checks. It did not import
  SDK/plugin modules, run plugin fixtures, start native tests, query CI, or make
  network/account/device calls.

`metadata` describes the exact declaration/re-export, including class symbols
and dataclass fields. `pure-sdk` identifies a specific preserved Python body;
it is not a claim that PluginHost admits an archive. `native-adapter` identifies
an installed, concrete provider, including the Python `java.io.File` port.
`partial` names a working branch and a specific missing route.

### Counts

| Module | IDs | Metadata | Pure SDK | Native adapter | Partial | Unsupported |
|---|---:|---:|---:|---:|---:|---:|
| `elyx_runtime` | 16 | 8 | 4 | 0 | 4 | 0 |
| `.archive` | 35 | 23 | 11 | 0 | 1 | 0 |
| `.assets` | 42 | 14 | 20 | 1 | 0 | 7 |
| `.dev_commands` | 14 | 11 | 2 | 0 | 1 | 0 |
| `.errors` | 8 | 8 | 0 | 0 | 0 | 0 |
| `.facade` | 24 | 15 | 6 | 0 | 2 | 1 |
| `.loader` | 38 | 31 | 5 | 1 | 1 | 0 |
| `.localization` | 25 | 14 | 6 | 0 | 5 | 0 |
| `.metadata` | 20 | 10 | 8 | 0 | 2 | 0 |
| `.namespace` | 22 | 15 | 7 | 0 | 0 | 0 |
| `.settings` | 14 | 5 | 2 | 7 | 0 | 0 |
| `.utils` | 4 | 3 | 1 | 0 | 0 | 0 |
| **Total** | **262** | **157** | **72** | **9** | **16** | **8** |

There are zero standalone public callback-override declarations in this
partition (`plugin-contract: 0`). The supplied implementations inside `gen/gen2`
remain plugin callback contracts; the factory functions themselves are `partial`
because their generic adapter branch has a concrete constructor defect.

## Actual iOS startup and bridge route

1. `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:146–157`
   creates `PluginHost` with `TelegramPluginServices`, then installs
   `NativeBridgeBinding`. Lines 167–237 install the actual UI/TL/native/pill/config
   extensions. This is the application composition, not a speculative class name.
2. `swift/PluginHost/Sources/PluginHost/PythonRuntime.swift:111–135` installs
   `virtualjava` with the C `BridgeBackend`, then calls
   `exteraless_runtime.configure`.
3. `python/exteraless_runtime/__init__.py:59–89` binds one plugin ID, validates
   native bootstrap and directory agreement, requires an empty SDK registry,
   then invokes `Platform.install`. `_platform.py:195–325` installs the real
   service seams; `_facades.py:19–24,88–95` registers `PythonBridge`.
   There is no separate Elyx `initContext` override to assume.
4. Native calls use `_platform.py:89–95` →
   `python/bridge/_exteraless_bridge.c:3252–3282,2005–2055` →
   `NativeBridgeBinding.swift:73–95` → `BridgeServices.dispatchJSON:200–245` →
   the exact operation/provider. C injects its bound identity; Python request
   fields do not choose another plugin owner.

### ELYX-GAP-01 — P1, existing source-only platform exclusion

The actual inspector is
`PluginHost.swift:926–943 → exteraless_runtime.metadata_json`; load is
`PluginHost.swift:1273–1286 → exteraless_runtime.load_json`.
Both pass through `_source_path` at `python/exteraless_runtime/__init__.py:43–47`,
which rejects archive suffixes before an Elyx body runs. Installation at
`PluginHost.swift:962–989` also stores every file as `<id>.plugin`.

A valid own `demo.elyx` therefore fails the suffix gate. Renaming ZIP bytes to
`.plugin` selects the source AST parser; it does not select the SDK's archive
dispatcher. The preserved dispatcher is
`python/sdk/extera_utils/plugin_loader.py:2704–2710,2761–2805`, and the actual
archive pipeline is `python/sdk/elyx_runtime/loader.py:262–351`.

Further integration requirements visible behind that gate:

- Elyx IDs use `^[A-Za-z0-9_]{2,32}$`; configure/native storage use the source
  validator and a letter-first native ID. No ID translation is installed.
- Elyx `metadata.py:120–135,202` emits
  `requires = {id: {min_version, url}}`. Native
  `PluginModel.swift:21–22,129` expects `[String: [String?]]`.
  `PluginRuntimeProtocol.swift:29–44` unwraps `metadata` or `meta` and directly
  decodes `Plugin`; it has no conversion for nonempty Elyx `requires` objects.
  **The envelope is accepted; the nested value shape is not adapted.**
- `load_plugin_record` registers its environment before entry execution and
  attaches the instance/record, but lifecycle belongs to the outer SDK loader.
  The archive branch does not call the source branch's `_ensure_requirements`.
- Swift uninstall at `PluginHost.swift:997–1008` does not call Elyx
  `purge_plugin`; state teardown and archive-derived disk cleanup are separate
  preserved Python APIs.

## Archive, namespace, assets and data contracts

### Archive and import paths

`archive.py:203–255` uses
`<plugins_dir>/.elyx_extracted/<id>/<sha256[:16]>`, a completion marker, PID temp
directory and `os.replace`. A complete marker permits reuse without checking
each extracted file. The stable `ElyxPlugins/<id>` filesystem reference uses a
symlink with a best-effort copytree fallback. Final copy failure is swallowed.

`process_wheels:290–351` handles sorted direct `.whl` children only, caches by
filename stem, removes stale stems, and returns local search directories. A
same-stem changed wheel can reuse the previous extraction. The namespace search
order is archive root, optional nested-entry directory, then extracted wheels
(`loader.py:126–143,305–307`).

`namespace.py:139–153,311–355` resolves Python source/bytecode, packages,
namespace directories and JSON/YAML/YML/TXT data modules. It has **no native
extension loader**. Extracting Android `.so` bytes or declaring a wheel does not
produce an iOS native implementation; bytecode must match the real interpreter.

Canonical imports use `ElyxPlugins.<id>.*`. `_WrappingLoader:204–227` injects the
plugin-local `__import__` into the module's builtins; reserved and stdlib roots
stay ordinary imports. `_ElyxIdFinder:358–375` supplies eligible bare-ID aliases,
and eviction checks alias loader identity. `facade._calling_plugin_id:51–62`
recognizes canonical frames only: a bare-ID frame by itself is not a bound
`elyx` environment.

### Filesystem / audit boundary

The actual SDK audit attributes **plugin frames**, not merely the surrounding
load context (`plugin_loader.py:819–835,892–926`). Thus loader-owned archive
extraction before entry execution must not be described as an arbitrary plugin
file operation.

Direct plugin operations use `audit_gate.py:500–599,661–771` and the installed
iOS overrides in `_audit_paths.py:161–254`. Owned roots are native per-plugin
files/cache and `<plugins_dir>/.data/<id>`; blanket system `TMPDIR` access is not
granted. Runtime code/vendor paths are read-only, and native protected paths are
refreshed at runtime scopes. Path resolution actually uses
`os.fspath/os.fsdecode/realpath` in `_audit_paths._real:17–24`.

`Asset.from_path` specifically accepts `str`, `Path`, or `getAbsolutePath`-bearing
objects; it does not accept every arbitrary `os.PathLike`. Registered
`_java_types.File:557–586` implements both `__fspath__` and `getAbsolutePath`, so
that concrete argument works. `Asset.java_file` reaches this registered Python
port through `jclass`; it does not need a generic Swift File constructor.

`temp_asset_from_url:152–169` performs synchronous `urllib.request.urlopen` and
file copies into a system-temp directory. It supplies no timeout/size cap or
automatic cleanup. Its source route is the actual CPython network/file audit
path, including native permission queries; no HTTP was performed here.

### Missing asset conversion providers

Each converter has an individual unsupported entry. The terminal missing
operations are:

| Exact method | Required provider absent from the registered/native surface |
|---|---|
| `Asset.to_drawable` | `Drawable.createFromPath` |
| `Asset.to_image_location` | `ImageLocation.getForPath` |
| `Asset.to_bitmap_drawable` | `BitmapFactory.decodeFile`, `Bitmap.createScaledBitmap`, `BitmapDrawable` constructor |
| `Asset.to_svg_drawable` | `SvgHelper.getDrawable/getBitmap`, sized `BitmapDrawable` constructor |
| `Asset.to_svg_bitmap` | `SvgHelper.getBitmap` and Bitmap result |
| `Asset.to_svg_thumb` | `SvgHelper.getDrawable`, `PorterDuff.Mode.SRC_IN`, `PorterDuffColorFilter`, drawable tint/alpha methods |
| `Asset.to_lottie_drawable` | `RLottieDrawable` constructor/animation provider |

`AndroidUtilities.dp`, `Theme.getColor` and `java.io.File` have concrete
subroutes, but cannot replace the missing terminal drawable operations.
`PlatformContext` also has no Android `getResources`; `_resources` catches that
failure and returns None. Relevant provider anchors:
`_java_types.py:647–672`, `_ui.py:238–245,392–422`,
`BridgeServices.swift:379–380,422–482,772–807`.

### Metadata and localization

Preserved parser behavior is described from bodies, including discrepancies
with broad comments:

- `metadata.parse_mapping_file:74–94` treats `.json` as JSON, `.py` as executable
  Python mapping source, and other names as safe YAML. `_exec_python_mapping:58–71`
  performs `compile/exec` and collects simple public non-callable values.
  Accordingly, archive metadata/localization scanning is **not universally
  code-execution-free**, although it does not import the main entry module.
- `_normalize_keys:44–55` keeps the first normalized key, rather than always
  preferring the plain spelling. `parse_refmap:158–179` skips null values and
  stringifies others; its UTF-8 decode is outside its parse-error wrapper.
- The PyYAML 6.0.3 pure-Python projection is pinned at
  `python/runtime/dependency-lock.json:165–178`.
  `_dependencies.create_provider:153–213` checks packaged roots and metadata.
  Dependency metadata is not an executed Elyx import or vendor-payload receipt.
- `Strings` supports explicit locales, override, English/default/key fallback,
  Python formatting and its fixed Slavic plural rule. Locale filenames use the
  final underscore suffix, so `strings_en_US.json` means locale `US` here.
- `get_current_locale:48–69` tries the override, then
  **`java.util.Locale.getDefault().getLanguage()`**, then CPython locale functions
  and finally `en`. The Java class/method has no provider. Native
  `LocaleController.getLocaleStringIso639` exists in `BridgeServices.swift:630–646`
  but is never called by this body. The CPython fallback is retained; its observed
  value or agreement with Telegram's language is not assumed.

## Settings: concrete persistence, exact original fallback behavior

For a settings module imported after normal configure:

`SettingsController` → registered `_facades.PythonBridge` →
`Platform.getSetting/setSetting` or installed `exportSettings` →
`_settings.read_values/update` → C/native bridge →
`BridgeServices.callRuntime(getSettings/updateSettings)` →
`PluginServiceStorage.settingsJSON/writeSettingsJSON`.

`getSettings` returns opaque JSON text. Export uses the original SDK's
JSON-per-value encoding, then `decode_values` reverses it. Ordinary strings and
transport-looking keys therefore remain settings data. Reads/coercion,
default-vs-stored-null semantics and aliases are individually mapped.

Important exact limitations:

- `settings.py:16–19` captures `PythonBridge` once. An early import which stores
  None keeps the local-memory branch; `_platform.install` does not rebind this
  Elyx module. After normal configure, the registered facade exists.
- Elyx getters/setters retain their original broad catches: native wrong-owner,
  wrong-worker, corrupt-store or invalid-value failures can become `{}`, a
  default, or a None-returning write. BasePlugin's stricter replacements do not
  automatically replace these separate class methods.
- `clear_settings:93–105` **enumerates and writes JSON null to every key**. It
  never calls native `clearSettings/removeSetting`. Keys remain present with
  null values; the Android controller likewise stores the literal JSON string
  `"null"` (`PluginsController.java:1148–1156`). The no-bridge branch instead drops
  the in-memory dictionary. This is preserved source behavior, not a new reset
  implementation.
- Optional refresh is `_settings.py:36–39` →
  `PluginUIBridgeExtension.swift:273–283` →
  `PluginUISettingsRefresh.swift:9–18` →
  `PluginSettingsController.swift:130–137`. It requires a current native
  owner/account scope and posts work to main; storage and refresh are separate
  operations. No visual result is claimed.

## New source counterexamples

### ELYX-P2-01: generic `gen/gen2` constructor mismatch

Source witness, **not executed**:

```python
I = jclass("org.telegram.messenger.Utilities$Callback")
gen(I, "run")(lambda value: None)
gen2(I, run=lambda value: None)()
```

These interfaces are absent from `_java_types.install:647–672`. The real chain:

1. `virtualjava.proxy.get_class:204–219` creates a `JavaClass` inheriting
   `JavaInstance`.
2. `dynamic_proxy:92–109` returns its `DynamicProxyMeta` base.
3. `DynamicProxyMeta.__call__:80–89` sets `_fqcn/_backend`, then invokes the
   generated initializer.
4. Elyx `facade.py:140–143` / `165–166` calls `base.__init__(self)`.
5. `JavaInstance.__init__:141–143` requires `(self, fqcn, backend)`: two required
   arguments are missing. The failure occurs before native callback consumption.

The SDK proxy guard skips dunder methods (`plugin_loader.py:2010–2023`), so it
does not repair `__init__`. The lazy `elyx.Callback`, `Callback2`, `Callback3` and
`CallbackReturn` aliases select those generic interfaces at `facade.py:195–202`.
Registered Python `Runnable` and `OnClickListener` bases follow a compatible
constructor branch; that is not a claim of an executed native callback.

### ELYX-P2-02: dev-server argument shape

An authenticated request with `{"@":"elyx_ping", ...}` is selected by
`dev_server.dispatch:257–284`. `_cmd_elyx:230–241` calls `handler(request)`.
The preserved handler signature is
`handle_dev_command(command, params=None)`; `dev_commands.py:238` stringifies
that entire dictionary. Its name begins with `{`, so it cannot match
`_HANDLERS["elyx_ping"]` and returns `ok=false` / unknown command.

The same mismatch blocks list/compare/changes before their state-specific work.
This defect is inherited in the byte-identical Android SDK, not asserted as a
new iOS regression. An integration adapter needs to pass command and params
separately. No dev-server, socket or plugin was started to establish this source
counterexample.

Even with correct handoff, live-sync consumes this interpreter's Elyx `_states`
and outer Python `plugin_loader.plugins`; it has no host-wide native registry
snapshot. Its fallback evicts modules and returns `reloaded=false`, rather than
claiming an actual Swift worker reload (`dev_commands.py:165–200`).

## Generic bridge boundaries checked in the actual source

- `jclass`/`get_class` can manufacture an unregistered proxy. C
  `bb_member_kind/class_exists:2711–2757` uses manifest metadata; actual calls
  still go through `bb_call:2279–2355` and the installed dispatcher when no legacy
  service is registered. Neither a type name nor a reported method proves an
  implementation. The exact native Runtime metadata seam is installed at
  `_platform.py:323–325`.
- `finder.py:170–176` stores `set_call_fallback` in `_CHAQUOPY_STATE`.
  `JavaClass.__call__:58–59` calls backend construction directly; that setter
  does not supply a missing Elyx constructor. `mvel_execute` similarly reaches
  unimplemented `org.mvel2.MVEL.compileExpression/executeExpression`; the real
  HashMap port and native menu-condition DSL do not execute MVEL here.
- SDK thread marking (`plugin_loader.py:1396–1449`) and `Platform.mark:73–87`
  do not change the owner worker. `Platform.call` and callback invocation check
  that worker. `_scheduling.py:22–62` has a narrow direct `postToOwner` transport
  exception for posting; it is not unrestricted background host access.
  C `engine.c:305–358` checks native thread ownership and restores/saves the
  owner's tstate; `native_dispatch_request:2038–2040` retains the current GIL.
- Generic callback values still cross the actual `_codec.py:32–93` and C
  `marshal_value_inner:1507–1646`/UTF-8 paths. In particular,
  `virtualjava/arrays.py:15–19` validates one UTF-16 code unit for `jchar`, while
  C JSON uses `ensure_ascii=False` (`_exteraless_bridge.c:3700–3703`) and converts
  to UTF-8 (`2029–2032`). Local acceptance of a lone surrogate is not evidence
  of native transport support. No generic character/serde promotion is made.

## Source pins

The following SHA-256 values apply equally to the original and SDK Elyx files.
The JSON additionally pins every referenced adapter/native input, the immutable
inventory and the pre-existing acceptance report.

| Elyx file | SHA-256 |
|---|---|
| `__init__.py` | `c727c43ef32e020e8669391ea4721269c429592ee1712286acc4d925a0882cbf` |
| `archive.py` | `d35fe1a2e0f2a28d2fce29d3b5f0fcbc7a8c05c5667b488c3c8afb180ca660c2` |
| `assets.py` | `06f74f9ed95ad0e6402f8d9f7498431e4d0d81935bbe704493f62d4f3bc6320b` |
| `dev_commands.py` | `5d33aaac3e89f36d3eb7d6bf7f0ee43219b5d871f18c68aec837310e8e8b2ee3` |
| `errors.py` | `91903e8ac644557c628f5ef7dbb756a257c86bb090428db513ca626d9c45a66a` |
| `facade.py` | `a61a3b1920f3daf9fbb4d42df9af65f46f9da03782f847c3dc8463a291c0f390` |
| `loader.py` | `a09eddf36ae77415fbf41e58aed3b09ccb4ce27759aea6ba9814ad8129bc0e12` |
| `localization.py` | `b8a4d27642c27996dbd99cba7a1597bb73b8a3878920cc23b0eed416b47136cf` |
| `metadata.py` | `dfedf130c7501ff0c67350ceba51ee068e8664c6faca3aaa1760b9dae4dc7bd3` |
| `namespace.py` | `1b9a33a09318d0c19a7e64696028089def15cecff2a75a4c0ad6dfbde7d51966` |
| `settings.py` | `d240700bad642540941beb02b421be23b37597ce12dea7d86f55be4ef753d0a7` |
| `utils.py` | `51b4de5c64622d025045475c0c8a1e7cdf91abc6590cb957b96689c992e9435a` |

## Validation and existing execution evidence

**Data checks passed:** 262 exact IDs, 865 original/route anchors, 65 matching
SHA-256 pins, and 36/36 byte-identical Original/SDK Python files. Promotion flags
remain zero throughout.

Data-only validation checks exact inventory equality, unique IDs, original
path/line/name correspondence, required schema fields, allowed dispositions,
all-false promotion flags, existing/in-range route anchors, SHA-256 pins and the
36-file Original/SDK byte comparison. No new test receipt is manufactured from
these checks.

The existing independent runtime acceptance is
[`runtime-native-acceptance.md`](../runtime-native-acceptance.md), run
`43738810843`, commit `136c946f87194221342a83b2b06743fe4cc3fc7c`:
three macOS SDK child processes and standalone iOS bridge checks (219 total).
Its own scope excludes installed-app/UIKit behavior and production Telegram
network/state execution. It does not verify these 262 Elyx IDs, archive loading,
Kotlin native UI, the new source counterexamples, or an in-progress app build.
