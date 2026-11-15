# Settings remediation handoff

Baseline: `4b3f7064`, prior CI `43653040458` reported green by coordinator.
The review report `reviews/settings-core.md` is unchanged. The fixes below are
new source, not covered by that run. No CI/commit/push was performed here.

## Coordinator bindings

**SC07 requires a stable directory boundary**, not an existence heuristic. Use
the existing OS-provisioned app-group container already resolved by composition:

```swift
try ClientSettings.shared.configure(
    storageURL: existingBaseURL.appendingPathComponent("exteraless", isDirectory: true)
        .appendingPathComponent("client-settings.json"),
    durabilityRootURL: existingAppGroupContainerURL
)
```

The root must already be durably provisioned and contain the file. A newly created
account/base subdirectory belongs below this root, not in place of it. Core syncs
every descendant directory link on every filesystem operation, under the file
lock, independently of which process created it. Defaults use OS-provided home
or temporary-directory roots; an app-group/custom path outside them needs the
explicit existing root. This avoids opening/syncing ancestors outside its sandbox.
`applyPublic(_:resetting:expected:)` is unchanged.

**SC02 bridge:** `ClientSettingValue.decodeJSON(Data/String)` consumes original
JSON, before NSNumber or any re-encode. `ClientSettingsBridgeExtension` now reads
routing strings only, then parses the entire original owned request with it. It
uses typed values directly for set/fallback/response. Coordinator still owns the
BridgeServices raw-forward change described in the assignment.

**AI04:** exact shape API and sample are in [settings-shape.md](settings-shape.md).
Valid schemas remain registered on stored-value failure, allowing native repair.
Cached values rejected by a newly accepted shape are omitted from snapshots and
exports; the original file is preserved until a valid explicit replacement/reset.

## Fix / regression matrix

| ID | Fix | Regression (`ClientSettingsTests.swift`) | Status |
|---|---|---|---|
| SC01 | Learned source sensitivity, authorized matching retry, persisted `secretAliases`, retired-source exclusion from public views. | `testSC01FailedSecretRenameProtectsSourceAndAllowsNativeRetry` | Source fixed; XCTest pending |
| SC02 | Original-byte numeric codec at file/Keychain/bridge boundaries; unsupported precision rejects; exact integral encoding. | `testSC02StrictRawNumbersAndBridgeRequestValuesNeverRoundIntegers`, `testSC02UnsupportedUnknownValuesAndMetadataPreserveTheEntireFile` | Source fixed; XCTest and native bridge gate pending |
| SC03 | Recursive option equivalence/uniqueness and canonical option values. | `testSC03StructuredAndNullableEnumsUseRecursiveJSONEquivalence` | Source fixed; XCTest pending |
| SC04 | Exact Int64 bounds before floating-point work. | `testSC04IntegerBoundsAreExactAboveDoubleIntegerPrecision` | Source fixed; XCTest pending |
| SC05 | Explicit secret defaults remain overrides; reset alone deletes them. | `testSC05SecretExplicitDefaultsKeepPresenceUntilReset` | Source fixed; XCTest pending |
| SC06 | Equal nonempty mutations confirm file/directory sync, including a new instance retry. | `testSC06IdenticalRetriesConfirmDirectorySyncEvenInANewInstance` | Source fixed; XCTest pending |
| SC07 | Full descendant-chain sync from a stable root on every path, independent of creator/visibility. | `testSC07SecondCreatorPublishesAllAncestorsWhileFirstIsPaused`, `testSC07AncestorSyncFailureCannotBeSkippedOnVisibleDirectoryRetry` | Source fixed; explicit app-group root binding + XCTest pending |
| SC08 | Actual Keychain destination wins before losing-source validation. | `testSC08SecretDestinationWinsBeforeLosingSourceValidation` | Source fixed; XCTest pending |

## Additional bounded repair scope

Cold-start invalid Keychain was genuinely blocked: valid schema registration is
now retained after stored-value failure, so native `set`/`reset` can address the
item. Explicit repair can commit its targeted item while retaining/throwing an
unrelated unreadable-item error; missing credentials are not invented. This does
not make the two persistence backends one transaction. `lastError` remains the
last operation's status, not a global Keychain-health assertion.

Failed alias migration leaves original JSON untouched; its learned sensitivity
is process-local until successful alias metadata commit. Bootstrap must repeat
the declared migration before exposing legacy keys after restart. Retired aliases
remain protected after success, without classifying unrelated keys by their names.

The codec supports signed Int64 integer-valued tokens (including exponent/decimal
spellings). Fractional tokens must equal the decimal round-trip spelling of their
finite Double; excess precision/underflow is explicitly unsupported. String digits
remain strings. This is an honest refusal policy, not arbitrary-precision storage.

## Evidence boundary

Swift is unavailable in this Windows workspace. New XCTest fixtures are supplied
for the real Core: 42 settings methods total, including 10 new SC regressions,
3 shape regressions and 1 cold-start repair regression. `Get-Command swift, swiftc`
confirmed no local compiler. Scoped `git diff --check`, UTF-8/whitespace/delimiter
checks, Core-import boundaries and the bridge's absence of numeric re-encoding
passed with bounded local commands. These checks do not execute Swift.
Actual bridge/app compilation and coordinator's raw-forward integration still need
the next native/CI gate. Apple Keychain access-group/lock-state testing and real
power-loss/filesystem survival are external; ordered real fsync/rename plus fault
hooks establish control-flow coverage, not a hardware power-loss result.

After coordinator's build, bounded settings execution:

```sh
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--package-path", "swift/ExteralessCore", "--skip-build", "--filter", "ClientSettingsTests"], check=True, timeout=30)'
```

## Follow-up SCF01 / SCF02

