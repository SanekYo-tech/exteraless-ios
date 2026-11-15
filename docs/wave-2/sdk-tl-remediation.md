# SDK TL / native-boundary remediation — source handoff

Follow-up SDK02/03/04 and HNS-F03/F04 corrections, final **49/49** Python results and
the **272/4/32** registered Config receipt are in `sdk-adapters-final.md`. The
42-pass/drift observations below are the earlier TL/HNS slice, retained as history.

Owned findings: **TLN06/07/08/11**, SDK **HNS04**, and the real-CPython probe join for
**HNS02/03**. The coordinator's **TLN02** native text-origin fix is exercised by the
dedicated TL child. Independent review files remain the historical findings.

## SDK changes

| Finding | Applied behavior |
|---|---|
| TLN06 | False, malformed or throwing `tlCancel` retains the pending lease. Only positive cancellation closes it. Completion runs once and native FIFO release owns its C handle. Owner/native-ticket checks reject stale tokens; identity-checked removal and publication preserve a replacement/early-completed request. |
| TLN07 | Rich/reply/scheduled text uses `sendMedia(kind:text)`; text edits use `editMedia(kind:text)`. No getPeer/raw-RPC detour or extra messages.read/network permission. Caption/entities/silent/schedule/reply presence is preserved; native preparation retains paid/restriction responsibility. Explicit empty edits and explicit spoiler false differ from omission. |
| TLN08 | Generated `flags.n?true` fields rewrite their own bits on mutation/serialization. Other bits are retained, including unknown bits for native rejection. Value-optionals/shared-bit companions are never synthesized or dropped. Native mask validation stays strict. |
| TLN11 | Declared root Vector results use registered `org.telegram.tgnet.Vector` with final `.objects`, read-only context and wire-array serialization. Int/Long wrappers and `toIntArray()` follow the source data surface. Nested vectors stay ArrayList; no fake constructor definition or pointer metadata. |
| HNS04 | `setting_changed_json(key,value_json,account=None)` and `setting_click_json(callback_id,account=None)` preserve old arities, reject Bool/invalid Int32 indexes, and enter the captured account scope for write and callback. |

Runtime UI-author patch is applied; hashes, preserved Config regions and source
checks are in `sdk-runtime-hns-stitch.md`.

## Native probe: three independent children

Run the existing driver on the coordinator's Mac after the Host/native cohort is
ready (matching CPython 3.12 and sealed vendor bundle):

```sh
python tools/runtime/check_swift_plugin_embedding.py \
  --python <matching-CPython-3.12> \
  --python-root <repository-or-staged-python-root> \
  --output <empty-absolute-directory>
```

Each child has an independent **30-second** cap. C engine/bridge sources and the
existing `build-inputs.json` fingerprint filename are retained. Prior C callback
test numbering is not changed. The driver compiles the actual Foundation
`TLCodec.swift` and `TLSchemaGenerated.swift`; the TL child checks their source and
layout pins against the SDK JSON schema. Own plugin sources and canned payloads
are bounded at 32 KiB.

### Original SDK child

Original baseline lifetime/UI/reflection checks remain mandatory. Its request
delegate now checks `response.objects`, the actual Android Vector surface.

### TL child — `swift-sdk-tl-smoke.json`

Two real SDK plugins (`nativeTLSdkZ` = alpha/first priority; `nativeTLSdkA` = beta)
execute through actual Host/C/CPython workers:

- Original priority/MODIFY_FINAL/CANCEL/invalid-edit and update/container checks.
- `silent false → true → false`, flags2, and valid/missing/inconsistent bot shared-bit
  companions pass through the **real native binary codec between plugins**. Unknown
  bits and mismatched value-optionals remain errors; the next plugin sees the kept
  original after rejection.
- Root User/Int/Long vectors are modified through `.objects`, normalized against the
  declared method result and observed by the next plugin; nested usernames remains
  ArrayList. Int64 values above 2^53 remain exact.
- False/throwing cancellation preserves a legitimate completion; positive cancellation
  suppresses it. Eight transient native request handles are released exactly once.
- Messages.send-only rich/scheduled/edit calls reach the exact native DTO endpoint.
  Native-authored canned local IDs/edit receipts reach delegates; a paid-send error
  is logged. This recorder does not execute production enqueue/Updates application.
