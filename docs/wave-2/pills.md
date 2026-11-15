# PillStack — implementer handoff

## Review remediation

FPP-09/FPP-10 source fixes and new regression evidence are recorded in
[pills-remediation.md](pills-remediation.md): independent `pills.status` Settings
entry with pre-factory context admission; stable Core 4Hz latest-value/trailing
delivery with cancellation and owner replacement. Eight new Core tests and two
native admission tests are written; the earlier green 23-test Pill baseline is
not evidence that these new regressions pass.

## Plugin bridge follow-up

The real five-method `PluginPillBridgeExtension` is implemented. Stable public wire,
callback shapes, persistent ID mapping, exact constructor and Runtime/UI-agent
composition hunks: [pills-wire.md](pills-wire.md). The existing registry/header are
the native consumer; explicit refresh and asynchronous long-press result routing
are connected at their existing UI callsites. The initial registry-injection
proposal below is superseded by that implementation; Python class/facade binding
remains with the SDK agent.

Root/panel/visibility hunks from the first slice were reported applied by the
coordinator; restoration of the four layout definitions was assigned to Chat owner.
This follow-up edits no frozen ExteralessCore Pill source or Core Pill tests.

For ID 11, an actual passive Rust pong RTT was found in FFI event 17 / `value1`.
The Swift Rust session currently discards it. A new optional TelegramCore projection
and Pill UI consumer are implemented; exact Network-owner forwarding/reset hunks
and the remaining MtProtoKit gap are in [pills-ping.md](pills-ping.md). No RPC timing
is substituted for passive ping, and missing samples continue to be labelled.

## Assembly gates

Native/portable implementation is written for original PillType **1–15**. Native
compilation, XCTest execution, simulator frames and physical-device measurements
are **not verified** on this Windows host. No external provider request, location
permission, account operation, external plugin, commit, push or CI was executed.

Initial [pills-native-hunks.patch](pills-native-hunks.patch) is retained as assembly
evidence; root/panel/visibility integration and the four layout definitions are now
present in the reviewed source. The original hunk contents were:

1. `ExteralessClientRuntime`: register `PillFeatures.definitions`, retain
   `ExteralessPillIntegration`, call `update(context:)` / `clearContext()`.
2. `ChatListControllerNode`: a keyed `HeaderPanelContainerComponent.Panel` through
   `ExteralessPillEntry` / `ExteralessPillPanelComponent`. Its measured height flows
   through the existing navigation/list-inset calculation. An empty layout adds no
   panel. The existing tab-container type and download/search accessory remain
   accessible to their current callers.
3. `ChatListController`: foreground screen visibility begins at `viewDidAppear`
   and stops at `viewWillDisappear`; search, editing and inline forums suppress
   the panel. Empty layouts still observe settings, so enabling a pill restores it.
4. **Concurrent-edit prerequisite:** at initial inspection `ChatFeatures` owned
   the four layout keys; another subwave subsequently removed them. The final
   hunk restores those four definitions there, as required by this ownership
   contract. Without it, `applyPublic` correctly rejects layout/migration writes
   as unregistered keys. Do not register a second copy in `PillFeatures`.

Build owner: add `//submodules/ComponentFlow:ComponentFlow` to AccountContext and
`//submodules/Weather:Weather` to TelegramUI. TelegramUI already directly depends
on PhoneNumberFormat and ExteralessCore. New TelegramCore/TelegramUI/Core files are
covered by their existing Swift source globs. Native SDK imports are CoreLocation,
MapKit, UIKit and Darwin; existing location usage descriptions are used. No new
entitlement or credential is introduced. Check the normal framework auto-linking
for these SDK imports during the native build.

`ExteralessPillIntegration` now owns the independent `pills.status` Settings action
and checks the current context before constructing
`ExteralessPillSettingsController(context:)`. The current Feed subwave uses
`Feed/ExteralessFeedScreen.swift` → `ExteralessPillHeaderView(context:open:)`; that
initializer and its `start` / `stop` / `preferredHeight` / `heightUpdated` API are
retained. Main chat-list assembly is present in the reviewed source.

## Original source read

Read `telegram-ios/AGENTS.md`, `CLAUDE.md`, `docs/wave-2-contract.md`,
`docs/wave-2/chat.md:298–331`, and `settings-batch.md` when it became available.

Both Android trees were inspected:

- Kotlin `app/exteraless/pillstack/PillStackConfig.kt`: all 20 ConfigItems,
  defaults, dormant layout IDs, live-list compatibility, reset and migration.
