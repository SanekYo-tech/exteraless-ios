# Tools TB-01–07 remediation

## Follow-up TBF-01–04 — source patch supplied, execution pending

The independent `reviews/tools-backup-followup.md` remains read-only. TBF-01–04
have source fixes and regression fixtures below; TBF-05 cold-runtime continuation belongs to Host/coordinator,
and TBF-06 native fixture ordering belongs to UI. The coordinator-reported
`6f718b11` run compiled production Core but failed a URLProtocol fixture Sendable
capture. Its current immutable `ToolsReleaseLateDelivery` fix is preserved.

The current journal revision is **v4**: it adds created/displaced scratch-directory
identities and per-file ownership versions for cleanup, not a client-write witness.
TB-01 conservative restart, CA admitted projection/managed-key exclusions and
HNS dynamic default-deny remain unchanged. Older journals cannot invent cleanup
ownership from a UUID filename. Unowned/replaced entries are retained with durable
cleanup-debt evidence. Existing restore/recovery public binding shapes are retained.

Candidate publication is bound to the prepared original/target manifests and
the same checked descriptors before/after exchange. Updater publication retains its
verified output descriptor/version through exclusive rename. Legacy favorite/cloud
wrappers use a fully throwing typed wire reader; grammar validity alone does
not authorize generic Postbox construction.

Coordinator has applied the four common mode consumers/definitions described in
`tools-mode-hunks.patch`; those source hunks are now historical, not work to reapply.

Status: **TB-01–06 source fixes and regression fixtures implemented**. Swift/native
execution is pending; the local evidence is source hygiene. The independent report
`reviews/tools-backup.md` is retained unchanged. Source/runtime evidence will be
appended per finding; no CI, commits or real-account fixtures are part of this work.

## Early contract for Cloud / coordinator / UI composition

### CA-01/02 admitted projection API (current source contract)

```swift
ToolsBackupInspection.admittedKeys: Set<String>
ToolsBackupInspection.admittedPayload(includePluginSettings: Bool = true) throws -> ToolsBackupPayload
ToolsBackupArchive.revalidate(_ inspection: ToolsBackupInspection,
    definitions: [ClientSettingDefinition], secretKeys: Set<String> = []) throws -> ToolsBackupInspection
ToolsBackupPolicy.isPortableClientKey(_ canonicalKey: String) -> Bool
```

`settings` plus `resetting` from the **confirmed inspection** are the hard admitted
write set. Projection uses those values and preserves the setter/reset distinction;
the raw original payload is not an authority. Revalidation may remove newly forbidden
or unavailable keys, or reject invalid/secret values, but cannot add newly registered
keys, excluded IDs, or new default resets. The restorer uses this API directly.
Cloud may call `publicInspection.admittedPayload()` for its host handoff; retain
credential metadata in Cloud's separate plan/envelope. Tools' include-plugins switch
also projects the admitted client set before reinspection.

General backup export/inspection/projection/forward writes exclude the entire
`clientAPI.*` namespace (including test identity and pins) and `cloud.includeApiKeys`.
Low-level new archive encoding rejects those keys; old input archives report them
ignored and do not admit writes or resets. Legacy conversions check the **resolved
canonical destination**, so aliases cannot bypass the restriction. `cloud.autoSync`
can remain portable; the local include-keys permission is never imported/reset.
No general-backup path reads or edits a Keychain tuple. Raw inspection payloads may
retain untrusted input for reporting/Cloud rejection checks; only admitted projection
can reach restore. Old reports `reviews/cloud-api.md` and other reviews remain intact.

The Tools screen runner now also checks generation/context/cancellation **before**
entering a queued operation. Retired queued recovery/restore actions cannot enter
their service merely because the old completion would later be hidden. Already
admitted noncancellable filesystem/Host work retains its existing cleanup lifetime;
the separate Cloud runner's CA-06 fix stays with its owner.

**Journals v3/v4 are diagnostic state, not atomic client-write witnesses.** Live restore
keeps separate, in-memory client and directory-write dispositions. Only a confirmed
write in that invocation authorizes one automatic CAS rollback. A pending/uncertain
write never acquires authorship from equality with the target. A rollback already
attempted is not retried as a new target-authorized write.

