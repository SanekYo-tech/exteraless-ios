# Pill 11 — passive RTT evidence and Network-owner insertion points

**A real ping/pong RTT already crosses the Rust FFI. Swift currently discards it.**
It is not necessary to generate a request, time an RPC, open a socket, or change
the C/Rust ABI. The new read-side capability is implemented in
`TelegramCore/Sources/ExteralessPills/ExteralessPillPassivePing.swift` and consumed by
`ExteralessPillSubscription.refreshConnection`. Until the Network-owner forwarding
below is applied, that optional projection returns unavailable and the UI continues
to label readiness/activity honestly.

## Measured source chain

1. `third-party/mtproto-engine/crates/mtproto-core/src/session/mod.rs:2453–2479`,
   `on_pong`: matches a pending native ping by message/ping ID, computes
   `rtt = (now.mono - ping.sent_at).max(0.0)` and emits `SessionEvent::Pong { rtt }`.
   This is an actual native ping round trip in **seconds**, not a request-duration
   percentile. No new ping should be generated for PillStack.
2. `crates/mtproto-core/src/rpc/mod.rs:811` forwards `RpcEvent::Pong { rtt }`.
3. `crates/mtproto-ffi/src/lib.rs:490–493` emits kind **17**, `value1 = rtt`;
   `include/mtproto_engine.h:168` already declares `MTEventKindPong = 17`.
4. `MTProtoRustEngine/Sources/MTProtoRustEngine/RustEngineEvent.swift:22,62,81`
   already decodes `.pong` and `value1`.
5. **Missing consumer:** `RustNetworkSession.swift:784–785`, `case .pong: break`.

Do not substitute `NetworkTelemetry.mainRoundTrip`: `NetworkTelemetry.swift:1171–1179`
adds `NetworkTelemetrySample.duration` for successful small main-session requests.
`latencyP50`/`mainLatencyP50` are RPC-duration statistics, not passive ping RTT.
Likewise `NetworkEngineServerActivity.silentFor` / `waitingFor` are activity ages.

## Exact Network-owner Swift changes

All paths below are relative to `telegram-ios/submodules/`. They are handoff hunks,
not applied by the Pill implementer to Network-owned files.

### 1. Rust session: retain the existing event's reading

`MTProtoRustEngine/Sources/MTProtoRustEngine/RustNetworkSession.swift`:

```swift
// Add the optional capability to the existing class declaration:
final class RustNetworkSession: NetworkEngineSession, RustEngineEventHandler, ExteralessPillPassivePingSource {
    // Alongside lastHeardAt / busySince (same session queue):
    private var exteralessLastPassivePing: ExteralessPillPassivePingSample?
```

Replace the existing `.pong: break` in `handleEngineEvent` with:

```swift
        case .pong:
            if self.isMain {
                self.exteralessLastPassivePing = ExteralessPillPassivePingSample(
                    roundTripSeconds: event.value1, sampledAt: Date())
            }
```

In the same switch's `.connectionState`, immediately after
`let flags = RustEngineConnectionFlags(rawValue: event.flags)`, add:

```swift
            if !rustEngineHasAnsweredConnection(flags) {
                self.exteralessLastPassivePing = nil
            }
```

At the beginning of `.connectionDropped`, add
`self.exteralessLastPassivePing = nil`. In the existing pause application block
(`if paused != self.appliedPaused`, around line 1099), immediately after setting
`self.appliedPaused = paused`, add:

```swift
            if paused { self.exteralessLastPassivePing = nil }
```

Add next to `serverActivity(_:)`:

```swift
    func exteralessPillPassivePingSnapshot(_ reply: @escaping (ExteralessPillPassivePingSample?) -> Void) {
        self.queue.async { [weak self] in
            guard let self, self.isMain, !self.isStopped.with({ $0 }),
                  !self.isDraining, !self.appliedPaused,
                  self.lastConnectionFlags.map(rustEngineHasAnsweredConnection) == true,
                  let sample = self.exteralessLastPassivePing, sample.isFresh() else {
                reply(nil)
                return
            }
            reply(sample)
        }
    }
```

The sample rejects zero/non-finite RTT, has the actual event receipt timestamp,
and expires after 120 seconds. Pause/drop/drain prevents an old connection's sample
from being displayed during reconnection. An engine switch needs the wrapper check
below too. No private auth/session key, IP, APNs or payload data is exposed.

### 2. Recording wrapper: forward, not recompute

`TelegramCore/Sources/Network/RecordingNetworkEngine.swift`, class
`RecordingNetworkEngineSession: NetworkEngineSession` (line 74): add
`ExteralessPillPassivePingSource` conformance and this method beside `serverActivity`:

```swift
    func exteralessPillPassivePingSnapshot(_ reply: @escaping (ExteralessPillPassivePingSample?) -> Void) {
        guard self.role == .main,
              let source = self.session as? ExteralessPillPassivePingSource else {
            reply(nil)
            return
        }
        source.exteralessPillPassivePingSnapshot(reply)
    }
```

### 3. Switching wrapper: reject a reply from the replaced engine

`TelegramCore/Sources/Network/SwitchingNetworkEngine.swift`, `SwitchingCore`, next
to its `serverActivity` method around line 261:

```swift
    func exteralessPillPassivePingSnapshot(_ reply: @escaping (ExteralessPillPassivePingSample?) -> Void) {
        self.lock.lock()
        let session = self.state.pointee.isStopped ? nil : self.state.pointee.current
        self.lock.unlock()
        guard let session, let source = session as? ExteralessPillPassivePingSource else {
            reply(nil)
            return
        }
        source.exteralessPillPassivePingSnapshot { [weak self, weak session] sample in
            guard let self, let session else { reply(nil); return }
            self.lock.lock()
            let current = !self.state.pointee.isStopped && self.state.pointee.current === session
            self.lock.unlock()
            reply(current ? sample : nil)
        }
    }
```

Add `ExteralessPillPassivePingSource` conformance to `SwitchingNetworkSession`
(line 320), forwarding alongside `serverActivity`:

```swift
    func exteralessPillPassivePingSnapshot(_ reply: @escaping (ExteralessPillPassivePingSample?) -> Void) {
        self.core.exteralessPillPassivePingSnapshot(reply)
    }
```

## MtProtoKit gap

The checked public/session API contains no retained passive RTT. Its
`MTProxyConnectivity.roundTripTime` is produced by **a separate active connectivity
probe** (`MTProxyConnectivity.m:85`), and is not used as a substitute here.
`MTTcpTransport.m:765–783` matches `MTPongMessage.messageId` against
`MTTcpTransportContext.currentActualizationPingMessageId`, then clears it; its
context currently stores the message ID/resend timer but no matched send timestamp
or exported RTT reading. A future Kit implementation must instrument the existing
actualization ping's actual send and matched pong on its transport queue, clear on
retry/session replacement, and export a capability through `MtProtoKitEngine`.
It must not time arbitrary API requests or launch `PingFoundation` probes.

## Verification required

- A bounded fake-event fixture should pass `.pong` values through the FFI-decoded
  `value1` into the optional sample, reject zero/NaN/infinity, and clear it on
  pause/drop. A wrapper fixture must discard an old engine's late reply.
- No live network/probe, Rust/C source change, commit or CI was performed here.
  Native compilation and physical timing remain unverified. Rust passive RTT is
  **an identified, directly usable source pending the above owner hooks**; Kit RTT
  remains an explicit native gap. The new Pill UI uses a real sample only when the
  capability is present, connected and fresh.
