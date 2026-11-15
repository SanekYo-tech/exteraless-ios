# P-network-resolver (3) + P-maps (3) — source handoff

**Native/Rust/map integration applied; reserved Network/root insertions remain.**
Coordinator has the **Xcode 27.1 `xcode-27` app runner**, already used for IPA 23;
Foundation-only 26.6 is not an app-toolchain blocker. This agent performed source
work on Windows. No CI, account connection, external
provider request, permission prompt, commit, push or external plugin was run.
This is not a visual, native build, security-gate or parity-review pass.

## Exact six original IDs / source dispositions

Android paths below are relative to
`third_party/exteraless-android/TMessagesProj/src/main/`. Actual Java **and Kotlin**
trees were searched. `DnsFactory.kt` is under `java/`; there are no additional
consumers of these six symbols in `src/main/kotlin`.

| Original ID / default | Actual original consumer | iOS source / disposition |
|---|---|---|
| `neko.dnsType = 0` | `NekoConfig.java:54-57,147`; `ConnectionsManager.java:992-1017,1308-1380`; `DnsFactory.kt:60-205` | `NetworkResolverConfiguration.Mode` preserves IDs **0 Telegram, 1 NagramX, 2 system, 3 custom**. iOS default uses its existing native resolver: `MTDNS.m:237-251` documents removal of the dead Google fronted GET endpoint. Checked wire/JSON DoH is now called by applied native/Rust transport sources. Reserved Network factory/backup-source and pre-login root insertions are delivered separately. |
| `neko.customDoH = ""` | `DnsFactory.kt:69-86,129-174,254-290`; `ConnectionsManager.java:1636-1687` | Comma-separated HTTPS endpoint list, original six URL pins, empty custom list explicitly labelled as original-provider fallback. Malformed nonempty list rejected; custom path/query tokens preserved; Keychain-backed definition. TXT fallback remains Google DNS-JSON and signed MTProto decode. |
| `neko.useIPv6 = false` | `ConnectionsManager.java:1197-1275`; `DnsFactory.kt:347-423` | `NWPath` capabilities and real 250 ms Happy Eyeballs with opposite-family fallback. Applied DC scheme preference/discovery, Rust address ordering and epoch/TTL/cancellation. IPv6-only paths work with preference off; native DNS64 fallback retained. |
| `neko.mapPreviewProvider = 0` | `AndroidUtilities.java:2897-2941`; `ChatMessageCell.java:9778-9835`; `ArticleViewer.java:13124` | IDs **0 native Telegram/MapKit, 1 Yandex, 2 disabled**. Applied physical cloud/secret scope in `ChatMessageMapBubbleContentNode` and article scope in `InstantPageImageNode`. Secret/profile/contact snapshots remain native. |
| `neko.useOSMDroidMap = false` | `ApplicationLoader.java:129-142`; `OSMDroidMapsProvider.java:154-161`; `OpenExteraGeneralActivity.java:517-529` | Applied native OSM overlay, picker/pins/camera/live locations, visible tiles/cache/cancellation, attribution and labelled Apple satellite/hybrid fallback. External OSM option is now wired in `OpenInOptions`. |
| `neko.mapDriftingFixForGoogleMaps = true` | `GoogleMapsProvider.java:593-598`; `NekoConfig.java:308-309`; `NekoLocationSource.java:48-60`; `LocationActivity.java:2523-2524`; `GeodeticTransform.java:20-55` | Applied Google action consumer in `OpenInOptions`; exact WGS84→GCJ-02 constants/bounds and datum tag. Native MapKit and sent/received media retain WGS84. Original OSM-disable precedence is preserved; no BD-09. |

## API / composition

- `NewNetworkFeatures.definitions` (three original fields), `MapFeatures.definitions`
  (three original fields plus a separate optional **secret** Yandex credential).
- `NewNetworkFeatures.validate(_:for:)` validates the endpoint editor. The native
  resolver independently revalidates configuration. Invalid writes retain an
  established last-valid policy with a diagnostic. Without any valid startup
  configuration, DNS/public-TXT fallback is blocked instead of silently selecting
  a public/native resolver.
- `ExteralessNetworkIntegration.init()/update(context:)/clearContext()` and
  `ExteralessMapIntegration.init()/update(context:)/clearContext()` are TelegramUI
  composition APIs. Network initialization must occur in `configure(rootPath:)`,
  **before login/accounts**, not only in `update(context:)`.
- `ExteralessNetworkResolverRuntime.start()/register(context:)/clearCachedState()`;
  `NetworkResolver.lookup/resolve/update/rejectConfiguration/invalidate/state/remainingTTL`.
- `ExteralessNetworkBackupDNS.backupSignal` supplies the actual signed-config
  discovery pipeline with a subscription-time DNS policy.