The independent follow-up closed the original SC01–SC08 source findings and the
actual App Group bindings. Coordinator reports all prior 42 settings tests green
in Core CI `43696986849` on `e59bd30a`. That baseline does not cover the following
new, narrowly scoped recovery changes; the independent reports are not edited.

| ID | Fix | Regression | Status |
|---|---|---|---|
| SCF01 | An explicit secret `migrateKey` retry stages **all pending learned aliases** in one native candidate. Each actual Keychain destination is checked before the losing source; all required secret writes finish before the one JSON cleanup. Completed historical aliases without a remaining source do not require extra domain registrations. | `testSCF01TwoFailedAliasesCompleteTogetherOnNativeRetry`: two failed aliases, restored backend, retries of both, one cleanup rename, subsequent public write, reopen/redaction. | Source fixed; new XCTest execution pending |
| SCF02 | Explicit native secret set/reset can preserve another type/shape-invalid legacy JSON value in its **absent Keychain slot**, omit it from the typed cache, and commit the requested repair while still throwing the remaining validation error. Only the source whose secure copy is durable is scrubbed. | `testSCF02InvalidLegacySecretStringsAllowPerKeyResetThenSet`: `false/false` legacy strings, retained raw `false`, per-key progress/error, reopen and completion. | Source fixed; new XCTest execution pending |
| SCF02 retry | If a raw secure copy succeeded before a later backend/file failure, a subsequent native repair recognizes the matching JSON duplicate and completes cleanup. Different or unreadable raw data is not silently discarded. | `testSCF02ShapeInvalidLegacySecretsKeepRawValuesAcrossFailedRepairRetry`: two shape-invalid objects, B copy succeeds/A write fails, original JSON preserved, native retry progresses, B raw value retained until explicitly reset. | Source fixed; new XCTest execution pending |

Quarantine here means preserving the original **JSON value** under the same
secret-store key, without making it a valid typed setting. There is no new file,
metadata format or public repair entry point. An invalid preserved item continues
to produce an error on native typed read/registration until explicitly repaired.
The public setter/batch guards are not relaxed and never initiate this repair.
This remains ordered Keychain writes followed by atomic JSON replacement, not a
transaction spanning both backends.

Three bounded, temporary-data fixtures were added (45 settings methods total,
including the conditional non-Apple test). Scoped `git diff --check` and
UTF-8/whitespace/delimiter/unique-test checks passed for the three changed files.
`Get-Command swift, swiftc` still found no local toolchain; new Swift/XCTest
execution remains with coordinator. Apple Keychain/device
and power-loss evidence retain the external boundary described above.

## Focused recovery SCR01

Updated evidence from coordinator: **all 45 settings tests passed** in CI
`43700711108`, published commit **`f99909b5`**, in 0.78s. The overall Core run was
red due to the separately owned Cloud preview/CAS test; it does not negate the
settings result and does not cover this new SCR01 working-tree patch. Existing
review reports and prior output names are not modified.

| ID | Fix | Regression | Status |
|---|---|---|---|
| SCR01 presence | Acknowledged quarantine copies and confirmed matching raw duplicates publish `storedKeys = true`, with no typed value. Reads separately record item existence and validation success. | Existing SCF02 tests now assert presence after the first copy, partial backend failure, matching retry and reopen. | Source fixed; new XCTest run pending |
| SCR01 public batch | `resolvePublic` copies the native secret value/presence state exactly, including typed nil, without a default substitution or Keychain I/O. | `testSCR01QuarantinePresenceSurvivesPublicBatchesAndUnreadableBackend` uses raw `false` and `null`, checks unchanged raw bytes/read/write counters, explicit default-equal set, and reset. | Source fixed; new XCTest run pending |
| SCR01 failure recovery | Read-only recovery visits secret items independently. Writer-confined observations preserve acknowledged write/delete presence even if later reads fail; invalid/unreadable typed data stays unavailable. Original operation/durability errors retain precedence. | `testSCR01RecoveryPreservesCommittedPresenceBeforeAndAfterRename` injects the actual pre-rename seam and post-rename error for both raw fixtures, then checks cache, public batch, reopen and reset. | Source fixed; new XCTest run pending |
| SCR01 partial alias | A successful first destination write is not represented as absent when the second write fails and recovery reads become unavailable. | `testSCR01PartialAliasWriteRetainsConfirmedPresenceWhenReadsBecomeUnavailable`, followed by normal cohort completion. | Source fixed; new XCTest run pending |

Presence and availability use the existing API: a known stored-but-invalid secret
is in `storedKeys` while `value(key)` and `readSnapshot().values[key]` are nil.
Confirmed absence supplies the definition default and removes the stored flag.
An unreadable backend supplies no typed default; previous known presence is kept.
If presence has never been observed, typed nil plus no stored flag is **unknown**,
not an assertion that no item exists. Public operations preserve these states.
Raw secret payloads are never put into this cache, snapshots or exports.

Per-key observations are private to one writer operation and cleared before
callbacks run. Successful reset confirms absence; successful default-equal set
confirms presence. A later observed read can supersede an earlier write fact.
The original last-operation `lastError` contract, public permission guards, file
format and `applyPublic` signature remain as before; no public repair API is added.

Three new bounded fixtures bring the source inventory to 48 settings methods.
The `beforeFileReplace` hook is internal test instrumentation after temporary-file
fsync and before the real rename. It distinguishes the requested pre-commit fault
from the existing post-rename hook; neither is a hardware power-loss claim.
Scoped `git diff --check`, UTF-8/whitespace/delimiter and unique-test checks passed.
`Get-Command swift, swiftc` found no local toolchain: the SCR01 patch and its three
new methods have not been executed here. Swift execution and real Apple Keychain
verification remain with coordinator/device testing; the published `f99909b5`
result is evidence for the preceding 45-case source only.