- Java `app/exteraless/pillstack`: PillType, PillRegistry, PillStackController,
  PillStackView, PillStackSettingsActivity, PillStackEvents, PillCurrencies,
  RateInstances, ExchangeRates, GoldPrice; BasePill, WeatherPill and its settings,
  RatePill, CachePill, ProxyPill, GhostPill, LastSeenPill, TelemetryPill, RamPill,
  CpuPill, NetSpeedPill and DcPingPill.
- Java `org/telegram/ui/Stories/recorder/Weather.java` and its
  `MessagesController.weatherSearchUsername` configuration.
- Java compatibility classes under `com/exteragram/messenger/pillstack/core`
  and `ui`: registry/creator wrappers, live active/hidden lists, BasePill and view.

Important source distinction: **Telegram's configured weather bot is the active
Android provider**. The Open-Meteo URL exists in the commented earlier HTTP path
at Weather.java:379. It is an explicitly selected iOS option, not silently
described as the active Android source. No other weather/rates endpoint was added.

## Behavior and actual data

| Original ID | Implementation / actual source |
|---|---|
| 1 Weather | Existing native `Weather.requestWeatherData` with configured Telegram bot; optional URLSession Open-Meteo. Current location is one approximate CoreLocation fix, or a user-entered/native-map point. Permission is requested only by the explicit Enable action. |
| 2 GRAM | Coinbase TON, matching `RateInstances.normalizeBase("GRAM")`. |
| 3 BTC | Coinbase USD-base table, reciprocal USD/unit storage and cross-rate division. |
| 4 USD | Same table; target AUTO resolves from **this account's phone-country**, including the original +7 KZ/RU rule, otherwise USD. |
| 5 Cache | Actual account MediaBox storage + cache sizes; filesystem free/total capacity drives the occupancy ring. Tap opens native storage management. |
| 6 Proxy | Actual account network/proxy readiness and issue flag. Tap opens native proxy settings. No passive RTT is invented. |
| 7 Ghost | `PrivacyPolicy.ghostModeActive` / `ghostModeChanges`; all unlocked changes and their locked-flag CAS dependencies are one `applyPublic` batch. Existing account-scoped exclusions remain authoritative. |
| 8 RAM | Mach task physical footprint, system free pages and `ProcessInfo.physicalMemory`, separately labelled. |
| 9 CPU | `getrusage(RUSAGE_SELF)` user+system seconds / monotonic visible interval, explicitly **app CPU, percent of one core**. |
| 10 Network | Deltas of this account's native MTProto Wi-Fi+cellular counters, both directions in bytes/s; native reset identity and cumulative totals are displayed. |
| 11 DC ping | Native main-session readiness and `serverActivity` ages. **RTT unavailable** is explicit; activity age is never called ping. |
| 12 Gold | `https://api.gold-api.com/price/XAU`, USD per **troy ounce**, optionally converted by Coinbase. |
| 13 ETH | Coinbase cross rate. |
| 14 EUR | Coinbase cross rate. |
| 15 Last seen | Account-scoped native server-presence cache plus existing Privacy OwnLastSeen observations through a new TelegramCore projection. Display identifies cached/server/local source. |

Platform/scope differences are deliberate and visible:

- RAM free pages exclude reclaimable/compressed memory; no Android-style available
  RAM percentage is inferred from them. Kernel errors produce unavailable, not 0.
- CPU measures the process, not Android `/proc/stat` whole-device load. A genuine
  multithreaded reading may exceed 100%; invalid/non-finite intervals are rejected.
- Network speed is account traffic, not whole-device throughput or link capacity.
  Packet-drop counters are not exposed by this native accounting API and are not
  fabricated. Actual measured zero traffic remains a valid zero.
- `NetworkEngineSession` exposes readiness/activity, not passive DC/proxy RTT.
  Engines without `serverActivity` still supply account readiness and DC ID.
- Last seen reads existing observations rather than issuing the Android periodic
  `users.getUsers(self)` RPC. A cached online expiry is labelled cached. Unknown
  status stays unknown; no timestamp or online state is synthesized.

## Settings, migration, caching and lifecycle

- Four original layout keys remain `chats.activePillsRaw`, `hiddenPillsRaw`,
  `lastActivePillId`, `infiniteScrolling` (restoration hunk above). The other 16
  original fields are registered by `CorePillFeatures.swift`. Defaults are exact:
  active `5,6`, hidden empty, loop true, selected −1; six targets AUTO, instance and
  cache strings empty, timestamps 0, migrated false; current location true and
  manual strings empty. The only new public options are weather source and units.
