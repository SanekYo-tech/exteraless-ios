# CA-04 P1 — credential-bearing RPC log boundaries

**CA-04 remediation is applied to source, including all coordinator propagation
and the mandatory earlier RustEngineRuntime callback suppression. Source wiring
is complete; the six native fixtures and Apple execution remain pending. No
native/runtime verification or final review closure is claimed.**

Finding: `reviews/cloud-api.md:138–166`. This slice changes logging output, not
the raw RPC errors used for retry/flood/auth decisions or native completion.
No CI, commit, account, network, external dependency or provider call was run.

## Classification and propagation contract

`MtProtoKit/MTRequestLogContext.h/.m` supplies immutable, interned logging contexts.
The exact protected set is:

- `bots.invokeWebViewCustomMethod` (the entire method);
- `auth.sendCode`, `auth.exportLoginToken`, `auth.importBotAuthorization`,
  `auth.importWebTokenAuthorization`, `auth.initPasskeyLogin`,
  `auth.initFirebasePnvLogin` — exactly the six existing ClientAPI identity methods.

The native table is pinned to their **constructor IDs in `TelegramApi/swift_scheme.tl`**.
The first TL constructor, or an exact known method name, can add protection. A
supplied name cannot downgrade a recognized payload. No user-string substring,
parameter contents, error-text regex, or token/URL pattern is used to infer trust.
Protected output uses the compiled canonical method name, numeric code and the
fixed `CREDENTIAL_RPC_ERROR` category even when `Logger.redactSensitiveData` is false.

`NetworkEngineRequest.logContext` is a `let`, selected before submission. Its
convenience initializer covers the existing Cloud name-only path; constructor
recognition covers generated auth payloads. Both Network request builders now
explicitly propagate the context, and the applied TL transformation path merges
the original and final contexts, retaining protection across a replacement.

`mtProtoKitRequestForEngineRequest` is the shipping adapter used by
`MtProtoKitRequestService.add`, and passes that context to `MTRequest`. ObjC
payload setup copies the payload and may only strengthen classification; the
context objects themselves have no mutable/public privacy flag. Context, raw
metadata and dependency tag remain attached across native retry/handover.

## Applied logging paths

| Boundary | Applied behavior |
|---|---|
| MtProtoKit add-request / handover logs | Use `metadataForLogging`, not raw metadata. |
| MtProtoKit outgoing/prepared-message debug descriptions | `MTOutgoingMessage` receives protected metadata/short metadata. Ordinary descriptions remain lazy, preserving the disabled-log fast path. |
| MtProtoKit success and RPC-error logs before completion | Shipping `MTRequestMessageService.responseLogDescription(request:result:error:)` substitutes fixed protected response/error categories **before** object-description evaluation. |
| MtProtoKit APNs/reCAPTCHA decorator descriptions | Fixed redacted labels; nonce/secret/token remain only in the real serialized payload and verification state. |
| Rust failed / retry / worker-401 / authorization / soft-reset logs | Shipping `RustRequestLog.failure` uses the associated request context; missing association gets a fixed redacted `unattributed` category. |
| Rust send / move / parse-failure / handover logs | Use `NetworkEngineRequest.logShortDescription`. |
| Rust unassociated key-creation / bind diagnostics | Redacted category, numeric code; raw event remains available to existing decision logic. |
| Failure `description`, `debugDescription`, `Mirror` | `NetworkEngineRequestFailure` uses its logging context. `failure.error` is still the original `MTRpcError`. |
| Telemetry copies | Credential text is replaced only in the value passed to the logging/telemetry sink. The retry policy and native completion receive the original error/context. |
| Network request-logger wrappers and both builders | Applied canonical classification and forced protected metadata at `Network.swift:35–36,53–54,1422,1498`. |
| TL transformed requests | Applied original/final context merge at `TLNetworkRequest.swift:322–323`. |
| Earlier free-form Rust callback | Applied `RustRequestLog.nativeEngineMessage(level:)` at `RustEngineRuntime.swift:129`, before either Logger sink. |

The actual MtProtoKit `rpcError` handling block, flood-wait parsing, auth branches
and `completed(rpcResult, info, rpcError)` retain their raw input. Rust predicates,
`pending.errorState`, retry decisions and the final `MTRpcError(event.code,
event.text)` likewise retain it. No protocol response or UI error is fabricated.
Cloud's existing `.network` UI redaction remains downstream.