- `ExteralessResolverTcpConnectionInterface` uses the existing native TCP socket
  for the winning connection, partial reads and byte accounting. This does not add
  request work to telemetry or transform RPCs.
- `ExteralessResolverTLSConnector` provides the Rust WSS/HTTPS stream host's native
  TLS connection, SNI hostname preserved while dialing the selected IP.
- `MTAppNetworkResolver.h/.m`: small DNS-SD / Swift / Rust boundary, completely
  independent of the CPython bridge. Rust blocking calls are confined to resolver
  workers, bounded at 5.5 s; last-Rust-session cancellation is observed within
  50 ms and disposes the native query. Scoped link-local IPv6 uses the DNS-SD
  interface index, not a guessed interface name.

## Applied integration and remaining reserved hunks

Details and exact root/pre-login instructions:
[`network-maps-integration.md`](network-maps-integration.md).

Applied native sources include MtProtoKit TCP/DNS interface, family selection,
backup primary-source seam; Rust resolver workers, cancellation, TTL/epoch caches,
TLS stream host; physical cloud/secret/article map scope and external navigation.
Rust TTL reads stay off reactor queues, cached replies are bounded to 128 per
session, and TTL=0 can satisfy its current dial once without being re-cached.

Remaining **OpenCode patch-envelope** files, intentionally unapplied by this owner:

- `network-maps-network-hunk.patch`: **only Network.swift**, for its current TL/network
  owner; native socket factory capture and backup signal insertion.
- `network-maps-integration.patch`: **only ExteralessClientRuntime/SettingsController**,
  rebased root definitions, pre-login start, lifecycle and editor validation.

AppDelegate already calls root `configure` before accounts. `Account.swift` needs
no insertion. The old `network-maps-rust-integration.patch` is historical proposal
evidence, **already applied with source fixes; do not reapply it**.

Proxy auto-disable / names and TL transformation owners retain their code. The
WEB-carrier branch still resolves nothing and never becomes a direct socket.

## Network semantics

- App MTProto scope only. No NE/DNS-settings entitlement is requested, and no
  system-wide DNS claim. Unrelated URLSession clients, WebKit, Safari, VoIP and
  notification extensions retain their own resolver policy.
- DoH endpoint bootstrap is URLSession native DNS; original IP-literal providers
  avoid hostname bootstrap. HTTPS only, no credentials in URL user-info, no
  redirected DoH endpoint, no trust bypass, no URL/header/domain telemetry.
- DNS wire: 16-bit random transaction ID, exact question/class/type validation,
  QR/opcode/TC checks, bounded compression traversal, record counts and EDNS(0),
  typed A/AAAA/TXT, CNAME loop/depth bounds, SOA negative TTL, minimum chain TTL,
  HTTP Age/max-age subtraction. DNSSEC is not claimed.
- Cache: 256 questions / 128 in flight, monotonic TTL ≤1 hour, transient errors
  2 s, config/route epoch invalidation, last-waiter cancellation, no late result
  admitted into a replacement epoch. A/AAAA are ordered for the native dialer;
  cached results do not constitute a connection-success claim.
- A/AAAA DoH failure falls back to native DNS-SD within a total 5 s lookup budget.
  Local/single-label/mDNS names stay native. TXT custom fallback uses the original
  Google JSON schema; 256-byte decoded config still goes through `MTIPDataDecode`
  and the existing date / datacenter probes.

## Maps semantics / resources

- No downloaded package or plugin. URL/protocol pins are in `MapProviderURL`; these
  are **not** live-availability claims. OSM standard raster is requested only for
  visible `MKTileOverlayPath`s (z 0…19). No bulk/offline-area download.
- OSM attribution is displayed and links to `openstreetmap.org/copyright` (ODbL
  data attribution; tile-service policy applies). Provider-specific satellite and
  hybrid fall back to Apple Maps with their actual provider label.
- Yandex preserves the original Static Maps `1.x/` URL/query convention. Optional
  key is Keychain-only; 403/HTML/invalid-size images lead to a labelled Apple Maps
  fallback, then `Map unavailable` if native snapshot also fails. Provider's logo
  is not intentionally covered; frame acceptance remains pending.
- Maps cache is memory-only, ≤8 MiB / 128 entries, 128 flights, 8 s outer timeout;
  image HTTP ≤4 MiB / 6 s, actual image dimensions checked before decode. Keys are
  account-scoped for snapshots and view-UUID-scoped for tiles. Last subscriber
  cancellation, account clear and policy epochs cancel work and discard late data.
- No location authorization call is added to settings or tests. Existing picker
  permission/user-location behavior remains its native responsibility.

## Build/dependency handoff — build owner