- Dynamic pairs retain Android `id:FROM>TO;…`, first ID 100, maximum 12, GRAM→TON
  and GOLD→XAU. Add/edit/remove, layout, manual coordinates and cache value+time
  use atomic public batches. A stale pair-editor cannot overwrite a newer pair.
- Legacy migration creates pairs only for legacy IDs present in active/hidden
  lists; replaces those slots and remembered selection in the **same** commit as
  instances and the marker. Failure preserves the whole previous document. If
  all 12 slots are occupied, the remaining legacy IDs still have working providers.
  Malformed/oversized instance strings are preserved with a repair screen.
- Unknown/dormant IDs retain order through toggle/reorder; explicit Reset restores
  default layout. Removal of a selected pair atomically clears its remembered ID.
  Horizontal/vertical swipes and VoiceOver adjustment obey loop/clamp selection.
- Rates and gold persist the original string formats with Unix **milliseconds**.
  Both components of a cache update are one commit. Error fallback retains the
  original receipt timestamp. Gold cross-rates use the older dependency timestamp.
  Weather caches are bounded to eight source+coordinate entries in memory; current
  device coordinates are not persisted as a new location history.
- Refresh intervals: rates/gold 300s, weather 900s, cache 180s, RAM/CPU 3s, account
  network 2s, DC readiness 5s, cached own presence 60s. Proxy/ghost are observations.
  Fast metrics slow in Low Power / serious thermal state. There is one selected
  subscription per visible surface, with cancellation on selection change, exit,
  background and account generation replacement. CPU/network baselines reset.
- `PillRequestPool` keys include account generation, domain and immutable provider
  selection. Concurrent consumers share producers; cancelling one preserves the
  others, cancelling the last cancels the producer. Late old-generation callbacks
  cannot publish a new reading or write cache data after lease retirement.
- URLSession is ephemeral, no cookies/credential storage/cache, redirects disabled,
  15s request / 20s resource timeout and a 1 MiB streaming body cap. Responses are
  strictly validated. Minimum manual request spacing is 5s; this is labelled local
  throttling, not a source quota. HTTP 429 honours Retry-After, otherwise uses an
  explicitly labelled local 60s backoff. Visible one-shot retry timers are cancelled
  with the subscription. No background polling/session is created.
- Provider usage shows actual coalesced request/HTTP response/failure counts,
  optional reported remaining quota and last HTTP status. Missing quota is “not
  exposed”. Built-in sources require no keys. A future injected credential-bearing
  provider must use native secret definitions/ClientSettings Keychain access; keys
  must not enter PillModel, URLs in diagnostics, public snapshots or exports.

UI state transitions: initial unavailable/permission/location hints have no
timestamp; initial requests show loading; refresh retains an existing value with
its original timestamp; successful replies become ready; failed refresh with a
value becomes stale; failed initial requests show retry and source error. Restored
future/expired timestamps never qualify as fresh. Details expose source, scope,
units, time, phase and usage. Header tap target is at least 44pt; empty layouts
report height 0. Ghost/observed-online state uses native success color plus text.

## Plugin SDK binding: actual native surface, adapter still pending

`PillPluginRegistry` and `PillPluginProvider` are implemented and consumed by the
same native header/detail path. `PillModel` is a validated Codable native DTO:

```json
{"id":10001,"title":"Plugin status","value":"12 MB","detail":"Source detail",
 "source":"plugin/provider name","phase":"ready","updatedAtMs":1000250,
 "progress":0.25,"isHighlighted":false}
```

`phase` = idle/loading/ready/stale/failed/unavailable. Omit unavailable timestamp
and progress; do not encode an invented zero. ID is positive Int32; text fields and
finite progress are bounded. Timestamp wire units are Unix milliseconds, not
Foundation's default reference-date seconds.

Implemented Swift injection API:

```swift
let registration = try PillPluginRegistry.shared.register(
    owner: PillPluginOwner(pluginId: pluginId, generation: generation),
    descriptor: PillDescriptor(id: nativeId, title: title, symbol: sfSymbol, interval: interval),
    provider: provider
)
// Retain registration; cancelling it unregisters exactly this instance.
// provider.start(PillPluginRequest, update:) -> PillCancellation
// provider.perform(.refresh / .tap / .longPress, request:)
PillPluginRegistry.shared.unregister(owner: owner)
```

Registration capacity is 64, native plugin IDs begin at 10000, refresh interval
5–3600s, update admission at most 4Hz. Core built-ins cannot be overridden. The SDK
adapter must reserve/check dynamic-rate IDs too and map arbitrary Android IDs to
native IDs without deleting their dormant layout entries. Account scope must match
the lease. Start/actions/cancellation run on a utility worker. Owner unregister and
consumer lease disposal cancel resources; retired callbacks cannot render. No
Python executes during layout, drawing, model reads or UIKit callbacks.