- Plain `client_utils.send_text` inside alpha's pre-request hook reaches the legacy
  BridgeServices text DTO with native `origin.pluginIds == [alpha]`. A detached native
  hop forwards that ancestry: only beta runs. An unrelated direct public
  `Runtime.sendMessage` has nil ancestry and enters alpha + beta.

Marker: `EXTERALESS_SWIFT_SDK_TL_PROBE_OK`.

### HNS child — `swift-sdk-hns-smoke.json`

`native_hns_probe.plugin` uses real SDK APIs and the finalized Foundation
NativeServices pool, scheduler, operations, cleanup route and transport factories:

- Mandatory `NativeServiceCallbackControl` reaches the actual dispatcher worker
  predicate through `NativeServiceCallbackTransport.callback/result(using:)`.
- Native admission stores `ownerWireToken: owner.wireToken`. SDK cleanup enters
  `NativeServiceCleanupRoute` before active-owner/account/permission lookup.
- A real C reverse call blocks the actual owner worker for a bounded interval.
  User/download/observe callbacks are admitted, then the real permission store or
  `NativeServiceSnapshots` account epoch is revoked. No corresponding Python callback
  source/body runs; each handle has exactly one later FIFO release. A persistent
  observer is not cancelled until its worker predicate has been exercised.
- Positive terminal callback survives native close/lease deallocation, executes once,
  and precedes its C release. No `isOpen` fallback suppresses it.
- A 60-second owner task, persistent peer observer, NotificationCenter observer and
  nine-wrapper UI DTO lease remain live. Host calls **`_exteraless_runtime.unload()`**;
  actual `CallbackLeases.end()` performs cleanup while the current owner is hidden.
  New retiring work is rejected. Maintenance succeeds without process finalization;
  resume creates a distinct C epoch. Duplicate cleanup is checked during retiring
  production-route execution. Old-token replay through Host after destruction/resume
  requires typed SecurityError before the provider and unchanged replacement leases.
  Native backstop sweeps must find
  no uncleaned resources; final native/SDK counts are zero.
- Captured SDK account **41**, distinct from selected slot 2 and record id 9000,
  traverses actual Host update/click → C → SDK write/callback. Both callbacks record 41.

UI here is explicitly a Foundation stored-token DTO recorder. It does not establish
UIKit visibility, UI effect-budget coverage or Telegram delivery. NativeServices
helpers and Host/C/SDK execute real code; no FakeEngine is used by these children.
The third child has 31 unique `(owner token, native lease handle)` retirements across
two plugin epochs. It keeps the original child counts separate.

Marker: `EXTERALESS_SWIFT_SDK_HNS_PROBE_OK`. Parent success requires all three reports,
all required flags and all three markers, including `EXTERALESS_SWIFT_PLUGIN_PROBE_OK`.

## Local checks and remaining gate

- Expanded requested baseline + new TL/HNS/Config tests: **42 behavioral cases passed
  on CPython 3.12.10 and 3.14.8**. Each scenario is a fresh process capped at 20 seconds.
- One separate Config source-receipt check fails on both interpreters because parallel
  Tools/Chat definitions changed after Config freeze. The 308-ID table remains frozen
  at **260/16/32**. A read-only regeneration candidate is **262/14/32**, promoting only
  the two `UploadSpeedBoost` overloads to the newly supplied `tools.uploadBoost`.
  The bool `rearVideoMessages` to native enum-facing conversion still requires review;
  it is not made successful by a mismatched key type. Runtime's applied HNS stitch also
  changes a pinned source hash. No accepted table was silently overwritten.
- Final targeted checks execute the exact native-child Python fixtures, including the
  C engine's Unicode/JSON return convention and captured settings account. JUnit paths
  and exact outcomes are in `tests/sdk-python-checks.json`.
- Python source parsing, Swift delimiter/whitespace checks, patch hashes/reverse
  apply-check and full Postbox import check passed. Delimiter checks are not Swift
  parsing/typechecking. **Swift/Xcode are unavailable here; no new native pass is claimed.**

## Closed SDK-owned source

`python/exteraless_runtime/{_tl.py,__init__.py}`; the SDK-exclusive driver
`tools/runtime/check_swift_plugin_embedding.py`; `python/runtime/smoke` TL/HNS
helpers, Swift DTO fixtures and local plugins; associated targeted tests and handoffs.
Runtime is handed back at the hash in `sdk-runtime-hns-stitch.md`. Config production
adapters/generator remain at their prior freeze. Coordinator owns the Mac run and
subsequent Config/domain reconciliation. No CI/commit/push or external plugin run.