On restart, nonterminal v1–v4 recovery performs no target-to-before writes.
Readonly confirmation that all affected state is already before may finish cleanup;
otherwise the journal/originals remain and recovery throws **ToolsError.rollbackFailed**.
Cloud's existing mapping to **needsRecovery** therefore remains required. Successful
restore result and the existing three Host-lease outcomes retain their shapes.

`ToolsBackupSettingsAccess.readCurrent` is an optional **fresh, readonly** observer
for already-before confirmation. The current Core `readSnapshot()` is cached and
`reload()` can migrate/write; neither is silently treated as that proof. The standard
Core adapter therefore conservatively holds nonterminal client journals. Explicit
keep-current reconciliation labels cached observations and performs no live writes,
so it remains available without a new foreign Core API. A future readonly Core
`readPublicSnapshotFromDisk()` would also need no mkdir, migration or Keychain I/O.

New explicit recovery API (Tools-owned, being implemented):

```swift
ToolsBackupRestorer.inspectRecovery(settings:plugins:) -> ToolsBackupRecoveryInspection?
ToolsBackupRestorer.reconcileKeepingCurrent(_:settings:plugins:) -> ToolsBackupReconciliationResult
```

Inspection is data-only. The review token contains the transaction/journal hash,
the public observation (explicitly fresh or cached) and current plugin manifests.
Reconciliation must run under the actual
Host maintenance lease and rejects a changed review. It keeps live client/plugin
state, durably archives recovery evidence/originals and releases the active journal.
The Tools recovery screen will expose this explicit choice; it does not silently
reinterpret an ambiguous recovery as a successful rollback. Success commits the
reconciliation decision (`finish(.committed)`); a failed reconciliation retains
`needsRecovery`. Freeze/export/startup path resolution must use the coordinator's
non-creating `PluginServiceStorage.settingsDirectoryURL()` contract (TB-07).

### Indistinguishable histories (TB-01)

1. Before=false/absent; Tools saves pending/uncertain; native writes true/stored;
   crash occurs before forward CAS.
2. Same before and pending journal; Tools writes true/stored; crash occurs before
   its acknowledgement is journaled.

Journal bytes and live value/presence are identical. Hashes, another read and a CAS
against true cannot distinguish them. Likewise, after a completed rollback whose
terminal marker is lost, a native writer can restore the old target. A saved
"applied" field alone does not prove the currently observed target still belongs
to an unrolled-back Tools operation. Conservative hold is intentional.

For future automatic restart rollback, the coordinator would need an **atomic**
Core transaction API, not a Tools-side metadata file:

```swift
applyPublic(_:resetting:expected:transactionId:) throws -> ClientSettingsWriteReceipt
readPublicTransaction(transactionId:) throws -> ClientSettingsTransactionState
rollbackPublic(_:resetting:expectedReceipt:rollbackId:) throws -> ClientSettingsWriteReceipt
```

The receipt/revision and transaction outcome must be stored in the same atomic
client document/commit as values and presence, survive post-rename errors, reject
later revisions including equal-value writes, and record rollback's own identity.
Tools does not implement or assume this foreign CoreSettings API in this patch.

### Directory ownership (TB-02)

The live states are `notStarted`, `swapAttempted`, `confirmed`. Confirmation requires
the successful swap and the staged directory identity, not just target JSON hashes.
A pre-swap manifest conflict retains native files and recovery evidence. Restart
cannot infer directory authorship from the recorded hashes; it uses the same hold /
explicit keep-current reconciliation policy.

## Implemented changes and regressions

### TB-01 — client authorship and repeat rollback

- `ToolsBackupRestore.swift` now writes diagnostic journal **v4**, retaining v1/v2/v3 readers.
  Config archive version **2** is unchanged. Actual invocation-local `ClientWrite`
  is separate from the journal's pre-call `uncertain` marker.
- The live rollback path accepts only `.applied`, performs at most one target CAS,
  and records `rollingBack` before attempting rollback. `uncertain` never authorizes
  a rollback. Rejected/not-attempted forward calls leave native client edits alone.
- A rejected rollback CAS can only be followed by optional fresh readonly
  already-before confirmation. It never calls a second setter with before as its
  expected image. Restart performs **no** nonterminal target-to-before mutation.
- `ToolsBackupRecovery.swift` supplies the review/result types. `inspectRecovery`
  redacts fields no longer public. `reconcileKeepingCurrent` checks the review,
  publishes the original journal under a no-replace evidence filename, writes a
  durable `reconciled` marker, and retires only the active journal. Original/staged
  plugin directories remain retained. Terminal cleanup can be retried.
