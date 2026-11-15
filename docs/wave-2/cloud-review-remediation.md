# Cloud review remediation — CA-01/03/05/06

The independent `reviews/cloud-api.md` is read-only. CA-02/general backup write
admission belong to Tools; CA-04 lower engine logs belong to Network. Root/C1–C6
and application configuration remain with the app owner.

## CAF-02/03 follow-up — frozen source correction

Read-only review: `reviews/cloud-api-followup.md`. It source-closes
CA-01/02/03/06; CAF-01's native metadata-helper type belongs to the coordinator.
This delta addresses only CAF-02/03. The coordinator reports that the previous
72 Cloud tests passed in `43712394860` / `93a1badc` (603 Core / 174 Host / 30 Hooks).
Those results precede this delta; no new CI or local Swift execution is claimed.

### CAF-02: capture permission, not just an omitted account write

Both native and Android plans now retain an immutable CF admission decision:
`excluded`, `add` (expected absent), or `retain` (expected present). Public projection
and credential admission consume the same captured decision. The existing host's
pre-public hook checks both presence directions; removal of a previewed existing
token requires a fresh preview just as appearance of a new token does.

The actual optional key phase rechecks the decision. **Retain never calls
`insertIfAbsent`**, so it cannot acquire add permission if another native operation
removes the token. Add rechecks absence and treats a raced duplicate as a conflict
while preserving that independently written local item. A change detected after
public commit reports the existing partial-application error and does not manufacture
a successful credential insertion. Unrelated/local replacement keys remain add-only.

### CAF-03: native opt-out is captured before projection

Native inspection captures local `cloud.includeApiKeys` together with the source
envelope's inclusion flag. An opted-out plan contains no admitted credentials and
no CF account setter/reset. Ordinary admitted public values and reset presence
remain usable; local inclusion permission is not imported. Counts reflect that
projection. Later permission enablement cannot expand an already confirmed opted-out
plan; a new preview is required to include keys.

An empty optional credential phase returns without registration, reload, credential
presence reads or insertion. The native footer now describes the captured preview
intent. Existing whole protected AI strings, their bindings, public CAS, writer
admission and the actual maintenance lease are unchanged by this correction.

### Exact files / bounded proof

- Core: `CloudCloudflareMetadata.swift`, `CloudArchive.swift`,
  `CloudLegacyModels.swift`, `CloudLegacySettingsArchive.swift` under
  `swift/ExteralessCore/Sources/ExteralessCore/`.
- Native footer: `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/ExteralessCloudController.swift`.
- Tests: new `CloudCloudflareAdmissionTests.swift`; the existing
  `CloudArchiveTests.swift` and `CloudReviewRemediationTests.swift` key-import fixtures
  now explicitly enable the local inclusion permission before inspection.
- This handoff. The old review reports are unchanged.

Six new bounded Core fixtures exercise direct apply plus the **same pre-public and
optional-key hooks used by the native host**, driving the real Tools restorer:
present-token removal before commit; removal between host phases; the legacy path;
opted-out native public restore with resets/counts/permission preserved and zero
credential I/O; no permission expansion after preview; independent local replacement
without any incoming CF insertion. Stores and token markers are synthetic; no HTTP,
account operation or real Keychain material is used.

Local source hygiene/boundary checks and the full Postbox check passed. The working
suite has 78 authored Cloud/API Core methods (72 previous + six new); the six new
methods and this delta have **not** been compiled/executed here. Run the focused
fixtures with the existing ≤30-second post-build bound in the next coordinator CI.

**FROZEN artifacts** (new names; older frozen slices remain intact):

- `C:\Users\sasha\AppData\Local\Temp\opencode\cloud-caf02-caf03-93a1badc.patch`
- `C:\Users\sasha\AppData\Local\Temp\opencode\cloud-caf02-caf03-93a1badc.manifest.json`

Core hunks are relative to `93a1badcb0ef414ca5218cf938e3b8e2be47a828`.
The manifest records exact base/target hashes; native footer/handoff hunks use the
captured preceding working versions where those files are not tracked in that base.
This is a source freeze, not a new native/visual or test-pass label.

