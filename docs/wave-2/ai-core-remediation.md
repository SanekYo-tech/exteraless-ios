# AI Core remediation — AI-04/05/11/12/13/17

Scope: Core `AI*.swift` and Core AI fixtures; provider forms in
`ExteralessAISettingsControllers.swift`; plugin-review snapshot construction only.
Native integration/chat/result/speech/native adapter/rich mapper/engine helper and
shared hooks belong to the native-remediator. The independent review is unchanged.

## AICF-01/02 — current follow-up handoff

Read `reviews/ai-core-followup.md`. That independent review closed AI-04/05/12/17
at the source/fixture level and identified these two remaining P2 paths. This patch
addresses AICF-01/02 in `AITranslation.swift` and `AISettings.swift`; public Core API
signatures are unchanged.

- **AICF-01 / AI-11:** the private LLM path now receives the effective HTML intent
  from `original.spans`, after `preserveFormatting` has been applied, and passes it
  to the existing Google request builder. Cloud fallback receives the same encoded
  `q`/`data-e` tags with `format=html`; plain or formatting-disabled input uses
  `format=text`. The fresh Google request carries only its own configured credential.
  The existing protected-span decoder/validation remains in the return path.
- **AICF-02 / AI-13:** Android import's nil/null/empty credential intent now uses
  `reset`, following the coordinator's `e59` service/endpoint removal correction.
  Import snapshots prior **presence and value** for each secret, and prior values
  plus presence for `ai.services` / `ai.selectedServiceId`. Rollback restores the
  public keys in one update/reset batch and restores each secret with set or reset
  according to prior presence. A previously stored empty override is restored as
  empty; a previously absent item stays absent. This consumes SC-05 semantics.

Two targeted XCTest methods were added:

1. `AIRetryTests.testAICF01CloudFallbackKeepsHTMLIntentSpansAndSeparateCredentials`:
   four scripted cases, each three 502 responses then Google Cloud. Checks the
   exact encoded query, HTML/plain mode, absence of LLM Authorization/body keys,
   translated bold/link/emoji UTF-16 ranges, formatting-disabled input and rejection
   of a modified protected emoji with `.formattingLost`.
2. `AILifecycleTests.testAICF02AndroidImportRemovalAndRollbackKeepOverridePresence`:
   missing/null/empty import keys over absent/explicit-empty/bound prior items;
   each removal permits a real fixture `insertIfAbsent` through the Cloud credential
   contract and the native reader returns the restored bound key after reload.
   Four second-secret-write fault cases cover absent/empty/bound credentials and
   absent, explicit-default and nondefault public overrides. They compare backend
   key sets/bytes, stored presence, effective values and the settings-file bytes;
   the unattempted third key remains absent.

**Current evidence:** all four changed Swift files parsed without syntax errors;
scoped `git diff --check` passed. The owned AI set now declares **75 tests (73 + 2)**.
`swift` remains unavailable on this host, so the new XCTest methods and Swift
typechecking have **not run here**. Coordinator command after rebuilding tests:

`timeout 30s swift test --package-path swift/ExteralessCore --skip-build --filter AICF`

Coordinator-reported baseline: `43696986849` (`e59`) green **390 Core / 90 Host /
16 Hooks**; whole-wave Host `43698196787` (`dcc13004`) green, counts pending the
coordinator's report. Those runs predate these two fixtures. Their results were
not queried here; updated CI and independent follow-up are still the acceptance
evidence for AICF-01/02.

## Current API contract for native-remediator

The early contract is now implemented in source:

