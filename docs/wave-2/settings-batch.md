# Atomic public settings batches — stable handoff

```swift
public func applyPublic(
    _ values: [String: ClientSettingValue],
    resetting: Set<String> = [],
    expected: ClientSettingsSnapshot? = nil
) throws
```

- Affected keys = `values.keys ∪ resetting`. Overlap throws
  `ClientSettingsError.conflictingChanges`; empty batches do nothing.
- Every affected key must be registered/public and every new value must validate.
  Live schema, persisted **and learned** secret classifications override an older
  snapshot: `secretAccessDenied`, including for resets. No Keychain read, write or
  migration occurs on this path; its last native credential cache is retained.
- With `expected`, affected effective values **and** stored-override presence are
  compared against the current file under `flock`. A mismatch or missing expected
  value throws `ClientSettingsError.concurrentModification`. Unaffected values,
  snapshot errors and label changes do not cause a CAS conflict.
- JSON-equivalent integral doubles/integers compare correctly, including nested
  values, without rounding Int64 or treating booleans as integers. This is a
  value/presence CAS, not a revision token: same-state/ABA edits are not detected.
- One validation phase, at most one atomic file replacement, one cache publication
  under writer/file locks. Observer invalidation is delivered once for a changed
  generation, outside both locks. Getters stay on the existing short cache lock.
- Unrelated/unknown values and envelope metadata survive. Format stays version 1.
  Known plaintext credentials must finish native migration first; a public batch
  will not copy them. Corrupt/unsupported files remain protected as before.
- Reset removes the override; the default stays in memory. A post-rename error can
  mean the **entire** batch committed; the published cache reflects that state.
  Validation/pre-commit failures never publish a partial patch. Error recovery may
  refresh external public changes and error status, without touching Keychain.

## Tools binding and rollback

`ToolsBackupSettingsSnapshot` must retain `storedKeys`, and the access/journal
must carry `resetting` and `expected`. Its current `previousSettings`-only journal
and dictionary-only `applyAtomically` closure cannot preserve absent overrides.
Those Tools changes remain with its owner.

Snapshot construction is now public for reconstructing journal/CAS states:

```swift
public init(definitions: [ClientSettingDefinition],
            values: [String: ClientSettingValue], storedKeys: Set<String>,
            secretKeys: Set<String> = [], lastError: ClientSettingsError? = nil)
// Known secret values are redacted by construction.
```

For a restore that sets public `patch` values, prepare both guards **before** the
attempt. Validate/normalize the patch with the captured definitions first:

```swift
let before = settings.readSnapshot()
let definitions = Dictionary(uniqueKeysWithValues: before.definitions.map { ($0.key, $0) })
var normalized: [String: ClientSettingValue] = [:]
for (key, value) in patch {
    guard let definition = definitions[key], !before.secretKeys.contains(key) else {
        throw ClientSettingsError.secretAccessDenied
    }
    normalized[key] = try definition.validatedValue(value)
}
let affected = Set(normalized.keys)
let expectedApplied = ClientSettingsSnapshot(
    definitions: before.definitions,
    values: before.values.merging(normalized) { _, new in new },
    storedKeys: before.storedKeys.union(affected), secretKeys: before.secretKeys
)
let previousOverrides = before.values.filter { affected.contains($0.key) && before.storedKeys.contains($0.key) }
let previouslyAbsent = affected.subtracting(before.storedKeys)

// Journal before + expectedApplied + presence information before the attempt.
try settings.applyPublic(normalized, expected: before)
// If a later directory/journal step fails:
try settings.applyPublic(previousOverrides, resetting: previouslyAbsent, expected: expectedApplied)
```

Do not obtain `expectedApplied` by reading after the attempt: an observer or native
writer can already have changed an affected key. A rollback conflict preserves
that edit and keeps the journal for recovery. If the forward write never committed,
the same rollback patch with `expected: before` can safely confirm the already-old
state; if neither whole affected state matches, retain recovery state. Never retry
rollback with `expected: nil`. For an intended patch that itself resets keys, its
expected result has those keys absent from `storedKeys`, with the applicable schema
defaults in `values`; schema/default changes can require recovery reconciliation.

This is atomicity for the single client-settings file only. Tools continues to own
directory staging, leases and the durable cross-file recovery journal.

## Verification

Baseline `496d426` / CI `43645893132` was reported green by coordinator (the prior
15 Core tests plus Host/Hooks). This batch patch is not covered by that run.
13 new bounded fixtures (28 Core methods total) cover batch/reset atomicity, rejected patches, public/secret
boundaries, absent-vs-stored rollback, independent writers/CAS, unrelated updates,
one post-commit notification/re-entry, and a real rename followed by injected
directory-sync failure. Scoped `git diff --check` and UTF-8/whitespace/delimiter/
Core-import checks passed. `Get-Command swift, swiftc` found no local toolchain;
the new Swift fixtures have not been executed. After its build, coordinator can run:

```sh
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--package-path", "swift/ExteralessCore", "--skip-build", "--filter", "ClientSettingsTests"], check=True, timeout=30)'
```

No CI was dispatched by this subagent.