- `ExteralessBackupController` has real **Review recovery… / Keep current
  configuration…** actions and async service calls. Reconciliation obtains the same
  actual Host lease as restore; any failure finishes `needsRecovery`, success commits
  the keep-current decision. No live client/plugin setters are called by that API.
- Existing successful in-call presence/CAS rollback controls retain their expected
  restored values. The old test that falsely inferred ownership from pending+target
  was replaced by a readonly already-before control and real-Core counterexamples.

Regressions: `ToolsRecoveryRegressionTests` covers independent native target before
any forward call (zero writes), actual Core post-rename error, native target after
a completed rollback/before its terminal marker, zero-setter before confirmation,
changed review rejection, retained evidence and a subsequent successful restore.
`ToolsBackupTests` also exercises explicit reconciliation after a durability failure.

**Composition requirement:** keep the backup bindings accessible while startup is
blocked on recovery, with a real maintenance retry / proven no-Host boundary. After
reconciliation, the ordinary runtime startup retry can proceed because the active
journal is retired. Tools does not bypass quiescence with `!isRunning`, or start
Python from its inspector. This remains the existing Runtime/UI owner's composition.

### TB-02 — plugin swap receipt

- `notStarted / swapAttempted / confirmed` are tracked in the invocation. The
  diagnostic journal records the attempted phase before the syscall.
- Darwin replacement uses fd-relative **RENAME_SWAP**. A receipt requires success,
  the staged directory inode at live, the old live inode at stage, unchanged staged
  file versions and parent synchronization. File versions include device/inode,
  type, size, mtime and ctime. Rollback validates this receipt again before a swap.
- A changed pre-swap native manifest, including the exact staged target, retains
  live files and originals and returns `rollbackFailed → needsRecovery`. There is
  no hash-equality path that promotes `notStarted` into ownership.
- A current original image is readonly confirmation, not a replacement operation.
  Restart's diagnostic `confirmed` field is not reused as a durable ownership receipt.

Regression: Darwin `testTB02PreSwapNativeExactTargetAndThirdImagesNeverBelongToTools`
uses two tiny JSON files, `.afterPrepared`, exact-target and third-state writers,
zero client writes, retained native/original bytes and the needsRecovery error.
The prior confirmed-swap rollback and successful credential-preserving merge tests
remain in `ToolsBackupTests`.

### TB-03 — cached favorite data

- `ToolsPostboxPreflight.swift` checks the actual key/type grammar, signed lengths,
  nested boundaries, counts and work/depth budgets **before** the throwing typed
  `ToolsFavoritePostboxReader.swift` reader.
  No registered Postbox object is instantiated by the preflight.
- `ToolsFavoriteStickerStorage.swift` stores bounded, versioned raw JSON directly
  through `PreferencesEntry(data:)`. Existing v1 local preferences use the checked
  preflight and typed legacy reader, then migrate on the next successful mutation.
  The 11-byte negative object length fails before DTO construction. This boundary
  no longer calls `PreferencesEntry.get` / `CodableEntry.get` at all (TBF-02).
- The actual cloud ordered-list data also goes through preflight. A small typed
  wrapper extracts `fd/sr`; **throwing `getCheckedRoot` with bounded verifier options**
  validates the real FlatBuffer. A fixed sticker DTO projection reads validated
  schema fields without `SavedStickerItem`'s unchecked getRoot/_parse or debug traps.
- Malformed cloud data fails the signal visibly; it is not counted as a successful
  empty list and nothing is written back. Legacy cloud `f`/opaque Postbox media
  blobs are explicitly refused as unverified and retained, rather than invoking
  their generic registered-object decoder. This is a precise cache-format limit;
  current native `fd` data and the prior local v1 preference are supported.

Regressions: `ToolsCachedFavoriteTests` includes the review's exact 11 bytes,
truncated nested data, tiny huge-count declarations and account/version isolation.
`telegram-ios/Tests/Exteraless/ToolsFavoriteStorageNativeTests.swift` uses the real
native preference/CodableEntry encoders and production decoder, valid old-local/new
raw records, a real SavedStickerItem and a malformed FlatBuffer. Native tests are
supplied, not executed here; no Account/Postbox database is opened by those fixtures.

### TB-04 — bound descriptors and publication