```swift
public enum AICredentialUpdate: Equatable, Sendable {
    case unchanged
    case replace(String)
    case remove
}

// Same read signature: empty on missing, unbound legacy or destination mismatch.
AISettings.apiKey(for service: AIService) -> String

// Replacement for save(service:apiKey:). Metadata-only save must use .unchanged.
AISettings.save(service: AIService, credential: AICredentialUpdate,
                authorizeDestinationChange: Bool = false) throws

// Trusted native provider-form operations. Generic setPublic cannot bind a key.
AISettings.saveCustomLLM(baseURL: String, credential: AICredentialUpdate,
                       authorizeDestinationChange: Bool = false) throws
AISettings.saveOpenAITranscription(baseURL: String, credential: AICredentialUpdate,
                                 authorizeDestinationChange: Bool = false) throws
AISettings.saveLLMKey(preset: AILLMPreset, credential: AICredentialUpdate) throws

AISettings.llmAPIKeys(for service: AIService) -> [String]
AISettings.openAITranscriptionAPIKey(baseURL: String) -> String
```

`authorizeDestinationChange` is set only for a user's explicit native endpoint
edit/save or explicit “use stored key for this endpoint” action. A metadata-only
save of a public/restored URL must leave it false. `.unchanged` never removes a
stored credential and never authorizes a new destination by itself.

Credentials for assistant services, custom LLM and OpenAI-compatible audio become
single protected records at their existing secret setting keys, containing the
credential and its trusted normalized destination. The binding covers scheme,
host, effective port, base path and wire protocol. Public metadata remains
exportable. Existing unbound raw credentials are preserved, but cannot be sent
until an explicit native credential operation binds them; public URL values are
not trusted migration evidence.

`AITranslationConfiguration` and `AITranscriptionConfiguration` use the
validated readers internally; consumers using those configurations need no new
read-side code. The native Speech provider form must use `saveOpenAITranscription`
for its base URL/key edits instead of directly setting the two independent values.
Fixed vendor key fields (Gemini/Workers/known LLM presets) keep their normal raw-key
format and code-defined destinations.

Provider forms must prepare/recover before their first credential read. `.remove`
is the only metadata-save intent which deletes a known key. Explicit Android
service import remains supported and writes canonical metadata plus trusted
credential records, preserving legacy stable-ID/hash selection.

`saveLLMKey` replacement is for fixed, code-defined presets. For `.custom`, a
replacement must use `saveCustomLLM(baseURL:credential:)` with the **URL displayed
when the native editor opened**. It must not fetch a mutable public URL later
inside the credential-save task. The same rule applies to the audio form's
`saveOpenAITranscription`: capture that form's endpoint. Removing/clearing an
endpoint with `.unchanged` preserves the stored key, without rebinding it.

The three variable-destination credential families are now opaque string envelopes
(`exteraless.ai-credential.v1\n` + JSON), still stored at the existing Keychain keys.
Credential-aware backups can round-trip that entire protected value; they must not
strip its binding or infer one from public metadata. Existing raw restored keys
remain unbound until native authorization. Public service metadata backup stays
unchanged in kind (closed, public array; 100 records maximum).

Allocation changes preserve `AIPluginReviewTools(snapshot:)` and existing public
tool methods. Optional `mode: AIPluginReviewMode`, `limits: AIPluginReviewLimits`
and a synchronous cancellation-check seam support bounded construction/fixtures.
The owned native review builder now selects `.sourceExcerpt` before constructing
the tools actor when `ai.disableTools` is enabled.

## Implemented source corrections

### AI-04 / AI-13 — credential destination, schema and save intent

- `AICredentials.swift`: the protected record binds the credential to setting/service
  identity, normalized scheme/host/effective port/base path and wire protocol.
  Assistant, custom LLM and compatible audio readers match the **same captured
  service/URL** subsequently used by the request builder. Fixed LLM preset readers
  also reject a mismatched service ID, destination or protocol.
- `AISettings.swift`: metadata saves register/recover dynamic secrets, then apply
  `.unchanged`, `.replace` or `.remove`. `.unchanged` performs no key mutation unless
  a trusted native caller explicitly authorizes rebinding. Empty `.replace` is an
  error; only `.remove` deletes. Public metadata/selection are written as one public
  batch after validation. Explicit Android import still resolves original signed
  Java UTF-16 hashes and writes canonical service records with bound credentials.