## Additional earlier Rust trace — applied callback suppression

The audit also found frozen
`third-party/mtproto-engine/crates/mtproto-engine/src/session_runtime.rs:log_query_trace`:
`QueryTrace::Answered` formats the server error, and `pump_rpc_events` emits that
trace **before** the structured FFI event. Before remediation, the Swift
`RustEngineRuntime.rustEngineLogCallback` forwarded it verbatim to Logger.

That unstructured callback supplies only level/free-form text, with no trusted
request classification. Parsing a request ID or masking substrings in it would
create the bypass CA-04 forbids. The applied Swift callback now emits
`RustRequestLog.nativeEngineMessage(level:)` only, without decoding the free-form
message. Structured request events separately retain canonical method/code.
This intentionally trades unstructured engine trace detail for confidentiality;
typed Swift request/transport diagnostics and raw engine error semantics remain.

Coordinator applied this mandatory Swift callback change. The TLS N04 lane patch
is also applied with CA-04 preserved, per coordinator; the callback postimage was
read back here. Nested Rust `.rs` and cohort source/pins remain frozen.

## Coordinator/AppCloud application receipt

[`network-error-redaction-shared.patch`](network-error-redaction-shared.patch) is
preserved as a marked **historical reference**. All its source changes were applied
by coordinator and read back; do not reapply it to the frozen cohort:

1. `Network.swift`: explicitly passes canonical description/payload classification
   from both request builders; protects `WrappedFunctionDescription` and
   `WrappedShortFunctionDescription` at the request-logger entry, independent of
   the generic redaction switch.
2. `TLNetworkRequest.swift`: merges original/final classifications before constructing
   the immutable engine request, preserving existing hook, dependency and retry logic.
3. **`RustEngineRuntime.swift`**: suppresses the earlier unstructured native trace at
   its Swift callback using the provided formatter.

No `Account.swift` insertion is necessary: it does not construct these request
objects or format their errors. `NetworkLogging` and `Logger` sinks only forward
already-formatted strings; they are not token-redaction boundaries. The inspected
`MTInternalMessageParser` parses errors but logs parse categories/counts, not their
raw text. Key-binding-only MtProtoKit services do not carry any of the seven API
methods; their raw-error behavior is outside CA-04's request classification.

Build owner: new `.m`/public header are covered by MtProtoKit's source/header
globs; `RustRequestLog.swift` by its existing source glob. Existing MtProtoKit,
TelegramCore, TelegramApi and XCTest dependencies suffice. No BUILD/MODULE edits
or new runtime dependency were made here.

## Bounded native fixtures / verification

- `TelegramCore/Tests/NetworkCredentialLogTests.swift`: **4 tests**, all seven
  constructor/name cases and both generic redaction settings, through the actual
  shipping MtProtoKit adapter and response formatter; metadata/result description
  evaluation is counted, including an actual generated auth factory payload.
  Also verifies canonical classification cannot downgrade,
  raw retry context/native error identity survive, and failure dump/description
  contains method/code but not the synthetic sentinel.
- `MTProtoRustEngine/Tests/MTProtoRustEngineTests/RustCredentialLogTests.swift`:
  **2 tests**, both settings, all seven methods and six canned error codes decoded
  from `MTEvent`, through the same formatter used by failed/retry/auth logs;
  plus the unattributed/free-form callback formatter. No engine/account is created.
- Fixtures use only `CA04_SYNTHETIC_SENTINEL`, constructor IDs and scalar metadata;
  they contain no API-hash/token material. All loops are finite; no waits/sockets.
  Execute the targeted native suites with a **30 s bound** on coordinator's
   available Xcode 27.1 / `xcode-27` environment after building the frozen cohort.
- Native fixture execution is **pending**, not represented by a source grep or a
  prior FunctionDescription-only contract test. This agent's local source checks
  and diff checks are recorded separately below.

Historical pre-application verification: **6 source checks passed in 0.009 s** and
the scoped diff check passed. The checker now reads the actual Network wrappers,
both request builders, TL context merge and Runtime suppression **postimages**;
it no longer applies a patch in memory or requires unapplied preimages. Schema,
shipping formatter, raw-error preservation, fixture paths and frozen Rust
hash/byte-length checks remain. **All 6 postimage source checks passed in 0.008 s**
via `python docs/wave-2/tests/network_error_redaction_source_fixtures.py`.
The six native tests and Apple execution are still pending; source matching is
not their substitute.
