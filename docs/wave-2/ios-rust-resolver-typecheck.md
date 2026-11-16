# iOS Rust resolver unsafe-lint fix

**2026-11-16 — frozen for coordinator delivery.** The resolver-local fix and exact outer patch replay are verified. Apple Rust compilation and the full native link remain pending the next full-app build.

Trigger: full-app run `43776035926`, revision `54b2f7e8`. The supplied `C:\Users\sasha\AppData\Local\Temp\opencode\ipa-54b2f7e8-failed.log`, lines 2904–2969, reports five `unsafe_code` errors in `resolver.rs` (original lines 5, 21, 32, 44, 66), inherited from `lib.rs:1`.

## Source change and audited boundary

Changed only `telegram-ios/third-party/mtproto-engine/crates/mtproto-engine/src/resolver.rs` inside the nested repository: 18 inserted lines, consisting of the module-local attribute below and safety comments at the extern declaration and all four unsafe blocks.

```rust
// Audited iOS-only FFI boundary for MtProtoKit/MTAppNetworkResolver.h.
#![cfg_attr(target_os = "ios", allow(unsafe_code))]
```

`crates/mtproto-engine/src/lib.rs:1` still has `#![deny(unsafe_code)]`; the workspace lint also remains `unsafe_code = "deny"`. The exception applies only to the private resolver module on `target_os = "ios"`. The public `Engine` API and resolver entrypoints continue to expose safe Rust types. Existing targeted allowances in `clock.rs:5`, `interface.rs:4`, and `connection.rs:509–525` establish the engine's native-call pattern. Reviewed `telegram-ios/CLAUDE.md`'s Rust/iOS build contract and `third-party/mtproto-engine/docs/swift-integration.md` §15 ownership contract.

Audit against the actual native implementation:

- **ABI:** `telegram-ios/submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTAppNetworkResolver.h:23–30` and `Sources/MTAppNetworkResolver.m:104–172` agree on C linkage, `uint16_t/u16`, `int32_t/i32`, `uint64_t/u64`, `size_t/usize`, `double/f64`, and the C `bool (*)(const void *)` callback. The native `char *output` is raw byte storage, matching the Rust byte buffer; Rust always supplies a non-null callback.
- **Epoch:** the native function reads a process-lifetime C atomic using acquire ordering and accepts no borrowed pointer.
- **TTL:** the live, NUL-terminated `CString` is copied into an `NSString`; the native function retains no Rust pointer. `ExteralessNetworkResolverRuntime.swift:43–53` installs the resolver and TTL blocks. `swift/ExteralessCore/Sources/ExteralessCore/NetworkResolver.swift:95–126` confirms the synchronous `remainingTTL(host:) -> TimeInterval` read and the asynchronous resolver/cancellation-token interface. `worker.rs:135–140` performs the blocking lookup and TTL read on its resolver thread.
- **Output:** native code copies the hostname before starting its signal. Its asynchronous completion blocks capture Objective-C-owned state, not Rust pointers. After the bounded wait it marks completion under a lock, disposes the subscription, checks `bytes.length <= capacity` and `INT32_MAX`, and only then copies bytes. Rust's initialized 2048-byte array stays live across the call; negative/oversized-count rejection, UTF-8 validation, address parsing and the 16-address limit are intact.
- **Cancellation:** the private callback receives the same valid, aligned `AtomicBool` borrowed by `resolve_blocking_cancellable`. Native polling occurs only synchronously before return, including its post-disposal check; neither callback nor context escapes into the asynchronous signal blocks. The Rust null check and acquire load are intact. `worker.rs:129–136` owns a cloned `Arc` throughout the call, even if the reactor removes the pending lookup and sets cancellation with release ordering. The temporary flag in `resolve_blocking` likewise lives through its complete synchronous call.

The host fallback and iOS zero-result native fallback retain their existing behavior. No DNS, socket or resolver runtime was executed for this verification.

## Exact source identity

The outer gitlink and nested HEAD are both pinned to `da4b2170210aab0430c4ff18c032991f3030cf45`. All three incoming nested modifications matched the existing manifest's prepared postimages before editing; no unknown third-state source was found. `session_runtime.rs` and `worker.rs`, their payload sections and their entire manifest entries were preserved byte-for-byte. Nothing was staged or committed in either repository.

Paths below are relative to `telegram-ios/third-party/mtproto-engine/crates/mtproto-engine/src/`. Hashes are SHA-256 of raw bytes, including the recorded line endings.

