# Cloud legacy remediation — source/import and AI boundary

Implemented source in owned Cloud files, with explicit native preview/restore.
C1–C6/AppDelegate/Network/CoreSettings/Tools journal files remain with their owners.
Source checks passed; local Swift/Xcode execution and UI frame proof remain
unavailable in this Windows session. Coordinator CI `43700711108` on `f99909b5`
compiled the whole Core target but failed the CAS-retry fixture described below.
That historical run is not a green Cloud batch or proof for the subsequent fixes.

## FROZEN CI-retry slice — `43700711108` / `f99909b5`

**FROZEN for separate coordinator validation.** The replayable patch and SHA-256
manifest are in the approved local artifact directory:

- `C:\Users\sasha\AppData\Local\Temp\opencode\cloud-ci43700711108-f99909b5.patch`
- `C:\Users\sasha\AppData\Local\Temp\opencode\cloud-ci43700711108-f99909b5.manifest.json`

Apply that immutable artifact against the named base (or an equivalent clean
snapshot). Later CA-01/03/05/06 work can change the live Cloud files; it is not
part of this frozen CI-retry artifact. The manifest pins the exact saved contents.

Confirmed cause: the expected rejected public CAS leaves
`ClientSettingsSnapshot.lastError = concurrentModification`. A subsequent cached
snapshot is correctly rejected by `CloudLegacySettingsArchive.inspect`; both the
failed fixture and production `CloudSyncSession.previewAndroid` lacked an actual
preparation reload. Local log `core-f99909b-failed.log:676–678` confirms the single
`testLegacyOverlayCASPreservesAbsentUnrelatedFieldsAndRejectsChangedPresence`
failure as `localStorage`.

Fix:

- `CloudSettingsArchive.readLatestSnapshot(settings:)` performs real
  `ClientSettings.reload()` and captures the fresh snapshot on a detached utility
  task, with cancellation propagation. It returns only a healthy snapshot and
  propagates actual reload/current-snapshot errors. It does not erase an error flag.
- Sync/export and **both** native/Android fresh previews use this preparation,
  then recheck the original account-context generation before any remote work.
  Existing confirmed restore plans retain their exact old CAS image.
- The pure native/legacy inspection health guards remain intact. Invalid stored
  shape and unavailable Keychain stay closed. Full preparation validates secure
  storage even when credential export is off; the export function's opt-out still
  performs zero credential reads of its own.
- A reload failure's error-only settings invalidation cannot re-arm automatic
  sync. New user edits or foreground events retain the original retry policy.

Frozen code/test files:

1. `swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift`
2. `swift/ExteralessCore/Sources/ExteralessCore/CloudSyncSession.swift`
3. `swift/ExteralessCore/Sources/ExteralessCore/CloudAutoSync.swift`
4. `swift/ExteralessCore/Tests/ExteralessCoreTests/CloudLegacyImportTests.swift`
5. `swift/ExteralessCore/Tests/ExteralessCoreTests/CloudSnapshotRecoveryTests.swift`

The original regression now proves byte-identical rejection, a real independent
writer's changed values/removed overrides, explicit refresh, and preservation of
later unrelated edits. Five new bounded fixtures exercise the actual Android
session retry, native preview/export refresh, invalid shape/Keychain refusal before
remote work, MainActor responsiveness and cancellation during a gated secure read,
and absence of error-driven auto retry. The gate has a two-second deadline; no
fixture needs an account, bot, real network or production Keychain.

Validation for this slice: local UTF-8/whitespace/delimiter checks, three prepared
entrypoints and retained unhealthy-snapshot guard checked. Swift is absent locally;
**the frozen changes and five new tests have not been compiled/executed here**.
The coordinator-reported 45 Settings/75 AI successes belong to the failed historical
run. No CI/commit/push/network action was performed by this owner. The independent
review file is read-only and was not changed.

## Native AI credential API boundary (AI-04/13 coordination)

Read the current `ai-core-remediation.md`, `AICredentials.swift`, `AISettings.swift`
and the closed `AIFeatures.servicesDefinition` before changing Cloud.

`CloudAICredentialBridge.swift` is the isolated native adapter. It uses the **actual
AI implementation** `AICredentialDestination`, `AICredentialBinding.read`,
`validated` and `updated`, rather than cloning the credential envelope format.