The separate CI-retry fix is already **FROZEN** in
`C:\Users\sasha\AppData\Local\Temp\opencode\cloud-ci43700711108-f99909b5.patch`,
SHA-256 `d30e8d7d2de779221c01770a6b4b2a62ca16e4da54bb2fdf4bd99190c102c8ae`.
Its companion manifest pins the six saved files. The live tree below contains
subsequent review-remediation work and is not that frozen CI snapshot.

## CA-01 — exact public projection

`CloudPublicRestoreProjection` builds a payload from exactly `settings ∪ resetting`,
with `clientStoredKeys = settings.keys`. Reset placeholders come from the preview's
validated native defaults. Original excluded fields never reach Tools. The native
Cloud archive host validates this invariant before acquiring maintenance. Credential
metadata remains separately retained inside the Cloud plan and is not used to
expand the public write set. The current Tools owner implementation now exposes
`admittedKeys`, `admittedPayload` and `ToolsBackupArchive.revalidate`; its no-expansion
check composes with this Cloud projection. Cloud's host checks the exact values,
reset set, payload keys and stored-key presence before acquiring the shared lease.

The source fixture drives the **real ToolsBackupRestorer** with an admitted portable
flag/reset plus an excluded bot-routing user ID changed after preview. Only the
admitted fields reach the writer; the excluded ID/value/presence survive and counts
match. This covers the former difference between Core direct apply and native host.

## CA-03 — conservative captured repair

`CloudRepairPlan` classifies a first bounded native storage snapshot. Malformed
current-format manifests and their own chunks can be removed only when no valid
record needs them. Valid records and all their parent/chunk namespaces remain
protected. A missing/malformed required parent, cycle, foreign owner, unsupported
format or unknown key grammar rejects repair.

Unknown orphan chunks may be an in-flight upload and are **not** automatically
garbage. Only a locally observed failed uploader that never started publishing its
manifest supplies abandonment evidence. That evidence is process/session-local;
restart does not invent ownership of old orphans.

Before each deletion batch the keys and **exact bytes** must still equal the
captured snapshot minus prior confirmed removals. A second listing never adds
deletion targets. Newly arriving revisions invalidate the operation before their
keys can be deleted. Final verification likewise uses the expected remainder.
The original service still has no conditional delete/CAS; stable-read verification
is not represented as a remote lock. Local accepted heads and last-success state
are preserved by repair.

Fixtures cover healthy H + malformed M, a new healthy revision arriving on the
second listing, a required malformed parent, an unknown orphan, and known failed
local upload chunks. All use in-memory transport; no real remote operation ran.

## CA-05 — opt-in Cloudflare destination metadata

Cloudflare's validated 32-hex account ID is a typed optional attribute of the
**credential entry**. It is exported only together with an included CF token.
`CloudArchivePolicy` still excludes it from the general portable public snapshot;
there is no blanket allowlist expansion and opt-out performs no credential reads.

Inspection recovers the source pair from that entry (or an explicit matching
source metadata field in an older archive), never the target's arbitrary current
account ID. Only an empty or matching target destination without a stored CF token
admits the account write. An existing token retains its existing account/value;
a different configured destination without a token is a conflict. Real secure
presence is rechecked before the public commit, so a key added after preview rejects
the account write. Legacy CF import uses the same conditional projection.

Credential metadata remains separate from the Tools public projection. The original
opaque AI string format for assistant/custom-LLM/audio credentials is unchanged.
All credential insertions remain add-only; the existing separate public/Keychain
phase and partial-failure contract remains, not a new cross-backend transaction.

Fixtures exercise native prepare → inspect → restore to an empty fake store and
build the actual `AITranscriptionRequest` without HTTP, comparing the source/target
account URL and authorization value. Separate cases cover opt-out, an existing
target pair, a token appearing after preview and an already configured different
destination. Credentials are synthetic and never used for authentication.

## CA-06 — actual queued writer admission

`CloudWriteAdmission` is a native lock-only revocable token carrying the captured
**ObjectIdentifier of the actual context**, not an account-record number. Its lock
is released before the writer runs. Revocation wins before admission with zero
effects; an already admitted complete writer finishes once. Cancellation handling
is installed before a detached worker is created. No worker synchronously calls
MainActor.

