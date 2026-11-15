# Darwin storage aliases — coherent Core fix cohort

Status: **production path-boundary fix and bounded fixtures supplied; Mac rerun
pending**. No CI dispatch, commit, real-user file mutation, network operation or
native execution was performed here.

## Execution evidence / root cause

Input: coordinator Mac run **43728873627 / 46393e31**, local log
`build/artifacts/python-runtime-43728873627/swift-components/ExteralessCore/test.log`.
Production Core compiled. The log has **663 tests, 42 error records across 35 failed
test methods**. The AI UTF-16 error remains with the coordinator. The filesystem
cohort accounts for **41 error records across 34 methods**, not 41 distinct tests.

The failing root is the actual Foundation temporary URL:
`/var/folders/h5/t85nd63d71x27_8gl5gw3l_w0000gn/T/...`.
The old boundary lexically changed that to `/private/var/...`, then compared it
against whole-path `resolvingSymlinksInPath` / `standardizedFileURL` output. Darwin
Foundation can report another legitimate spelling of that same OS directory.
The Emoji store additionally compared URL values whose directory/spelling form
can change after creation. These comparisons were not inode/symlink proofs.

Observed exits:

- `ToolsBackupArchive.swift:157`: `validateLocation` rejected before export/schema
  work or prepared-journal creation (archive-budget, backup, HNS fixtures).
- `ToolsFileSafety.swift:50`: `checkedChild` rejected valid children (recovery,
  subtitles, terminal cleanup). The restore cleanup wrapper then surfaced
  `rollbackFailed`; missing-journal assertions are consequences of the earlier exit.
- `EmojiPackStore.swift:148`: three domain tests stopped at the URL equality gate.
- `CloudSyncLifecycleTests.swift:176`: reopening/loading the saved metadata surfaced
  `CloudError.localStorage` through the same child-path boundary.
- All five existing `ToolsFileRaceTests` passed in the supplied log. Their retained
  FD/no-replace mechanisms are preserved; passing negative-path tests did not prove
  the positive `/var/folders` path could reach its intended fault point.

## Production change

### One path policy, fixed OS prefix only

`ToolsFileSafety.canonicalFileURL(_:)` now performs **spelling-only** substitution
of the first absolute Darwin component for exactly:

```text
/var -> /private/var
/tmp -> /private/tmp
/etc -> /private/etc
```

It does not call Foundation whole-path standardization/resolution. It is not itself
an authorization API. Caller-controlled `.` / `..` components are rejected before
walking; a component named `var`, `tmp`, or `etc` below the root is not an OS alias.
Local file URLs are required; remote file hosts and NUL paths are rejected.

`ToolsDirectoryDescriptor.walk` opens `/` and walks descendants using
`openat(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`. If the requested first component was
one of the documented aliases, a `ToolsSystemAliasPin` is acquired from that real
filesystem-root descriptor. It requires:

1. An actual symlink at the fixed root alias, with a retained metadata version.
2. An exact target string `private/<name>` or `/private/<name>`.
3. A separately opened no-follow `/private/<name>` target and held ancestor FDs.
4. Equality between the alias-following **prefix-only** `fstatat` identity and that
   held target identity. Revalidation checks the alias version and target binding.

Only this fixed OS prefix is followed. The suffix is never resolved as a whole.
All existing ancestor/leaf identity, version, expected-manifest and no-replace
checks remain. A retargeted prefix, replaced directory, or descendant symlink
fails closed; matching bytes do not renew ownership.

Canonical `/private/...` spellings use the same no-follow directory walk directly.
Ordinary Foundation temp/home/app-container paths need no test-only conversion.
App-group-style paths with spaces are ordinary descendant components, not special
alias permissions. Custom descendant symlinks are not promoted to trusted roots.

### Readonly prospective paths

`ToolsFileSafety.checkedPath` validates every existing component with held directory
descriptors. It can stop at a missing suffix for prospective app-owned paths,
without mkdir, migration or writes. `checkedChild` retains its component grammar
and validates the root as a directory, then the child without following a leaf
symlink. Actual Tools I/O still pins/revalidates descriptors when it starts.
A checked URL is not a retained I/O capability and does not replace those receipts.

`ToolsBackupPolicy.validateLocation` keeps its exact `settings`-directory and
allowlist rules and delegates only the filesystem check to that shared path policy.
Restore and ownership code inherit the corrected boundary: their transaction,
CAS, manifest, rollback, cleanup-debt and recovery decisions are not changed.

### Narrow Emoji / Cloud allowance

- `EmojiPackStore` no longer resolves an entire caller-supplied root in its
  nonthrowing initializer. Root creation uses the no-follow directory opener and
  child lookup uses the common checked-child boundary, mapping failures to
  `EmojiPackError.storage`.
- `CloudFileStateStorage` validates its directory through the same boundary and
  creates it through the no-follow opener, preserving `CloudError.localStorage`.
- Both retain their existing file-data read/write algorithms, encodings, quotas,
  account checks, font inspection/origin rules, metadata contents and sync logic.
  This cohort does not claim to redesign either domain's transactions.

## Exact APIs / scope

Existing public signatures remain:

```swift
ToolsFileSafety.checkedChild(_ name: String, root: URL) throws -> URL
ToolsFileSafety.read(_ url: URL, maximumBytes: Int,
                     hooks: ToolsFileOperationHooks = .init()) throws -> Data
EmojiPackStore.init(root: URL, accountId: Int64)
CloudFileStateStorage.init(directory: URL) throws
```

Internal filesystem APIs:

```swift
ToolsFileSafety.canonicalFileURL(_ url: URL) -> URL // spelling only
ToolsFileSafety.pathComponents(_ url: URL) throws -> [String]
ToolsFileSafety.checkedPath(_ url: URL, directory: Bool = false) throws -> URL
ToolsDirectoryDescriptor.open(_ url: URL, create: Bool = false) throws -> ToolsDirectoryDescriptor
ToolsDirectoryDescriptor.checkedPath(_ url: URL, directory: Bool) throws -> URL
ToolsSystemAliasPin.init(root: ToolsDirectoryDescriptor, name: String) throws
ToolsSystemAliasPin.verify() throws
```

Production constructs `ToolsSystemAliasPin` only with the `/` descriptor and the
three literal names. Tests can use an owned miniature root to exercise the exact
same link/target identity checks without modifying real OS aliases. It is not a
public caller-configurable alias whitelist.

Changed production files, all under
`swift/ExteralessCore/Sources/ExteralessCore/`:

- `ToolsFileSafety.swift`
- `ToolsFileDescriptors.swift`
- `ToolsBackupArchive.swift` — only location filesystem validation
- `EmojiPackStore.swift` — only filesystem root/child boundary
- `CloudSyncState.swift` — only filesystem directory boundary

The new test file uses the existing SwiftPM/Core test source glob; no BUILD edit
or new dependency is required.

## Meaningful regression fixtures

`swift/ExteralessCore/Tests/ExteralessCoreTests/ToolsDarwinStorageTests.swift`
supplies seven Darwin cases (six also compile/run on Glibc):

1. Raw `FileManager.default.temporaryDirectory` child read/write and actual client
   restore. It asserts the real prepared journal was observed, then retired, so a
   premature path rejection cannot pass as a simulated fault.
2. Real Darwin `/var`, `/tmp`, `/etc` and `/private/...` directory identities,
   Foundation home-root metadata, raw temporary URL and an owned app-group-style
   path. OS/home contents are not read or modified.
3. Descendant symlinks named `var` / `tmp` / `etc`, including a missing suffix,
   remain rejected; foreign file bytes stay intact.
4. An owned miniature system-root pin rejects link retargeting, a wrong target,
   and replacement of the documented target directory by another inode.
5. Leaf substitution after real source metadata, using a dedicated synchronous I/O
   queue and two-second barriers. Every `DispatchSemaphore.wait` is in synchronous
   code; there is no noasync wait inside an async/actor task.
6. A moved held directory cleans only its own entries and preserves the foreign
   replacement under the old filename, returning cleanup debt.
7. Actual Emoji store recreation/font bytes and Cloud metadata save/reopen on raw
   Foundation paths, followed by descendant-root redirection rejection. Fixtures
   use the small existing self-owned font data and metadata only.

All directories/files created by these tests have unique fixture roots. The
coordinator's runner should enforce the existing **30-second per-fixture bound**.
No old test root is rewritten with `resolvingSymlinksInPath`, and no earlier
assertion, size limit, fault hook, CAS or admission expectation was relaxed.

## Rerun / evidence boundary

Local checks: source delimiter checks and scoped `git diff --check` passed;
whole-path resolution/standardization is absent from the five changed boundaries.
Swift/swiftc is unavailable on this Windows host. The Mac results above are the
**failing pre-fix run**, not a new pass. Coordinator owns the one coherent native
Mac rerun after this cohort is joined.

Rerun the full existing cohort, particularly ToolsArchiveBudget / Backup /
Followup / Recovery / Schema / AdmittedProjection / SubtitleStore, all existing
descriptor/publication race cases, the Cloud host/preview/metadata cases and the
three Emoji store cases, plus the new alias tests. Do not count a source check or
a negative fixture's earlier path error as execution closure. AI UTF-16 remains
the coordinator's independent correction.

## Frozen paths

The existing Core tests are byte-preserved; only the distinct new test file is
added. PNP policy, renderer source and performance source-pin documents are not
rewritten. This path cohort also leaves these transaction/ownership bodies intact:

```text
cbc6628a82e53cc155b0da97280f86efa2dbd632f076350844114c3bc20a747d  swift/ExteralessCore/Sources/ExteralessCore/ToolsPerformancePolicy.swift
cb24284049116a67f5b5e1ffa1d55cf03ff15ff2ea2438616f937dbcf8bbae98  swift/ExteralessCore/Tests/ExteralessCoreTests/ToolsPerformancePolicyTests.swift
5865c79e377cdc2464714e4879069ce5fd61fdc55e21aa59bf126fc705dc08d7  swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift
e4b546dc477be886905c0fccddc89fcfa9d205e181f1af85ed3a08944e0391c9  swift/ExteralessCore/Sources/ExteralessCore/ToolsFileOwnership.swift
```