- Export reads the exact whitelisted native Keychain item, validates its binding
  against the captured public snapshot and preserves the complete protected value.
  A raw/unbound key or another-origin key is omitted, never rebound/exported for a
  changed public URL.
- Explicit Android import seals only the incoming inline key with `.replace`,
  `previous: ""` and the selected/validated snapshot's endpoint and wire protocol.
  It never reads a stored key to authorize that destination.
- Persistence stays atomic add-only `SecItemAdd`. Existing credentials, including
  their old origin binding, are preserved. Public metadata is restored through CAS;
  AI read-side destination checking decides whether an existing key is usable.
- Fixed vendor keys use native AI key validation and their code-defined endpoints.
- Old raw native-backup values can be retained as **unbound** values. They are not
  granted an origin by public metadata; native readers return no usable key until
  an explicit native credential operation authorizes it. Unbound local keys are
  not exported under an unrelated newly restored endpoint.

**API need for AI owner:** these binding primitives are currently module-internal
in the shared ExteralessCore target, so the adapter compiles against real symbols.
If they are made private/reorganized, expose equivalent no-metadata-mutation
backup/open/seal primitives and update this one adapter. The public
`AISettings.save`/`importAndroidServices` methods are not substitutes for this
boundary: they can replace keys and mutate service selection independently of the
Cloud preview CAS. No raw variable-origin key is silently assigned a destination.

For Android inline credentials, the native confirmation is explicitly labelled
**“Restore and authorize listed incoming keys”**. The preview lists each normalized
scheme/host/effective port/base path/protocol. Only the incoming key is sealed by
the native AI `.replace` primitive for that captured snapshot. Existing local
values are never passed to a rebinding operation. Cancel has no credential effect.

## Original protocol and source evidence

Read the current original files before implementation:

- `CloudSettingsHelper.java:298–433`: `neko_settings`, numbered chunks,
  `gzip_base64_v1`, legacy plain JSON, 3000 UTF-16-character chunks and 50-key batches.
- `SettingsBackupHelper.java:57–170,198–312`: `userconfing` (original spelling),
  `mainconfig`, `nkmrcfg`, optional `aiConfig`; `_long`/`_float` suffixes, primitive
  SharedPreferences values, `aiConfig.services` as a JSON **string**. It excludes
  `history`, device-specific push keys and `nekox_config` from its normal cloud export.
- NekoConfig Java, NaConfig Kotlin and the Kotlin configs' shared Neko preferences;
  `Service.java:18–24,135–159` for closed legacy fields, reasoning clamp and Java hash;
  `AiConfig.java:198–218` for ID/hash/first-service selection precedence.
- `Translator.kt:64–73`, `PresetRegistry.kt:7–17`, `DoubleTap.kt:10–35`,
  `TranscribeHelper.java:60–65`, `NaConfig.kt:822–838` and
  `ChatsConfig.kt:137–147` for actual option/float/percentage semantics.

`CloudRemoteStore.readAndroidSnapshot()` reads original metadata/chunks twice with
metadata bookends, then verifies/decompresses with the bounded native codec. Its
fingerprint includes **both exact metadata and payload**, so a same-timestamp
payload edit also invalidates a preview. Plain pre-gzip chunks use smaller bounded
batches and their original UTF-16 length limit. The native archive protocol/DAG is
retained; no Android timestamp is represented as a native revision or fake ETag.

Restore rereads that fingerprint before lease admission. This is conflict detection
over a server without CAS, not an atomic remote lock. No remote write occurs during
legacy preview/restore. Last-success time is the time after successful local apply,
not `neko_settings_updated_at`; native accepted-head state is retained.

## Mapping and skipped fields

- `CloudLegacyCatalog.swift` is a **reporting-only** index: 511 literal
  preference/source-ID joins from `docs/parity/client-features.json`, plus six
  checked scoped-prefix families. It grants no write access.
- `CloudLegacyRules.swift` has 263 explicit scalar rules: 228 reviewed boolean
  identities, 25 individual typed conversions and 10 named LLM model fields.
  These are original ConfigItem/preference IDs, not the ExteraConfig shim overloads.
  A rule still requires a currently registered, public native definition and
  successful full native validation. Unavailable/mismatched fields are skipped.
- `CloudLegacyAIImport.swift` handles the closed service array, stable-ID/hash
  selection and 16 named standalone service-key aliases. Public service output is
  validated by `AIFeatures.servicesDefinition` and contains exactly
  `id/name/url/model/reasoningEffort/wireProtocol`, at most 100 records. Keys remain
  in a separate protected collection; unknown service fields reject the group.