`ExteralessCloudListController.run` now checks task cancellation, context identity,
availability and generation **before** invoking the operation. `runWriter` carries
the token to the real detached writer. Cloud flag writes, API draft save and API
registration/reload use that boundary. Cancel, context retirement and deinit revoke
pending admission; admitted writers complete. Existing session restore lease
admission continues to own journalled archive commits.

Four bounded Swift fixtures use real ClientSettings/API-draft writes with fake
Keychain, queued barriers and observer counters: cancelled toggle, retired API save,
admitted completion once, and distinct context objects with the same record ID /
pre-cancelled task. Byte values, keychain tuple/journal keys and notifications are
checked. UIKit queue/frame acceptance still needs the native harness; it is not
claimed by the Core token fixtures.

## Frozen Chat migration projection

Applied only the Cloud sections of `chat-media-shared.patch:8–54`:
`ChatLegacyPreferenceMigration` runs on imported `nkmrcfg` before typed conversions.
Source precedence for `DisableChannelMuteButton`, `HideReactions` and
`MessageColoredBackground` is retained. HLS legacy value 1 becomes explicit native
Auto (0) plus prefer-original-quality. No native override is synthesized for absent
or inactive aliases; ignored alias values do not gain authority through catalog
lookup. The Cloud admitted projection and Tools managed-key exclusions still apply.

Three small fixtures cover conflicting canonical/legacy fields, inactive/absent
aliases and Auto-reset value/presence. The Chat helper, AI/native Chat insertion and
shared/root files were not edited by this owner.

## Exact written files in this review delta

Core (all under `swift/ExteralessCore/Sources/ExteralessCore/`):

- New: `CloudPublicRestoreProjection.swift`, `CloudRepairPlan.swift`,
  `CloudCloudflareMetadata.swift`, `CloudWriteAdmission.swift`.
- Updated: `CloudArchive.swift`, `CloudRemoteStore.swift`, `CloudSyncSession.swift`,
  `CloudModels.swift`, `CloudCredentials.swift`, `CloudAICredentialBridge.swift`,
  `CloudLegacyModels.swift`, `CloudLegacySettingsArchive.swift`, `CloudLegacyRules.swift`.

Core tests (`swift/ExteralessCore/Tests/ExteralessCoreTests/`):

- New: `CloudReviewRemediationTests.swift`, `CloudWriteAdmissionTests.swift`.
- Updated: `CloudRemoteTests.swift`, `CloudLegacyImportTests.swift`.

Native Cloud UI (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Cloud/`):

- `ExteralessCloudArchiveHost.swift`, `ExteralessCloudUI.swift`,
  `ExteralessCloudController.swift`, `ExteralessClientAPIController.swift`.

Handoff: `docs/wave-2/cloud-review-remediation.md`.

## Validation / freeze

**FROZEN review-remediation snapshot**, separate from the CI-retry slice:

- `C:\Users\sasha\AppData\Local\Temp\opencode\cloud-ca01-ca03-ca05-ca06-chat.patch`
- `C:\Users\sasha\AppData\Local\Temp\opencode\cloud-ca01-ca03-ca05-ca06-chat.manifest.json`

The manifest pins the written files and the prior CI-retry patch hash. Core hunks
are relative to `f99909b5` plus that frozen CI-retry slice. Native files absent from
that Git base appear as full source additions and belong in the coordinator's
native integration snapshot. This is a source freeze, **not a green build/test or
visual acceptance label**. Do not stage unrelated live work from the shared tree.

Historical slice validation: source checks covered UTF-8/whitespace, balanced delimiters, source ID/type joins,
Core/UI import boundaries and the continued hash of the separate CI-retry artifact.
That frozen Core suite had **72 authored Cloud/API test methods**: the historical
51, five CI-retry regressions, and sixteen review/Chat regressions. Counts do not
promote native/visual acceptance. The coordinator subsequently reported those 72
methods passing at `93a1badc`; the CAF delta above needs its own check. Local
Swift/Xcode remains unavailable.

Coordinator checks: bounded Core `Cloud|ClientAPI` run (30 s after build), the real
native host/admission queue fixtures, then recorded light/dark/large-type/RTL frames
for preview counts, cancellation, retirement, repair and CF destination display.
CA-02/Tools and CA-04/engine-log checks remain with their assigned owners.
