# Network/maps — applied native wiring and remaining owner insertions

## Applied by this owner

- `MtProtoKit/MTContext.h` + `MTTcpConnection.m`: real `resolvesHostnames` protocol
  and branch preserve the hostname until the resolver-aware socket dials it. The
  preceding WEB carrier branch still resolves nothing.
- `MTContext.m` + `MTDiscoverConnectionSignals.m`: app family preference participates
  in real DC scheme selection; opposite-family subscription is staggered, not removed.
- `MTBackupAddressSignals.h/.m`: actual `primarySource:` overload chooses the
  app-supplied TXT source; native signed-config decode/probes remain downstream.
- Rust `resolver.rs` + `worker.rs` + `session_runtime.rs`: real worker calls the
  native C resolver, per-query ID/epoch reject old results, last-waiter cancellation
  reaches the native query, and bounded secondary caches use native expiry.
  TTL is sampled on the resolver thread, **not the reactor queue**. TTL=0 grants
  only the current dial; cache reset preserves the matching waiter wakeup.
- `RustNetworkSession.swift`: real address order consumes native family preference.
- `RustEngineRuntime.swift`: app resolver changes reset existing engine connections.
- `RustStreamHost.swift`: real iOS TLS stream open uses the native Happy-Eyeballs
  connector. SNI/ALPN/false-start are preserved; system trust validates certificates.
  Stream-generation checks cancel obsolete dials. `mt_stream_sent` / `MTBytes.length`
  still use the actual byte count. CFError is reduced to numeric domain/code;
  no CF description containing a host or URL is exported.
- `ChatMessageMapBubbleContentNode.swift`: physical cloud/secret preview scope.
- `InstantPageImageNode.swift`: physical article preview scope.
- `OpenInOptions.swift`: physical Google correction and OSM external action.
- Existing owned `LocationMapNode`/`MapResources` integrations now reach these
  callsites; settings epochs update already-open previews and map views.

`network-maps-rust-integration.patch` is retained as the **historical proposal**
which was applied and refined. Do not apply it a second time. Actual source files
and the current parity receipt are authoritative.

## Network.swift — current Network/TL owner

Apply **`network-maps-network-hunk.patch`**. It contains only two insertion points
in `TelegramCore/Sources/Network/Network.swift`:

1. Before capturing `baseTcpConnectionInterfaceFactory`, register the MTContext
   and install the app resolver-aware native socket factory for iOS main-app
   networks. Keep the existing WEB-proxy override after that capture. Restoring
   the base factory after a proxy change then restores the resolver-aware socket.
2. Use `ExteralessNetworkBackupDNS.backupSignal` where the backup-discovery signal
   is created. The `primarySource:` native method is already implemented.

No insertion in `Account.swift` is required. This owner has not edited either
reserved file. RPC transformation/order and proxy policy remain with their owners.

## Root/schema/editor — current composition/CoreSettingsUI owner

Apply **`network-maps-integration.patch`**, now containing **only root/editor hunks**
rebased on the current composition source. These files were not edited here.

- Add `NewNetworkFeatures.definitions + MapFeatures.definitions` to the shared
  schema registration. `network.customDoH` and `maps.yandexAPIKey` are secrets;
  their storage is Keychain, not the public JSON snapshot/export.
- Retain `ExteralessNetworkIntegration` and `ExteralessMapIntegration` in the root.
- Construct them in `configure(rootPath:)` after shared settings and schema
  registration succeed, **before accounts/login**. The existing AppDelegate
  pre-account call to `configure` is sufficient; no second AppDelegate startup
  hook is needed. Constructing only in `update(context:)` would miss login and
  already-created network sessions.
  The current root also takes `durabilityRootURL`/`storageContainer`; the rebased
  hunk preserves that owner's new storage boundary and inserts after registration.
- Forward `update(context:)` and clear through the current
  `clearAccountDomains()` placement (the supplied hunk follows Tools there).
- In the generic editor, call `NewNetworkFeatures.validate(validated, for: key)`
  before storing. Reset to empty custom list is the explicit original-provider
  default, while a malformed nonempty list is rejected.

Native validation also runs independently of the editor. Invalid custom data
retains an established last-valid resolver with an explicit diagnostic. If startup
has no valid configuration (including unreadable custom secret state), DNS and
public TXT fallback are blocked with a configuration error; there is no silent
switch to a public/native resolver. Literal MTProto addresses do not need DNS.

## Build and verification handoff

Build/MODULE files remain with the build owner. Use the dependency names in
`network-maps.md`; the permitted native sources and public headers are in place.
The three `.rs` changes reside in the **nested worktree**
`telegram-ios/third-party/mtproto-engine`; coordinator freeze/packaging must include
that worktree's source changes as well as the outer Swift/ObjC changes.
`network-maps-native-pins.json` records raw-file hashes/byte lengths using the
inventory `_read/_sha` contract, including the current concurrent Core fix that
separates the Cache-Control maximumTTL read/write access. The pins are a source
snapshot, not a runtime admission or a new text-normalization algorithm.

Coordinator-confirmed app environment: **Xcode 27.1, runner `xcode-27`**, already
used for IPA 23. Foundation/runtime-only 26.6 is not an app-toolchain blocker.
This Windows agent has not run the coordinator's build or native test runner.

Prepared local fixtures: 21 Core XCTest cases, 1 native fake-socket case, and
2 Rust `app_resolver_*` cases for zero TTL / epoch wakeup. They use packet literals,
URLProtocol, fake DNS/sockets, or scripted Rust resolution, not provider calls.
Pill 11 passive RTT also has applied Rust/Recording/Switching forwarding and
7 native fake-event/wrapper cases; see `network-maps-passive-rtt.md`. No extra
Network.swift/root insertion or C ABI is needed for the optional RTT capability.
Post-apply source validation: one full 11-case run (10 passed; one detected a
concurrent root signature change), then the corrected root-hunk case alone passed.
Native sources/hashes required no correction. Outer/nested `git diff --check`
passed. Apple execution and frame review remain coordinator checks, not claims
made from source matching.
