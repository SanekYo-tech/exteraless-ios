# Pill 11 passive RTT — Network-owner applied receipt

**Applied to the actual Rust session and both Network wrappers.** This completes
the read-side forwarding identified by `pills-ping.md`; source-only verification
does not claim a measured device RTT or an executed Apple test.

## Exact source-to-consumer path

1. Existing `mtproto-core/src/session/mod.rs:on_pong` matches a pending native ping,
   computes seconds from `now.mono - ping.sent_at`, then emits `Pong { rtt }`.
2. Existing `mtproto-ffi/src/lib.rs:RpcEvent::Pong` emits kind **17**, **value1**.
3. Existing `RustEngineEvent.init` copies the FFI kind/value1.
4. **Applied** `RustNetworkSession.handleEngineEvent`, `.pong` branch, now feeds
   `RustPassivePingState.consume`. The projection creates the existing
   `ExteralessPillPassivePingSample` with native seconds and one `Date()` receipt
   timestamp. Snapshots preserve this timestamp and expire using its 120 s rule.
5. **Applied** `RustNetworkSession.exteralessPillPassivePingSnapshot`: main-role,
   stopped/draining/paused and answered-connection checks, one queue reply.
6. **Applied** `RecordingNetworkEngineSession` optional capability forwards the
   reading. `SwitchingCore`/`SwitchingNetworkSession` forwards only from the same
   current engine generation; the existing Pill subscription can now receive it
   through the real `account.network.mainSession` chain.

There is no new ping request, RPC-duration substitution, socket, or C ABI.
`NetworkTelemetry.mainRoundTrip`, latency percentiles and `serverActivity` remain
their original metrics; they are not sources of this value.

## Lifetime / late replies

- Only main sessions publish RTT. Worker/media/CDN sources return unavailable.
- Pause, non-answered state, connection drop/close, drain, reset and changed
  address schemes clear the Rust projection.
- A matched pong may precede its answered-state event: retain the event's time,
  publish only when the session is answered and active.
- Both wrappers reject late replies after pause/resume, drop or stop. Switching
  additionally checks generation and identity, including re-use of the same
  underlying session object. The recording wrapper retires reads on drain.
- `ExteralessPassivePingReply` completes each forwarded read once, rechecks
  freshness and never retimestamps it. No per-RPC object or timing work was added.

## Prepared bounded native fixtures

`MTProtoRustEngine/Tests/MTProtoRustEngineTests/RustPassivePingEventTests.swift`
contains **3** tests constructing `MTEvent`, decoding it through the real
`RustEngineEvent` initializer, and exercising the same state used by the session:
kind 17/value1, receipt timestamp/expiry, pre-ready ordering, non-main and
non-pong rejection, zero/negative/NaN/infinity/overflow, pause/drop/close/non-answered.

`TelegramCore/Tests/ExteralessPassivePingForwardingTests.swift` contains **4** tests
using actual `RecordingNetworkEngine` and `SwitchingNetworkEngine` wrappers with
fake inner sessions: timestamp preservation/one reply, worker and lifecycle
rejection, Recording-over-Switching late old-engine reply, and generation checking
when the same fake session object is reused. Telemetry uses `directory: nil`;
the fake request service fails a test if any request is submitted. No sleeps or
live DNS/ping/provider calls occur. These are prepared native tests, not merely
the earlier one-sample value-contract fixture, and have not been executed here.

Build owner: existing TelegramCore/MtProtoKit/SwiftSignalKit and
MTProtoRustEngine/MTProtoEngineFFI/Mapping dependencies cover the new source and
test files. No BUILD/MODULE/Network.swift/root insertion was made for this RTT
capability. Use the coordinator's `xcode-27` / Xcode 27.1 app/native environment.

The post-apply local source check passed the actual RTT event/wrapper bindings,
raw-file hashes and byte-count/trust boundaries. The prepared 7 native RTT tests
remain unexecuted; no live ping/tile/DNS call was made for this receipt.

## Precise Kit disposition

The checked MtProtoKit source only matches its actualization ping ID and clears
it; its public session interface retains no passive RTT sample/send timestamp.
`MTProxyConnectivity.roundTripTime` belongs to a separate **active** probe and is
not used. Thus Kit currently reports unavailable through the optional capability.
This is the specific historical/public-source gap documented in `pills-ping.md`,
not a claim that Rust lacks RTT or that an arbitrary RPC duration is equivalent.