- `AIFeatures.servicesDefinition` consumes the CoreSettings author's actual
  `valueShape` contract from `docs/wave-2/settings-shape.md`. The public array is
  capped at **100 records**; each closed object requires `id/name/url/model` strings,
  integer `reasoningEffort`, and string `wireProtocol`. Unknown fields, nested
  credentials and wrong types are rejected by the persistence boundary. Schema
  defaults remain empty; no temporary permissive schema publishes legacy raw data.
  Invalid persisted raw records fail registration and are absent from AI snapshots;
  this path does not invent trust from old public URLs.
- `AITranslationConfiguration` / `AITranscriptionConfiguration` consume the bound
  readers. A public destination change yields no previous credential; generation
  fails before transport rather than falling back with that key.
- Provider-list, service-editor and LLM-provider forms prepare before their first
  credential read, display a preparation/retry state, preserve metadata-only intent,
  and expose an explicit stored-key binding action. Custom key edits capture the
  displayed endpoint. The Speech-owner form must use the audio contract above.

Fixtures: `AICredentialsTests.swift` (8), plus the existing Android-import and
recreation tests updated to typed intent. Covered paths include host, port, base
path, protocol and service-ID changes; unsigned model discovery on mismatch; custom
LLM/audio URLs; explicit native rebinding; raw-key migration without implicit trust;
two instances → reload → metadata-only save preserving exact backend bytes; rejected
raw/schema payloads before persistence and normal metadata export.

### AI-05 — bounded review construction and decoding

- `AIReviewSourceContext.swift` retains UTF-8 buffers with a **global sparse-index
  budget**, not a `String` per line. Pages materialize only requested line prefixes.
  UTF-8 validation, scalar-safe excerpt/page boundaries and long loops have
  cancellation checks. Empty/newline-dense source does not create per-line objects.
- `AIReviewArchive.forEachEntry` admits each declared size against the remaining
  aggregate budget **before copying/inflating/appending** that entry. The source
  builder passes its remaining bytes/count into each subsequent archive; there is
  no combined intermediate array of inflated entries. The visitor can stop early.
- Embedded base64 is scanned incrementally over byte ranges, including multi-line
  blocks. Count, decoded-byte and candidate-attempt limits are shared across all
  files/binary blobs. No regular-expression match array is constructed. Invalid
  candidates consume the attempt budget too. Base64, DEFLATE and checksums cooperate
  with cancellation; decoded binary readable strings and ZIP listings are paged.
- Excerpts and metadata are built directly into bounded buffers. `.sourceExcerpt`
  does not build source indexes or discover blobs, and stops archive/file enumeration
  once the excerpt is filled. The native controller selects this mode before work.

| Production bound | Maximum |
|---|---:|
| Aggregate snapshot input | 16 MiB / 500 files |
| Aggregate expanded source | 32 MiB / 500 entries |
| One inflated ZIP entry | 8 MiB |
| Sparse line-index records, all files | 4,096 |
| Retained blobs / base64 attempts, all files | 500 / 500 |
| Retained decoded blob bytes, all files | 16 MiB |
| Source excerpt | 48 KiB UTF-8 |
| Prompt metadata / file-list text | 2 KiB / 8 KiB UTF-8 |
| Source page | 400 lines, 1,000 UTF-16 units per line |
| Tool result | 30,000 UTF-16 units |

`statistics` reports actual entry/byte/index/blob/candidate/excerpt counts. Its
`blobScanBytes` measures pattern-scanning visits, not the separate UTF-8 validation
and line-boundary traversal. It is not a measurement of peak resident memory.

Fixtures: `AIReviewAllocationTests.swift` (12), using small injected limits. They
cover four compressed newline-dense entries with five shared index slots; aggregate
exhaustion within/across ZIPs before deliberately malformed later DEFLATE is reached;
visitor early stop; many blobs on one long line and across files; byte/count/candidate
caps including binary blobs; multi-line base64; a long Unicode line; disabled-tools
early stop; deterministic cooperative cancellation and an actually cancelled Task.
The existing three review/codec/cache tests are retained.

### AI-11 — recoverable retry and fallback