Coordinator/SDK-agent proposal (not claimed wired Runtime methods):
`pillRegister(descriptor, callbacks)`, `pillUpdate(registration, model)`,
`pillUnregister(registration)`, `pillGetLayout`, `pillSaveLayout`.
Capture `PluginCallbackDispatcher.CallbackOwner` at registration and map it to
`PillPluginOwner.generation`; use dispatcher owner-worker FIFO for all Python
callbacks/releases. Retain one callback lease per registration, cancel its queued
work on unload/account retirement, and apply public layout patches atomically.
Implement Android mutable-list adapters as snapshots committed by savePillsLayout;
map settings/layout events to registry invalidation and model updates. Translate
BasePill loading/selected/visibility methods to provider leases and DTO phases;
arbitrary Android View subclasses need a DTO adapter. Compatibility class aliases
and these native dispatch bindings remain **SDK assembly work**, explicitly tracked
in the parity JSON rather than dismissed as permanently unsupported.

Services3 handoff was checked: its actual Android event mappings are **25
contactsDidLoad**, **46 mainUserInfoChanged**, **137 didUpdateConnectionState**.
The SDK can reuse those real publishers for compatibility notifications; none is
misrepresented as a Pill layout event or as new RTT/traffic data. Pill registry and
settings invalidations have their own native subscriptions. Privacy2's transaction
helpers are now internal to TelegramCore; `ExteralessPillCoreData.swift` calls them
inside that module and exports only the small own-status/activity projections.

## Verification and expected frames

23 own XCTest fixtures are in `PillPolicyTests`, `PillProviderTests`,
`PillWeatherProviderTests`, `PillPluginRegistryTests`. They use only generated local
fixtures and injected transports/providers: original IDs/defaults; atomic migration,
failure/capacity/selection; pair CAS; coordinate transaction; finite metrics and
counter resets; rate direction/troy units; freshness/error timestamps; request
coalescing/cancellation/generation; source isolation; actual quota vs local throttle;
portable timestamp schema; owner unload and off-main provider callbacks.

Run the Core Pill filter with an outer **30-second bound** after assembly, e.g.
`swift test --package-path swift/ExteralessCore --filter 'Pill.*Tests'` under the
coordinator's bounded runner. Swift/swiftc and an installed WSL distribution are
absent here, so these tests are written, **not executed**. Local source/patch checks
are recorded in `pills-parity.json`; they are not substitutes for compiler/tests.
The reported Core 122-test green baseline does not validate these new Pill tests.

Final bounded local checks passed: `git apply --check` for all coordinator hunks;
lexical/whitespace scan of 27 owned Swift files; parity coverage of all 15 original
IDs / 20 original config records; existence of every declared callsite and 23 test
methods; no Postbox import in Pill UI and no production URLSession transport in
tests. The same check explicitly confirms the four missing layout definitions as
an assembly prerequisite, rather than hiding that concurrent ownership change.

Before recording on an allowed simulator/device, expected frames are:

1. Permission/manual-location hint → loading → weather value: icon/text keep one
   baseline and one header frame; only text cross-dissolves for 160ms, no overshoot,
   no blank frame, no clipped pin/spinner. Reduce Motion replaces text immediately.
2. Rate refresh and USD→EUR/base switch: the old **same-pair** cached value may stay
   during refresh with its original timestamp; a new pair must never show the old
   currency-labelled value. Value changes cross-dissolve for 160ms without width
   oscillation. Failure preserves stale value/time and exposes the error.
3. Empty layout ↔ first active pill, search enter/exit and account change: the keyed
   panel and chat-list top inset change together; empty/search/retired state has no
   reserved blank panel. Existing folder tabs, notices and media panel keep their
   ordering. Verify light/dark, RTL, 320pt width and large Dynamic Type.
4. Reorder/cancel/reset and swipes at both ends: no duplicated pill, stale selection
   or moving neighbour left behind. Loop wraps; clamp stays put. Validate VoiceOver
   increment/decrement, activation, source/time value and Settings custom action.
5. Manual map: 240pt map + native pin remain inside table safe insets; changing a
   point and saving removes the previous annotation, preserves rows and returns to
   the new manual selection. No device-location prompt occurs on this route.

Record with `simctl io recordVideo`, extract labelled/timestamped frames per AGENTS,
then cite actual frame indices/times for all findings. **No frames were recorded
and no visual pass or physical telemetry/ping accuracy is claimed.**