- `ToolsFileDescriptors.swift` pins every directory ancestor; `openat` with
  O_NOFOLLOW/O_CLOEXEC and `fstatat/fstat` bind leaves to checked identities and
  versions. Reads compare metadata before/after and verify the ancestor chain.
  Only fixed Darwin `/var`, `/tmp`, `/etc` aliases are translated lexically;
  caller-controlled symlink ancestors are never resolved into a new authority.
- Backup export/copy and `ToolsFileSafety.read` use this boundary. Private journal
  writes also use owned descriptors. New restore directories are created via pinned
  parents with synchronization, under the lease.
- Files copy uses 64-KiB bounded reads, checks source metadata again after copy and
  before publication, and creates O_EXCL private output. Darwin RENAME_EXCL and
  Glibc linkat provide **no-replace** publication. Collisions choose the next name;
  rejected ancestor changes clean only the operation's inode through the held fd.
- `ExteralessFileSaving` now coordinates the actual security-scoped destination
  (`NSFileCoordinator`, `.forMerging`) and propagates provider errors. Unsupported
  exclusive-publication filesystems return an error. Other non-POSIX platforms
  report descriptor access unavailable instead of silently using the old unsafe path.

Regressions: `ToolsFileRaceTests` has leaf replacement during export, source ancestor
replacement during read/copy, source modification after read, racing destination
creation, and destination ancestor replacement with retained foreign data/no partial.
All use tiny, self-owned temporary files and synchronous barriers.

### TB-05 — cancellation owner

- `ToolsReleaseTransfer` has one serial delegate/cleanup owner. Cancellation closes
  admission and queues terminal cleanup on that queue; it resumes the continuation
  **after** the current callback drains, the owned fd closes and the partial unlinks.
- Response/data/redirect callbacks reject cancelled/finished operations. I/O and
  progress admission share the cancellation lock; a progress callback may safely
  cancel its own task. No queued callback reopens the file after terminal cleanup.
- The partial is O_EXCL and fd-owned; unlink uses the pinned parent/inode. A cleanup
  error is reported, and final completion/invalidation retries retained cleanup
  ownership. Outer folder cleanup happens after the transfer has drained and uses
  the same held directory/file versions (TBF-04), never recursive path removal.
- The coordinator's `contentHash` compiler fix is preserved.

Regressions in `ToolsReleaseTests`: real URLProtocol responses with queued chunks,
a cancellation barrier at accepted headers, cancellation after an actual first
write, and Darwin late provider headers/chunks after stopLoading. They assert empty
output directories and no late progress; waits are two seconds each, no live HTTP.

### TB-06 — aggregate budgets before materialization

- `ToolsBoundedJSON.swift` checks space before each append/escape/value, with bounded
  traversal. Payload/envelope output never grows beyond the configured budget.
- Export streams one plugin entry at a time. Both raw input bytes and encoded
  aggregate bytes have running limits; the next fd's size is checked against the
  remaining budget **before** read/JSON materialization. There is no accumulated
  `[all plugin files]` export object.
- Programmatic payload encoding uses the same bounded writer and per-file budget.
  Base64's exact size is checked before allocating it. Favorite preference/archive
  encoders also append bounded DTOs with a pre-encoding upper bound.
- `ToolsBackupLimits` accepts smaller fixture caps only; it cannot raise production
  limits.

Regressions: `ToolsArchiveBudgetTests` derives a tiny two-file cap from a valid
control export, adds six more tiny files and asserts exactly two admitted reads.
It also checks escaped-string growth and oversized programmatic payload rejection.
No large/OOM allocation is attempted.

### TB-07 — coordinator-applied dependency