- Incoming source primitive types and suffixes are checked. No bool/number/string
  coercion and no general Android integer → native enum cast exists. Translation,
  LLM and transcription providers and double-tap actions use explicit named native
  cases. Unsupported Google-CN/premium-transcription options stay skipped.
- **Important source distinction:** `OEChatsFlashWarmth/Intensity` are integer
  percentages, **not** ExteraConfig's fractional getter values. `LlmTemperature`
  really is a float and requires `_float`. LLM context size is an option index for
  1/3/5/7/10 messages. Old translation mode uses the original migration and commits
  its native migration guard in the same public batch.
- `SortByUnread` and `sort_by_unread` remain distinct original IDs; neither is
  silently aliased into the other. Source-owned state, unsupported options, missing
  assets and account-local records have explicit skip reasons.

Every source preference in a preview receives mapped/skipped/credential reporting.
Known fields carry their original ID; unknown/stock preferences retain their exact
source preference name and explicitly have no invented inventory ID. No skipped
field is reported as ported or written to a dummy key.

Stock `mainconfig`/theme preferences without a ClientSettings adapter are reported
as **requiring a native Telegram preferences adapter**, not as categorically
impossible on iOS. Android hardware/push/filesystem preferences, missing icon/model
assets, private histories/prompts/local-name records, and authorization/passcode/
session/NekoX credentials have distinct reasons. There is no personal file search
or inferred account mapping. API-key inclusion off also skips Cloudflare account
metadata and performs no native credential read/write.

## Apply / host / UI

`CloudLegacySettingsArchive.inspect` builds an immutable `CloudLegacyRestorePlan`.
Only supplied mapped fields enter its shared Tools archive; absent preferences do
not overwrite native defaults or unrelated fields. Duplicate JSON keys (including
escaped-key aliases), invalid service shapes and conflicting fields are rejected
or explicitly skipped before apply.

`CloudSyncSession.previewAndroid()` and `restoreAndroid(_:)` own the account,
fingerprint check, cancellation, no-op rejection and success date. Native host
binding adds `RestoreAndroid` alongside the existing native-archive callback:

```swift
// Set inside the existing owned Cloud integration; no MainRoot signature change.
session.restoreAndroid = { plan, keys, admission in
    try await archiveHost.restore(plan, includeApiKeys: keys, admission: admission)
}
```

The host uses the existing Tools maintenance lease/restorer/journal with
`plan.verifyLocalPreview(settings:)` as the `beforeSettingsCommit` CAS guard.
No Tools/CoreSettings file was changed. The public transaction and optional
add-only Keychain phase retain their existing honest partial-failure semantics;
no-op/skipped-only imports and failed key phases do not advance a success date.

The native Cloud screen now offers **Preview Android settings backup** whenever
the original keys are present, even beside native revisions. Its mapped, skipped
and credential sections show original IDs, native targets, reasons and validated
destinations. Applying requires explicit confirmation; cancel/account retirement
suppresses late work. Changing the inclusion toggle invalidates the preview.

## Bounded evidence and remaining gates

New fixtures cover source percentage/float units, enum meanings, migration state,
distinct aliases, per-field dispositions, absence/presence CAS and unrelated edits,
ID/hash selection, closed service metadata, destination changes, whole protected
value export, raw-unbound preservation, custom LLM/audio endpoint capture, duplicate
JSON, same-timestamp remote conflicts, no-op/date behavior, and tiny original gzip
exports using **actual MTGzip with a local fake transport**. They create no Account
and perform no bot/RPC/network requests.

Total authored Cloud/Client API fixtures: **51 Core + 4 native** (previously 38+2).
The source/receipt checks validate all 511 literal original-key joins and all 228
boolean source types; the whole Postbox import/access check passes. No Swift test
execution or native build claim is made. After compilation, the existing 30-second
`swift test --skip-build --filter 'Cloud|ClientAPI'` gate applies. Native MTGzip
fixtures still need the coordinator's TelegramCore test target wiring.

Remaining: C1–C6 common integration, actual Swift/native/Keychain checks and UI
frames; unsupported preferences remain visible as skipped rather than newly
claimed feature ports. AI/CoreSettings remediator-owned files were only read.
No commit, push, CI, signing, publishing, real account test or user-file search.