| File | Pinned base preimage | Prepared postimage | Bytes, base → prepared |
| --- | --- | --- | --- |
| `resolver.rs` | `f0ab8bbfc1814b8c2b46805c78b5fb414c47817b6a48501d7b774523c3500330` | `4c8b3fa7081f2ee23709b1e3df332fd3870c5781be1f931fd809c5acf40181d3` | 1211 → 5124 |
| `session_runtime.rs` | `2f63e664433ed9d523b2fe47c5f389b5cd2b06b9d32c43f4ce410ed4bd67a3aa` | `90c2f28f69ef2eed29b01d2f6864c4a955270b26312c914714cddf09e2b9b91e` | 116330 → 124126 |
| `worker.rs` | `32bc15d7c46b8f1a2bdd0ed035af8742f92407af07356e84823a4d13961485e2` | `2eeeaac5589410c676488c6a23f96f696f8214aae023127f306f8642c4d25d51` | 20157 → 23010 |

The incoming resolver snapshot was `bfc08ab5618867ceaccf41a08c8aeabaa4b02b9986b9cfed6dfdb33379fe7074` (3781 bytes). It is not substituted for the pinned base preimage. The new resolver's exact CRLF ranges are `[[59, 64], [106, 126]]`; all other lines are LF. The untouched `lib.rs` raw hash is `5a76d099592fc4c0d6b591561a1d5acc593d5dfe44488da6f15281dd7f813639`.

Read-only native audit snapshots:

| Path under `telegram-ios/submodules/` | Raw SHA-256 |
| --- | --- |
| `MtProtoKit/PublicHeaders/MtProtoKit/MTAppNetworkResolver.h` | `c90f37ad00ed6f727242db88fcca5c2b57bfe08892c60094b2aa4c6575a841e5` |
| `MtProtoKit/Sources/MTAppNetworkResolver.m` | `0bcd148eaca59ecc9565578d7f3a24a3a2976f4497327b4f28a7e922d7510a66` |
| `TelegramCore/Sources/ExteralessNetwork/ExteralessNetworkResolverRuntime.swift` | `74056ba7111cf42222993d16e5576b2708ce39d468950ebe5940854026ed8603` |

## Outer delivery

Coordinator delivery files:

1. `telegram-ios/build-system/exteraless-patches/mtproto-engine-native-dns.patch` — tracked payload; raw SHA-256 `93ec3e78929a5ff22c85c04af8060fe447f446270e38bec06e2a34abd1a35366` (17299 bytes).
2. `telegram-ios/build-system/exteraless-patches/manifest.json` — tracked manifest; raw SHA-256 `6bc8925baa7dca7dded27b1aaed638ecdc5396efaf0db3b1cf3a99ab9ef6868f`.
3. `docs/wave-2/ios-rust-resolver-typecheck.md` — this new handoff.

The nested resolver is the local prepared source, delivered through those outer assets; **do not stage the nested gitlink or commit the nested repository**. All original base preimage hashes/sizes are preserved. The patch was regenerated against the pinned base with `git diff --no-ext-diff --no-textconv --no-renames --full-index --unified=0` for exactly the three manifest paths; the regenerated bytes equal the published asset. Only the resolver section differs from the incoming payload.

The existing `tools/runtime/apply_telegram_client_patches.py` default root (`telegram-ios`), pinned contract, and fail-closed state validation are retained. `telegram-ios/build-system/Make/ClientSourcePatches.py` has raw SHA-256 `d21655a3ec43486f79660f0adf56dadcb336662d2f1aa8b67f52bc45269e755d`. The new complete source fingerprint is `737ac0f2d1e9dd9b5b775095fdf84054a834b2ae8c371450fe2945536c678980`.

## Verification and native pending

- `python -B -m unittest discover -s tools/runtime/tests -p test_client_source_patches.py -v`: **11 passed**, 1.493 seconds (1.874 seconds total process time, bounded to 28 seconds).
- `python -B tools/runtime/apply_telegram_client_patches.py --verify-only --prove-clean-base --report <report>`: **passed**, 0.936 seconds. Three raw pinned `git show` blobs in a gitless fixture replay to the exact current source bytes; repeated preparation performs no writes; tampering with each of the three files and mixed pre/post states is rejected. `native_execution_verified` is explicitly `false`.
- Nested resolver and outer payload/manifest `git diff --check`: **passed**.
- Host Rust compilation/typechecking: **not run**. `rustc`, `cargo`, and `rustup` are unavailable on PATH; the standard `.cargo` and `.rustup` locations are absent. No toolchain was downloaded and no substitute Apple compilation is claimed.
- Apple Rust compilation and final native linking require the coordinator's next supported full-app build. The separately owned MtProtoKit `dns_sd` link blocker remains with the coordinator. No CI, commit, push, live DNS/socket/network operation or external plugin was invoked.

Local evidence:

- `C:\Users\sasha\AppData\Local\Temp\opencode\ios-rust-resolver-patch-tests-ypq705bh\test_client_source_patches.log`
- `C:\Users\sasha\AppData\Local\Temp\opencode\ios-rust-resolver-clean-base-yf6ulp5i\source-proof.json`
- `C:\Users\sasha\AppData\Local\Temp\opencode\ios-rust-resolver-clean-base-yf6ulp5i\source-proof.log`