Read-only source check confirms `PluginServiceStorage.settingsDirectoryURL()` and
Runtime startup/liveSettingsLocation callers now use it; freeze obtains that same
live getter. Creating `settingsDirectory()` remains for ordinary native SDK writes.
The current test name is
`PluginServiceStorageTests.testBackupLocationResolutionDoesNotCreateStorageBeforeItsLease`
(the coordinator's absent-base-after-read fixture). It is supplied, **pending CI**.
The reported `75cbe7a1` CoreSettings/AI run has no result received here and is not
verification of this Tools working-tree patch.

## Finding status

| ID | Status |
|---|---|
| TB-01 | Source implemented; real-Core regressions supplied, execution pending |
| TB-02 | Source implemented; Darwin regressions supplied, execution pending |
| TB-03 | Source implemented; portable/native decoder regressions supplied, execution pending |
| TB-04 | Source implemented; bounded file-race regressions supplied, execution pending |
| TB-05 | Source implemented; URLProtocol cancellation regressions supplied, execution pending |
| TB-06 | Source implemented; small-cap/visit-counter regressions supplied, execution pending |
| TB-07 | Applied by coordinator; readonly-getter test pending CI |
| HNS-01 | Core evidence/validity and post-drain checks applied; default-deny arbitrary dynamic schemas; Runtime/UI joined patch and execution pending |
| CA-01 | Admitted projection applied at actual Tools restore/UI boundary; real-Core excluded-key/new-definition fixtures supplied |
| CA-02 | General backup native-managed exclusion applied to export/encode/inspect/projection/legacy aliases; tuple/permission fixtures supplied |

## Later P1 remediation — HNS-01 and CA-01/02

HNS-01's exact public types and issuer requirements are in
`tools-schema-evidence-contract.md`. The current SDK's arbitrary create_settings
does **not** acquire an immutable guarantee from an epoch, JSON annotation or equal
past results. Optional old calls remain source-compatible but grant no plugin
permission. The native validity protocol pins source/owner/account/revision at
actual I/O; Core checks source SHA and the exact settings snapshot, including the
post-drain stage and again before the plugin-directory swap. Cache replacement also
revokes captured locations. In-call rollback/restart policies from TB-01/02 are retained.

CA-01's `admittedPayload` projection preserves the preview's setter/reset/presence
decisions. `revalidate` consumes only that projection; newly registered definitions
and Cloud-excluded bot routing IDs cannot re-enter. Tools UI's include-plugin switch
uses the same projection, closing an earlier reinspection route before the restorer.
Returned counts describe the actual tightened admitted set.

CA-02's policy is applied to canonical destinations, including legacy conversion
rules. Source export omits `clientAPI.*` and `cloud.includeApiKeys`; new low-level
encoding rejects them. Older archives can report them ignored, but neither setters
nor resets are admitted. Public autoSync remains portable while the local key-export
permission, API mode/ID/hash and pins stay unchanged.

`ToolsAdmittedProjectionTests` uses the real Core store/restorer: Cloud's actual
portable filter, an excluded bot ID changed by an independent writer, a newly
registered explicit-default key, both old archive versions and reset presence,
two fake credential backends containing different API hashes/pins, zero general
backup secret reads/writes, the actual CloudCredentials opt-out export, and an alias
whose canonical destination is forbidden. No account or transport is instantiated.

`tools-owner-completion.md` and `tools-parity.json` separately account for the 14
additional Tools IDs and ChatSwipeAction. Applied automatic-fetch/upload/facing and
migration consumers are distinguished from coordinator-owned mode/gesture hunks;
none is promoted to verified without execution.

## Build / evidence boundary

New Core `Tools*.swift` files use the existing Foundation/Core source glob; POSIX
glue is guarded for Darwin/Glibc. The native favorites helper adds imports of the
existing TelegramCore FlatBuffers/FlatSerialization dependencies. The build owner's
current `//Tests/Exteraless:StickerEmojiRenderingTests` source list includes
`ToolsFavoriteStorageNativeTests.swift`; native execution is still pending.
No BUILD, CoreSettings, Pill, Root or shared Gallery source was
edited for remediation.

Local Swift/swiftc are absent on Windows. Supplied XCTest methods are **not reported
passed**. Final bounded source, formatting, Postbox and parity checks are recorded
with the concluding owner handoff. Native recovery-screen frames, Files-provider
behavior and Darwin swaps/cancellation still require the Apple runner and recorded
frame acceptance under `telegram-ios/AGENTS.md`.

### Pre-follow-up local source checks (historical)

- Bounded source sanity: **73 Swift files, 19 live registered Tools keys**, pass.
  This is delimiter/string/comment/consumer hygiene, not Swift typechecking.
- Official `python -B build-system/Make/PostboxImportCheck.py`: **exit 0**.
- Targeted `git diff --check` plus owned-file newline/NUL/whitespace checks: **pass**.
- Read-only parity merge/path-range validation: **43 feature receipts, 9 modules,
  171 references, zero conflicting feature overrides, zero added verified claims**.
- Coordinator mode patch: in-memory context/delimiter dry run passed for **5 files**;
  the dry run wrote no shared file and is not an Apple compilation result.
- **84 Core Tools XCTest methods and 3 native cache-boundary methods supplied**.
  None was run locally: swift/swiftc and Apple SDK are unavailable in this session.
  Async fixture waits are bounded to two seconds; I/O fixtures use tiny owned files.

No commit, push, CI dispatch, external plugin execution, live HTTP, send or actual
account mutation was performed. Remaining joined/native work is explicit in
`tools-schema-evidence-contract.md`, `tools-mode-hunks.patch` and
`tools-owner-completion.md`; it is not relabelled as verified completion.

## TBF-01–04 implementation and handoff (2026-11-15)

### TBF-01 — expected replacement images

`ToolsBackupRestore.swift` and the new `ToolsFileOwnership.swift` bind each
`RENAME_SWAP` to **both expected manifests**: the prepared original and target on
forward publication; the confirmed live target and prepared original on rollback.
`ToolsDirectoryImage` retains the file/directory descriptors that supplied its
checked bytes. It checks the exact filenames, directory identity, file versions
and SHA-256 before and after exchange, including a final binding/version pass.
The expected target hashes are derived from the checked original plus the admitted
merge, rather than from a fresh, potentially changed stage directory.

Rollback validates and retains its original backup image before the client CAS,
rechecks that same image after `afterClientRollback`, and copies only those checked
bytes into its owned replacement. Its replacement must match `originalFiles` before
publication. A mismatch returns `rollbackFailed`, retains `needsRecovery` evidence
and does not run terminal cleanup or report `rolledBack`.

Darwin fixtures in `ToolsBackupFollowupTests.swift` use one small `fixture.json`
with `style` and a local-only token, the real Core client store, and the existing
fault points. Both in-place and atomic replacements are covered:

- `testTBF01ChangedPreparedStageCannotBecomeLive`
- `testTBF01ChangedBackupAfterClientRollbackCannotBecomeRestoredOriginal`
- `testTBF01ConfirmedPreparedImagesStillCommitAndRollBackCleanly`

The original credential-preserving success and confirmed-swap rollback controls in
`ToolsBackupTests.swift` remain supplied. Darwin execution has not been performed.

### TBF-02 — fully throwing wrapper decoding

The native cache boundary now calls:

```swift
ToolsFavoriteStickerStorage.decodeLegacyPostbox(_:userId:) throws -> [ToolsFavoriteSticker]
ToolsFavoriteStickerStorage.decodeCloudPostbox(_:) throws -> ToolsCloudFavoriteWire
```

`ToolsFavoritePostboxReader.swift` checks each expected scalar/object/array shape
and bounds before constructing the data-only DTO. It performs no registered type
lookup or generic Postbox decode. `stickers` requires object-array wire data;
`aliases`/`sr` require string-array data; `fd` requires bytes. The real encoder's
`Int32Array(count: 0)` representation is accepted for empty arrays. Unknown keys,
duplicate keys, wrong typed fields and opaque legacy cloud `f` data throw while
the original entry bytes remain intact. Current cloud `fd` still goes through the
native throwing FlatBuffer verifier after wrapper decoding.

Three added `ToolsCachedFavoriteTests` methods exercise tiny valid-wire/wrong-type
fixtures and positive typed controls without linking Postbox. Three added
`ToolsFavoriteStorageNativeTests` methods use **real engine encoders**, the actual
production boundary, object-vs-array and primitive-array counterexamples, intact
source bytes and valid v1→raw-v2 migration, including empty arrays. The native
legacy fixture writes its version as `Int32`, matching release v1 bytes and avoiding
the old encoder's deliberate debug assertion in `encode(Int)`.

### TBF-03 — scratch cleanup authority

Journal **v4** records `ToolsDirectoryOwnership`: created/displaced directory inode
and per-file versions (device/inode/kind/size/mtime/ctime). These are cleanup
receipts, not evidence authorizing restarted client or plugin rollback.
`ToolsOwnedDirectory` retains its descriptors in the live operation. Cleanup unlinks
only recorded file versions relative to the held directory, synchronizes it, and
removes only the matching empty directory. It does not recursively traverse a
foreign replacement or acquire scratch ownership from a UUID-shaped name.

Confirmed forward/rollback exchanges update the displaced-side receipts. A
client-only transaction records no scratch ownership. On terminal recovery, v4
can reopen only identities already recorded in its journal; v1/v2/v3 plugin journals
cannot invent such receipts. Foreign/replaced/unknown entries remain, with the
terminal journal archived as `tools-settings-cleanup-debt-<UUID>.json` before the
active journal is retired. A failed debt publication retains the active evidence.
Preparation-only cleanup also archives any retained ownership debt. Debt archives
do not schedule another rollback or an unowned recursive deletion.

Additional `ToolsBackupFollowupTests` cover:

- Client-only `afterPrepared` foreign directories at **both** scratch names.
- v1/v2/v3 terminal journals without cleanup receipts.
- `beforeCommitMarker` replacement of **both** scratch directories, preserved
  foreign bytes, removal of owned entries through renamed held directories, and
  replay of the terminal journal with the same retained debt.
- Unknown entries and replacements of a recorded filename inside an owned scratch
  directory. Both must survive cleanup.

### TBF-04 — verified update capability through publication

`ToolsReleaseClient.swift` transfers a `ToolsVerifiedFileReceipt` to the caller:
the retained output fd, pinned parent/directory, exact file version, count and
SHA-256. Closing the delegate's write handle no longer discards this capability.
Final publication rechecks the same bytes/version and uses Darwin `RENAME_EXCL` or
Glibc `linkat`, then verifies the published inode/bytes through the held descriptor.
The Glibc original link is removed only against its checked post-link version.
Changes to `ctime` from the operation's own rename/link/unlink are accepted only
alongside matching identity/content versions and checked bytes.

After publication begins, verification drains before task cancellation is observed,
so a cancelled caller can clean its confirmed owned output. Delegate admission,
serialized close/unlink, progress cancellation and late-callback rejection remain
in force. Outer cleanup uses the held ownership receipt, preserving foreign files
or replacement directories. Hashing remains streamed in at most 64-KiB chunks.

Four added `ToolsReleaseTests` methods use six-byte offline URLProtocol fixtures:

- A→B replacement at `afterCleanup`, both atomic and in-place: no ready result,
  no accepted digest for B, and B retained.
- Replacement of the output folder at successful handoff and before error cleanup:
  foreign files retained; the moved owned partial is cleaned.
- A ready-name collision: foreign ready file retained; own partial removed.
- Cancellation at success handoff: owned output removed before the caller returns.

New async fixture helpers enforce a three-second completion wait, with two-second
hook assertions; each fixture remains below the 30-second limit. Existing positive
download, checksum-failure and cancellation controls remain supplied.

### Follow-up evidence and remaining acceptance

- Source sanity: **76 Swift files / 19 ToolsFeatures key-consumer checks**, pass.
- Official Postbox boundary checker: **exit 0**. Scoped `git diff --check`: **pass**.
- **14 new Core XCTest methods** (7 backup/cleanup, 3 typed-wire, 4 updater) and
  **3 new native methods** supplied; totals are **98 Core / 6 native** Tools methods.
  These counts are inventory, not executed passes.
- Core's source glob includes the two new implementation files. The current native
  BUILD already lists the favorite-storage test file under
  `//Tests/Exteraless:StickerEmojiRenderingTests`; that list was read, not edited.
- The coordinator's immutable late-delivery/protocol helper suffix is unchanged:
  normalized-text SHA-256
  `3f6768483b64ea88b0e928249e97bbd69aff7e474c605944e56444de81b401eb`.
  Its `contentHash` production fix is also retained.
- `reviews/tools-backup.md` retains the independently recorded SHA-256
  `556bab814c3a01d20ebe42f20813620f8e72ff29abf31f53447ade3b3fe548ef`.
  The follow-up report is preserved at
  `94bb8c897dd0b0b7b8934a78f255c75992a4307c41e4213b42678bd080cf877e`.

Local Swift/swiftc and Apple-native execution remain unavailable. The reported
`6f718b11` production-Core compile predates this patch; its failed test closure and
the subsequent coordinator fix are not a pass for these regressions. Authorized
Core/XCTest and Darwin/native runs, including the original positive controls, are
still required. TBF-05/06 acceptance stays with Host/coordinator and UI respectively.
The four common-mode consumers/definitions are coordinator-applied, as reported;
their historical hunk file should not be applied again. No verification status was
promoted, and this agent made no commit, push, CI dispatch or live-account/network
test operation for the follow-up.
