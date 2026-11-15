# SDK Config binding — final registered-cohort handoff

Final receipt: **272 implemented / 4 blocked / 32 unsupported**, exactly 308 IDs.
This supersedes the earlier 260/16/32 snapshot. Current source inventory and the
SDK02/03/04 + HNS-F03/F04 follow-up are in `sdk-adapters-final.md`.

## Delivered native/SDK contracts

- `ExteraConfigCompatibility.swift`: **22 closed global definitions / 44 original
  storage overloads**, under `compat.exteraconfig.<sourceKey>`. Original defaults,
  enum ordinal order and types are pinned by the generator and Core fixtures.
  These are compatibility state, not new client feature toggles.
- `ClientSettingsBridgeExtension`: existing get/set plus **setClientSettings**
  (one opaque JSON string → strict Core decode → one applyPublic transaction) and
  **getClientSettingMetadata** (registered public default/type/options as bounded
  opaque JSON). Unknown namespaces are not registered; secret keys and learned
  aliases are denied. AI closed valueShape and protected credential destinations
  remain enforced by the real Core public transaction.
- `setForceSnow(boolean)` now submits both actual appearance decoration keys in
  **one native atomic batch**. No two independent setters or Python default cache.
- `PluginConfigBridgeExtension`: thread-safe actual manager snapshots and bounded
  FIFO setters for engine/safe/developer/compact/pinned state. It checks C owner
  epoch and settings permission before admission and again on main before effects.
  The C worker receives `{accepted:true,operationId}` immediately; SDK Java setters
  return None. Completion is not pretended. Existing Runtime controls own disk,
  developer-server effects and nonterminal Host maintenance/hook gates.
- The Runtime projection waits asynchronously for its originating root operation
  to finish before a mode transition. This prevents self-disable from waiting on
  its own C caller. Pending retired-owner commands are cancelled; the executing
  transition is allowed to complete its maintenance lease. Errors use existing
  native logs/status. No engine finalize/reinitialize path was added.
- `ConfigItem.defaultValue` queries current native definition metadata. Missing
  registration fails explicitly; the SDK never substitutes the Android default.
- SDK05 coordinator join: `PluginConfigAuthority` reaches the native writer;
  pinned changes are one `pinnedSet(wanted:installed:)` commit. The SDK accepts the
  registered Java HashSet through its Set interface; the JSON API remains unchanged.

### Exact wire

| Runtime member | args | value |
|---|---|---|
| getClientSettingMetadata | `[registeredKey]` | opaque metadata JSON string, or null for unregistered key |
| setClientSettings | `[jsonObjectString]` | null after atomic public commit |
| getPluginConfig | `[field]` | actual Bool or pinned plugin-ID array |
| setPluginConfig | `[field,value]` | `{accepted:true,operationId:String}` |

Manager fields are closed: engineEnabled, safeMode, developerMode, compactView,
pinned. `compatibilityMode` has an explicit Android ART Profile Saver rejection;
the two PluginsDisableArtOpts methods are not exposed as false-valued native flags.
All methods are in exportedMethods. Metadata/batch bounds are 256 KiB; at most
128 batch keys. Compatibility strings are capped at 64 KiB. Manager admission
retains at most 128 commands / 32 per owner, including executing work.

## Actual root registration — SDK01/02

The App owner applied `sdk-config-binding-root.patch`: the serial root settings
worker includes ExteraConfigCompatibility.definitions and generic UI excludes its
keys. The generator now reads the actual consumed root set and fails if that group
is absent. The 44-overload SDK fixture checks this root before supplying recorder
values; its negative control cannot pass by registering its own missing definitions.
The native TL child uses actual Core ClientSettings and ClientSettingsBridgeExtension
with that root-generated registration expression, not a compatibility-only fixture
registration. Its two SDK plugins exercise 44 calls, reload all 22 values from disk
and check per-plugin isolation. Native execution remains pending the Mac runner.

Connected child declarations are pinned and parsed only from their referenced
initializers: AppearanceAdditionalFeatures.definitions/settingsSectionDefinitions,
the four ToolsNativeModePolicy definitions, and AINativeVisibilityPolicy's native
registration. An extra unregistered array in the same file is not discovered.

## Exact 308-ID receipt