`AITranslationClient` retries network/timeout/429, 5xx and empty/invalid successful
responses for at most **three non-streaming attempts**, with 1 s / 2 s backoff and
then one Google fallback. Configuration, credentials, cancellation, blocked,
length-limited and incomplete-generation errors are terminal. The optional-parameter
400 retry in `AIClient` additionally checks that no output event has been emitted.
The injectable delay preserves production backoff while fixtures run without waiting.

Fixtures: `AIRetryTests.swift` (6) plus the partial-stream fixture in `AIClientTests`:
503 → success/key rotation; three 502 → Google; malformed/empty response → bounded
fallback; 401/403/cancellation/partial failures → one attempt; cancellation during
backoff; actual length-limited provider JSON; partial SSE followed by a late error.

### AI-12 — provider continuation state

`AIReasoningContinuation.swift` retains an allowlisted, bounded wire value separately
from display reasoning. The next assistant tool-round message receives exact
`reasoning_content`, supported `reasoning`/`thinking` strings or content/signature
objects, and known `reasoning_details` text/summary/encrypted entries with their
ID, format, index, signature and opaque data. Unknown fields/types are not replayed.
State is capped at 64 detail entries / 256 KiB, lives only in the current tool
conversation and is not written to assistant history or displayed as opaque data.

Three new `AIClientTests` cover DeepSeek-style sentinel replay, structured opaque
state/object signatures and unknown-field exclusion, and rejection before tool
execution when the continuation budget is exceeded. These are offline wire
fixtures, not current vendor-acceptance evidence.

### AI-17 — manual-marker recency and eviction

`AIManualTranslations.set/state` and `AIManualTranslationState` keep their public
signatures. The private persisted record adds a mutation sequence (missing means
legacy zero). New/updated markers are always retained; overflow evicts hidden
entries first, then the oldest visible entries, with deterministic key-order ties.
The dictionary stays **≤2,048**. Sequence overflow compacts existing order. A corrupt
secure record is preserved instead of silently replaced by a one-entry dictionary.

Fixtures: `AIManualTranslationTests.swift` (3): seeded original-format 2,048 markers
→ 2,049th/2,050th insertion and recreation; recent/hidden eviction and removal;
sequence overflow and preservation of malformed secure bytes. A successful native
translation can no longer hit permanent marker-cap exhaustion.

## Initial remediation validation (historical)

- **30 owned Swift files parsed with zero syntax errors**, including both changed
  native UI files. Scoped whitespace/diff checks passed. The source parse initially
  caught a malformed test dictionary, which was corrected before the passing run.
- Python's standard `zlib`/`zipfile` independently validated the new small DEFLATE
  and four-entry ZIP fixture: **438 compressed bytes → 4,096 LF bytes**. **25 complete
  JSON protocol fixture literals** also parsed successfully. These checks validate
  fixture bytes, not Swift behavior.
- **73 XCTest methods are now declared in this owner's AI test set: 40 existing +
  33 new**. Native-remediator `AINativePolicy*` files/tests are excluded from these
  ownership/count claims.
- Attempted the local `swift test --package-path swift/ExteralessCore --skip-build
  --filter AI` command with a 30 s process bound. **NOT RUN:** this Windows host has
  no `swift`/`swiftc`; no XCTest process started. WSL is also not installed. Swift 6
  typechecking, XCTest assertions and native linkage remain coordinator checks.

Coordinator: build the updated Core tests, then run the AI filter under the existing
30 s bound. The previously reported 122-test CI result predates these changes and
does not validate them. Native compilation and independent re-review remain required;
no parity status or `ported` evidence was promoted by this source remediation.

Native frame expectations: provider forms show preparation rather than a transient
empty-key status; reload + metadata Save keeps the configured-key state; a public
endpoint change shows the missing-binding state until explicit native authorization;
secure-store failure exposes retry without deleting the key. Review cancellation
must dismiss loading without a stale result, and disabled-tools review must remain
responsive on the newline/long-line fixture. These frames and device memory/lifecycle
behavior have **not** been recorded here.