1. `//third-party/exteraless:ExteralessCore`: new Foundation policy/codec/HTTP/cache
   files are under the existing source glob. SwiftPM tests are under its test glob.
2. `//submodules/TelegramCore:TelegramCore`: add/retain ExteralessCore + MtProtoKit
   dependencies; new `Sources/ExteralessNetwork/**/*.swift` require **Network** and
   **Security**, Foundation. No UIKit dependency in these new Core sources.
3. `//submodules/MtProtoKit:MtProtoKit`: existing `.m` / public-header globs pick up
   `MTAppNetworkResolver`; link `dns_sd` (DNSServiceQueryRecord / dispatch API).
4. `//submodules/LocationResources:LocationResources`, `//submodules/LocationUI:LocationUI`,
   `//submodules/OpenInExternalAppUI:OpenInExternalAppUI`: add ExteralessCore. Native
   map modules need MapKit/UIKit/ImageIO already used by their code, verify direct
   framework declarations. No third-party map SDK or resource download.
5. `//submodules/MTProtoRustEngine:MTProtoRustEngine`: its existing TelegramCore and
   MtProtoKit edges supply the connector / C symbols. iOS Rust resolver FFI symbols
   link to MtProtoKit; host Rust builds are `cfg`-isolated. No crate/ABI repin needed.
6. New native fake-socket tests need a TelegramCore test target wired by build owner;
   no test may start real accounts, DNS, tile downloads or permissions.
7. Passive Pill 11 RTT now forwards through actual Rust/Recording/Switching session
   sources. See [`network-maps-passive-rtt.md`](network-maps-passive-rtt.md) for the
   existing event-17/value1 chain and **7 additional native fixture cases**. No
   new C ABI or active pinger; Kit passive RTT remains the precise source gap.

## Bounded verification / acceptance

Prepared Foundation XCTest suites: `NetworkResolverWireTests`,
`NetworkResolverLifecycleTests`, `NetworkResolverHTTPTests`, `MapPolicyTests`.
They use independent DNS packet literals, fake DNS/native callbacks, per-session
URLProtocol, fake clocks and known Beijing/Shanghai/London coordinates. HTTP
fixtures intercept **every** URL. Each wait ≤1 s; watchdog fixture 80 ms.

Post-apply verification covers **11 source checks**: exact IDs, actual
native/Rust/map/RTT calls, raw-byte source pins, reserved-only hunk anchors,
startup rejection, scope/import/trust/byte-count boundaries and packet literals.
The one full run took **0.025 s**: 10 passed and the root-hunk check found a
concurrent storage-durability signature change. That handoff was rebased without
editing the root; its sole targeted rerun passed in **0.002 s**. Thus all 11
checks are covered after the correction. Both outer and nested Rust
`git diff --check` passed (line-ending notices only). Command:
`python docs/wave-2/tests/network_maps_source_fixtures.py`.
It is source validation, not execution of Swift/Rust or a native build.

Prepared native `ExteralessResolverConnectionTests` uses fake sockets to prove the
IPv4 winner is reused after an IPv6 stall and queued bytes never reach the loser;
its wait is bounded at 2 s and it constructs no real Network.framework socket.

Apple run still required: targeted suites with a **30 s process timeout**; native
fake-socket test target; full supported app build through Make.py after shared
wiring. No compiler/runtime result is asserted by the source receipts.

After the build owner has compiled the package tests, the local-only execution is:

```sh
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--package-path", "swift/ExteralessCore", "--skip-build", "--filter", "NetworkResolver|MapPolicyTests"], check=True, timeout=30)'
```

There are **21 prepared Core XCTest cases**, **1 native fake-socket case**, and
**2 scripted Rust `app_resolver_*` cases** for zero TTL and epoch waiter wakeup.
Additionally **3 FFI-decoded passive-RTT event cases** and **4 real-wrapper
forwarding/late-reply cases** are prepared in the native Swift test targets.
Proposed native target for the build owner:
`//submodules/TelegramCore:ExteralessResolverConnectionTests`, on the coordinator's
`xcode-27` setup with an available pinned simulator. That target is a handoff name,
not an existing/run target. Xcode 27.1 app build availability is not blocked on 26.6.

Before frame recording expect: location picker pins/selection stay fixed while
provider changes; old tiles cancel without a stale provider flash; OSM attribution
is visible and tappable; satellite/hybrid labels say Apple; 0/1/2 preview choices
redraw an open cloud message/article; secret chat remains native; disabled/unavailable
cards have readable labels; Beijing Google navigation alone has the GCJ offset.
Record native picker + message + article, light/dark, 90 pt and normal-width cards,
provider failure/offline, account change and cancellation; judge indexed/timestamped
frames per AGENTS.md. **All frame checks pending** on Mac/device.