`sdk-config-parity.json` now records **272 implemented / 4 blocked / 32 unsupported**.
Source partition stays **220 mapped / 44 compatibility storage / 44 utility**.
No status is promoted to verified/full-ported. Per-method native calls and source
anchors replace the generic getClientSetting claim.

Of the formerly 102 blocked IDs, the global 44 are implemented; the 13 manager
IDs become 11 real bindings + 2 exact ART exclusions; atomic setForceSnow is bound.
Current native definitions resolve 36 of the 44 key-binding IDs. Four camera/API
or consumable-volume-KeyEvent overloads have exact unsupported dispositions.

Twelve of the previous sixteen blocked overloads now bind actual controls:

| Original field (getter + setter) | Applied native binding |
|---|---|
| neko.uploadBoost | tools.uploadBoost, native complete-resource chunk floor |
| neko.hideAllTab | appearance.hideAllTab, with native recovery-tab behavior |
| appearance.hideAiEditor | appearance.hideAiEditor, preserving Extera getter/setter inversion |
| appearance.hideMessageSummary | appearance.hideMessageSummary, independently inverted |
| neko.rearVideoMessages | tools.videoMessageCameraFacing, explicit Bool ↔ Front(0)/Rear(1) codec |
| icons.useSystemIconShape | appearance.useSystemIconShape, in-app logo shape |

Camera **Ask(2)** has no legacy Bool/two-case enum representation: reads fail by
name and do not change native mode; explicit Front/Rear writes select 0/1. Defaults
still come from native metadata. `disableCrashlyticsCollection` and
`enhancedFileLoader` remain named migration-only unsupported ConfigItems; matching
androidSymbols does not make them live aliases. Legacy false cannot enable collection.

**Four genuine blocked IDs remain**, explicitly corroborated by the frozen AP receipt:

- `compat.ExteraConfig.getTabletMode()` / `setTabletMode(int)`: no forced layout key/provider.
- `compat.ExteraConfig.getUseSystemFonts()` / `setUseSystemFonts(boolean)`: no family selector or supplied bundled-font assets.

Both AP rows have setting_key=null. Automatic layout, Dynamic Type size and bold
weight fallback do not implement these controls. Exact evidence is in
`sdk-config-binding-dispositions.json`; no blanket platform-only promotion is made.

## Checks

- Final expanded SDK cohort: **49 passed on 3.12.10 and 49 passed on 3.14.8**.
  After the App owner's final root-source hash change, regeneration and the four
  focused receipt/registration checks passed again; bindings/statuses were identical.
- The new SDK fixture executes all 44 compatibility getters/setters; two fresh
  plugin workers observe the same global namespace and separate plugin storage.
  It checks actual metadata defaults, enum/Bool separation, atomic failure,
  secret/alias rejection, accepted-versus-delivered manager changes and permission loss.
- Eight Core XCTest cases cover the real persistence/metadata/batch implementation,
  original defaults, exact Int64/JSON, secret aliases/closed AI shape, FIFO and
  self-disable/retirement. **Authored, not run here:** swift/swiftc are unavailable.
- Run after the coordinator's Core build, with an outer 30-second process bound:
  `swift test --package-path swift/ExteralessCore --skip-build --filter ExteraConfigCompatibilityTests`.
- Root registration/UI exclusion are applied; scoped source/whitespace checks pass.
  Python/native-recorder checks do not establish a native app-provider execution pass.
  No CI/commit/push.

## Closed owned files / next cohort

Config source is frozen in:

- `swift/ExteralessCore/Sources/ExteralessCore/ExteraConfigCompatibility.swift`
- `swift/ExteralessCore/Tests/ExteralessCoreTests/ExteraConfigCompatibilityTests.swift`
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift`
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift`
- Runtime composition + `applyGlobalPluginConfig` projection hunks only in
  `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift`
- Python `_config.py`, generated `_config_manifest.py`, generator and Config tests.

Runtime's later writer/read/batch guards are coordinator/UI owned and are included
as current dependency fingerprints, not overwritten with an older stitch hash.

HNS04 SDK boundary is also implemented from `host-settings-execution-contract.md`:
optional nonnegative Int32 `account` positional argument, old arities preserved,
Bool rejected, storage and callback inside the captured account scope. Host files
were not edited. HNS02/03 and TLN06/07/08/11 native fixtures are authored; their
Mac execution remains pending. Follow-up details: `sdk-adapters-final.md`.
