# Native Elyx FD authority — independent review

**Stable-backend verdict: changes required — one P1 and two P2 source findings.**
The v1 capability/reader design is materially implemented, including real
directory-FD operations. The findings concern cleanup after namespace loss,
pre-retirement load-policy validation, and publication-failure response fields.
They do not depend on the announced NativeStartup/Root/readiness join being absent.

Review date: **2026-11-16**. Observed HEAD:
`31287b9204aef5384b85d75f97f233dccf230409`, with concurrent worktree changes.
Initial backend capture: `2026-11-15T22:42:29Z`; later read image:
`2026-11-15T22:51:41Z` (machine UTC). Only this document is authored here.

Inputs: [remediation continuation, line 312 onward](../native-elyx-developer-remediation.md),
the [exact v1 ABI](../elyx-source-descriptor-v1.json), production
Files/Descriptor/Transaction/Request/Candidate bodies, C/BridgeServices, the Python
FD-inspection consumer, and the **21 prepared filesystem tests**. Some activity,
registry-readiness and Host TLS additions arrived during review; the affected
backend bodies were reread. Their read-time hashes are recorded below. Final
entrypoint/startup acceptance belongs to the owner's completed join, not this
intermediate review.

## Path key

- `H` = `swift/PluginHost/Sources/PluginHost/`
- `F` = `H/PluginElyxDeveloperFiles.swift`
- `D` = `H/PluginElyxDeveloperDescriptor.swift`
- `T` = `H/PluginElyxDeveloperTransaction.swift`
- `R` = `H/PluginElyxDeveloperRequest.swift`
- `Z` = `H/PluginElyxArchiveCandidate.swift`
- `P` = `python/exteraless_runtime/`
- `U` = `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/`
- `FT` = `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift`

All line references below use the later read image unless explicitly identified
as the initial image. Full paths, hashes and selected stable spans are at the end.

## Findings

### NFD-01 — P1: cleanup deletes through a stolen staging-parent FD

**Locations:** `F:422–443` (`elyxRemoveOwned`), `F:512–520` (`ElyxStage.deinit`),
and the error-cleanup callers at `F:497–500`.

The destructive helper checks the **leaf** identity, quarantines it with an
exclusive rename, checks the moved identity, and unlinks it. It never calls
`directory.verify()` or checks the stage's namespace watch. Its
`directory.metadata(name)` call is only `fstatat` (`F:191–207`), not namespace
validation. The destructor likewise does not call `checkNamespace()` after its
`beforeCleanup` hook.

Consequently a rename of the captured operation directory is detected by normal
candidate checks (`F:504–505`) but ignored by cleanup. The held dirfd still resolves
its original candidate after the parent namespace has been stolen. Cleanup removes
that file in the moved directory; the later lookup of the old operation name can
return ENOENT without recording recovery debt. This violates the requested
no-file-deletion-after-stolen-parent boundary. The finding is specifically about
deletion in a lost namespace; it does not assert recursive deletion or that an
arbitrary different leaf inode passes the identity check.

**Minimal real-provider fixture to add to FT; source witness, not executed here:**

1. Use the existing `rig()` and prepare its small candidate normally.
2. In `.beforeCleanup`, move the operation directory, without changing its contents,
   from `.elyx-developer-staging/op-…` to the fixture root's `stolen-stage`.
3. Release the prepared lease, making this the last stage reference.
4. Assert that `stolen-stage/candidate.eaf` still contains the candidate and that
   recovery prevents another stage admission.

The current trace is deterministic: `beforeCleanup` returns → `fstatat` through
the old operation dirfd finds the expected candidate → `renameat2`/`renameatx_np`
quarantines it in `stolen-stage` → `unlinkat` removes it. Both assertions in step
4 lack the necessary guard. `FT:273–291` replaces the **leaf**, and
`FT:309–326` changes the installation parent during **publication**; neither
exercises this cleanup case.

**Closure needed:** make lost/ABA staging namespace a retain-and-recovery result
before destructive cleanup, including failed preparation. Keep the existing
nonrecursive leaf-identity/quarantine checks. A plain held FD must not silently
replace the missing namespace authorization. Guarded publication rollback into
two captured slots is a separate operation from this final deletion.

### NFD-02 — P2: known unsupported load constraints pass FD inspection

**Locations:** `P/_archives.py:614–638,647–686,817–826,1202–1219`;
`F:680–713`; `H/PluginHost.swift:1107–1140`.

The FD inspector really reaches `_inspect_archive_bytes`; it is not replaced by
the native ZIP transformer. However, some already-known platform load constraints
are deferred to `_load_record`:

- A nonempty metadata `requires` mapping is accepted by inspection, but always
  rejected at `_load_record:1207–1209` because there is no cross-owner import
  provider.
- `_wheel:638` retains `Requires-Python` without validating it. Its compatibility
  check occurs only at `_load_record:1215–1218`.

`F.prepare` accepts the inspector's metadata after checking ID/format/engine and
descriptor consumption. Host then retires the old owner at line 1117, publishes
the new bytes at line 1130, and only afterward loads the new worker. The known
unsupported requirement therefore becomes a post-publication reload failure
instead of a pre-retirement refusal. This finding does not require predicting
arbitrary plugin exceptions or executing entry code during inspection.

**Independent bounded helper witness executed on CPython 3.12.10:** two own ZIPs
were created exclusively in `BytesIO`. The actual `_inspect_archive_bytes` and
`ArchiveAdapter._load_record` bodies were called; the latter received only an
own-ID checker and an empty-requirements recorder, with entry execution trapped.
No FD registry, native authorization, extraction or publication was simulated.

| Candidate | Inspection | Later actual load-policy body |
|---|---|---|
| 512-byte ZIP, unchanged ID `7_archive`, metadata `requires: {"other_archive": null}` | Accepted | `Elyx requires cross-plugin imports have no iOS cross-owner module provider: other_archive; dependency URLs are metadata only` |
| 1,130-byte ZIP with a pure `py3-none-any` wheel whose METADATA contains `Requires-Python: >=99` | Accepted | `local wheel requires Python >=99` |

The minimal archives otherwise contain ordinary `refmap.json`, `meta.json`, and
`main.py`. The second adds `wheels/own-1.0-py3-none-any.whl` with valid WHEEL and
METADATA files. Their SHA-256 values were respectively:

```text
1a44cc6e9b555f5dadc4a65e1d409583e99576a044afa3273e54e88562627335
4a94373036c53355d533ec900507f29ccd432029757dc28b0bf6638a3a432858
```

A negative control adding `library.so` was rejected by the actual static
inspector. Thus existing native-member restrictions do run, while the two
specific constraints above do not. Entry execution, filesystem writes and native
FD execution were all zero in this helper. The command had a 30-second bound.

**Closure needed:** use a shared, side-effect-free platform-load preflight before
the FD inspector returns success, and retain the load-time checks. Reject these
known unsupported import/version constraints before Host retirement. Any required
approved-dependency snapshot must be supplied explicitly; metadata must not grant
permissions or trigger installation/network work.

### NFD-03 — P2: publication outcome is lost at the native wire error boundary

**Locations:** `F:30–41,779–835`; `R:144–153`;
`U/PluginElyxDeveloperIngress.swift:35–46`; `T:187–199`.

The file engine distinguishes `refused`, `rolledBack`, `committed`, and
`recoveryRequired`, with `sourceChanged` false/false/true/unknown. But the real
ingress sends every thrown error through `PluginElyxDeveloperError.response`.
That function extracts only `PluginElyxDeveloperError`, not
`PluginElyxDeveloperPublicationFailure`; it returns `ok`, `error`, `error_kind`,
`plugin_id`, `reloaded`, and `errors`. **It omits both the publication outcome and
`source_changed`.** Commit knowledge survives only in free-form error text.

For a directory-fsync failure after the engine's confirmed exchange, this loses
a known `sourceChanged == true` result. For an unprovable rollback/namespace, it
also loses the explicit unknown result. Errors from Host persistence or a final
session check after successful publication have the same missing structured
commit context. This is an omission, not a claim that the formatter emits false.

**Minimal native value fixture; not executed here:**

```swift
let request = try PluginElyxDeveloperRequest(json:
    #"{"@":"elyx_changes","plugin_id":"7_archive","changes":[]}"#)
let failure = PluginElyxDeveloperPublicationFailure(
    outcome: .committed, detail: "directory fsync EIO")
XCTAssertEqual(failure.sourceChanged, true)
let reply = PluginElyxDeveloperError.response(failure, request: request)
XCTAssertEqual(reply["source_changed"], .bool(true)) // current value: nil
```

**Closure needed:** carry the typed publication outcome through the transaction
and error formatter, with Bool/null source-change semantics. Preserve that context
for failures occurring after a successful publish too. The existing protocol
test preserves `ok=false`; it does not assert these publication fields.

## Mechanisms which are present in the reviewed source

### Opaque read-only SourceProof: exact eleven-key ABI

The provisional three-key descriptor in the earlier report is superseded by
`elyx-source-descriptor-v1.json`. Native issuance at `D:224–249` constructs exactly:

```text
abi schema capability purpose plugin_id owner_token format
source_sha256 byte_length source_namespace source_nonce
```

`D:254–264` compares the entire decoded value to the registered native proof
**before** consumption. Capabilities, namespace and version nonces are native
64-lowercase-hex values. The registered backing retains a read-only FD and native
claims/checks; JSON does not register a pathname, FD, owner, grant or replacement
proof. Wrong issuer/purpose/context, modified proof and replay fail. Descriptor
and claims fields are native immutable values; Python's checked proof is a
`MappingProxyType` at `P/_archives.py:701–763`.

`python/bridge/_exteraless_bridge.c:3529–3592` accepts only the five operations,
bounded UTF-8 payload text, and constructs identity from C module state. It uses
the retained dispatcher under the caller GIL and frees the response buffer on
all exits. There is no legacy-service or raw-FD fallback. BridgeServices' applied
early route at `H/BridgeServices.swift:238–255` deliberately uses this registry
before ordinary Java/owner admission: inspection has no plugin owner, and release
must remain possible for a retiring caller. The registry supplies the narrower
authority checks.

| Operation | Concrete native check / result |
|---|---|
| `claim` | `D:335–343,254–294`: inspect/load only, exact eleven-field equality, current native TLS, matching immutable C identity, one consumption per capability. |
| `manifest` | `D:345–360`: current C/native owner and expected digest; exactly **one** registered live Source receipt. Two matching receipts intentionally fail; no first-match/path-only selection. `F:662–678` rechecks the captured installed file and full hash. |
| `read` | `D:377–381,480–485,510–535`: native-owned duplicate, explicit `pread`, offset `0...length`, count `1...65536`, exact `min(count, remaining)` bytes. Custody checks bracket reads. |
| `check` | `D:370–375`: same caller/ticket/proof, current native invocation and backing; exactly read_id/descriptor/current. |
| `release` | `D:368–371,498–508`: absent ticket returns false; existing ticket requires its recorded C owner. Owner release may proceed during retirement, without admitting another read. |

Numeric offsets/counts reject CFBoolean, floating storage and out-of-range
integers (`D:412–417`). Payloads are at most 4096 UTF-8 bytes with exact key sets;
the Python consumer independently rejects Bool-as-int schema/length/readiness,
wrong returned offsets, invalid base64/length and digest/proof mismatches
(`P/_archives.py:701–802`). No descriptor or reply serializes an FD.

Inspection's `@elyx-inspection` is **not a privileged string capability**.
`D:119–147,216–222,279–294` requires its unique native registry/invocation context,
bound to the issued descriptor, plus null C owner token. A plugin cannot select
that context through payload fields. The read image's Host inspector now binds
the concrete descriptor after reserving the inspector and installs/clears TLS on
the actual worker (`H/PluginHost.swift:1017–1054`). This observation is not final
acceptance of the still-owned startup/readiness composition.

### Reader lifetime and actual execution cleanup

`D:473–540` owns a separate `F_DUPFD_CLOEXEC` descriptor and holds the backing Entry.
The duplicate shares kernel open-file state, but all reads use explicit `pread`
offsets, so consumers do not share a mutable seek position. Retiring a ticket
revokes use; ARC closes its FD only after outstanding native references release it.
The backing closures retain their actual held file/stage, not just an integer FD.

`D:384–403` registers reader cleanup with the native TLS Box (`D:31–55`). A manifest
scope also retains its issued capability until finish. Python release is not the
sole cleanup path. The Host invocation retains `retainingElyxSource` and clears
TLS at execution completion; `H/SubinterpreterManager.swift:429–442` runs that
completion in the mailbox's `defer`, after actual worker entry/return. Async
waiter cancellation alone does not close an FD still used by that work.

Registry invalidation now closes future admission while allowing recorded release
(`D:166–180,325,368–371`). It does not recycle backing resources from an in-flight
reader. Default capability and reader limits are 64, configurable up to 256;
source/stage limits are independently 8/8 (`D:162–164,243,388`; `F:575,613–620`).
New activity counters are observations, not permission or FD authority.

### Filesystem custody, bounded candidate and real atomic exchange

- `F:157–239` walks from `/` through held directory FDs with nofollow/close-on-exec,
  checking entry/opened identity. Only actual Darwin OS-root var/tmp/etc aliases
  to the fixed private target are accepted and pinned. Arbitrary descendant
  symlinks are not canonicalized into authority.
- `F:105–124,370–405` pins device/inode/type, size, link count, mode, nanosecond
  mtime/ctime; source must be singly linked, regular, nonempty, O_RDONLY and at
  most 32 MiB. Capture reads bounded chunks and rechecks the held/named file.
- `F:267–367` continuously observes namespace-self rename/delete/revoke using
  kqueue or inotify on held inodes. Linux's `/proc/self/fd` path is the kernel's
  held-FD link. Draining an event permanently revokes that watch, including ABA;
  ordinary writes to ancestor `plugins.json` are not namespace-self events.
- `F:458–496` uses a unique 0700 sibling stage, exclusive nofollow candidate
  creation, bounded writes, 0400 sealing, fsync and a separate read-only open.
  The writer's lifetime ends before the inspector is called. Staging is outside
  old archive cache/extraction cleanup.
- `Z:25–96,109–205` limits source/output ZIP to 32 MiB, outer expansion to 64 MiB,
  entries to 2048, members to 16 MiB and central data to 2 MiB. Request limits are
  128 changes / 256 KiB decoded content (`R:11–13,59–68`). The transformer preserves
  untouched compressed bodies; it does not substitute for CRC/inflation,
  metadata or nested-wheel inspection.
- The actual FD inspector reaches `_CheckedZip`, mapping validation and `_wheel`
  using one aggregate outer-plus-wheel budget (`P/_archives.py:149–234,614–686,817–826`).
  Native binaries, wheel ABI tags, nested wheels/.pth/.data, path aliases and
  incompatible bytecode magic are checked. NFD-02 identifies the remaining
  specific load-policy checks, rather than calling this route absent.

**The publication primitive is a kernel exchange, not inode-CAS.**
`F:408–416` calls `RENAME_SWAP` / `renameat2(RENAME_EXCHANGE)` on held parents.
`F:754–778` checks source/candidate before exchange and verifies both resulting
slots, versions and hashes afterward, including the actual displaced source.
It deliberately excludes rename-induced ctime differences from the post-rename
version comparison; it does not claim an atomic compare-and-swap of metadata.

Before confirmation, rollback is attempted only while both captured slot
identities match, and the two resulting identities are checked again
(`F:808–821`). A replaced slot or unproven rollback retains the stage and records
recovery. After confirmation, directory-fsync failure follows the committed/
recoveryRequired branch, not a false no-write success (`F:779–806`). A successful
publication updates the namespace pin and source nonce; rollback also advances
the operation nonce, invalidating older leases. A duplicate publish does not
corrupt a successful receipt.

Recovery preservation disables new **stage admission**, and a nonempty staging
root cannot be silently adopted by a new provider (`F:508–510,564,613–623`).
Cleanup is nonrecursive and refuses different leaf identities/nonempty directories;
NFD-01 is the missing parent-namespace check within that otherwise narrow cleanup.
NFD-03 is the later loss of the engine's typed outcome at the wire boundary.

## Positive update/reload route: own retirement is expected

The source does not require the old callback owner to remain live throughout
publication. `F:652–660` checks consent/readiness/file/version custody;
`currentTarget` is additionally required for open, manifest and preparation.
`F:733–739,848–854` can therefore remain valid while Host intentionally retires
the old owner, provided the file and captured consent stay valid.

`H/PluginHost.swift:1098–1145` holds the per-ID mutation reservation, verifies the
old target before unload, then uses a new publication predicate requiring **no
current callback owner**, the same persisted model and the same consent. The
model projection excludes transient loaded/handle flags (`T:23–28`;
`H/PluginModel.swift:129–133`). Host's ordinary unload persistence changes an
ancestor file, not the pinned installation directory's entries.

After byte publication, new metadata is persisted with the original path/format
and enabled state. `F.loadSource:857–878` requires a genuinely different current
native owner, emits a load-purpose proof with the new source nonce, and checks
the published bytes again. Host passes it through `_elyx_developer.load_verified_json`
(`H/PluginHost.swift:1724–1743`; `P/_elyx_developer.py:99–118`). The Python context
holds inspected immutable bytes through `load_json`; `snapshot_for_load:854–863`
consumes them once without reopening the label path.

Changed class/code or declared metadata permissions do not reuse an old instance
or grant consent: the existing loader instantiates the new entry, while native
consent is compared as a snapshot including revision. Publication uses
`persistInstalledPlugin`, not `prepareInstall`/`setGranted`. Final delivery checks
the actual new owner and consent (`T:187–199`). A load failure can correctly return
`reloaded=false, source_changed=true`; known unsupported preflight failures should
instead be caught earlier as NFD-02 describes.

This is the positive source route. The current FT positive test publishes while
the old owner is still live and then calls ordinary Host reload; it does **not**
execute the full reserved-retirement/verified-load transaction.

## Prepared 21-test matrix: assertions and actual limits

All entries below are **source definitions, not new passes**. FT uses actual file
operations and the actual registry. Its inspector/engine uses small JSON files
instead of full Elyx ZIP/entry execution (`FT:34–46,53–126`). Assertions about disk
bytes, identities, counts and response fields are useful external observations;
the canned inspector cannot establish full Python preflight or joined C/TLS entry.

| FT test / lines | What its assertions establish if run; important boundary |
|---|---|
| `testSHA256KnownVectors`, 141–146 | Independent standard hash vectors, including empty and multi-block input. |
| `testRealStagingPublicationAndNewOwnerDescriptor`, 148–192 | Original bytes unchanged before publish; candidate/version persisted; duplicate publish does not invalidate receipt; old/new owner, forged fields/token and replay controls. Publication precedes ordinary reload in this fixture. |
| `testForgedFdDigestPurposeAndInspectionContextNeverAuthorize`, 194–210 | Foreign registry and added fd/hash fields fail; no leaked issued descriptor. It does not independently mutate every one of the eleven valid proof fields. |
| `testInspectorCannotReturnSuccessWithoutNativeResolution`, 212–223 | Canned success without consumption fails, live bytes unchanged, stage/capability counts drain. |
| `testBridgeReadinessAndMetadataFailurePrecedePublication`, 225–239 | Missing verified-load hook and changed metadata ID refuse; no publication. |
| `testSameDigestReplacementAndNamespaceABAInvalidateCapture`, 241–254 | Equal-byte inode replacement and real rename-away/back invalidate held source. |
| `testSymlinkAndParentSwapCannotRedirectReadsOrWrites`, 256–271 | Source-capture parent redirection fails; outside marker survives. |
| `testCandidateReplacementBeforeInspectionIsRetainedNotUnlinked`, 273–291 | Replaced leaf survives cleanup; diagnostics and later staging refusal. Does not steal the operation directory. |
| `testRevocationAtAtomicExchangeRollsBackCapturedInodes`, 293–307 | Post-exchange revocation gives rolledBack/false, original bytes restored and old lease invalidated. |
| `testParentSwapAfterExchangeRollsBackOnlyHeldNamespace`, 309–326 | Replacement namespace marker survives; rollback restores only the held old namespace. |
| `testUnrecoverableRacingSlotAndPostCommitFailureReportTruthfully`, 328–353 | Third-inode slot gives recoveryRequired/unknown; throwing at `.committed` gives committed/true. That hook runs **after successful fsync**, so this is not actual directory-fsync-failure coverage. |
| `testCancelledWaiterRetainsActualInspectorFDThroughCompletion`, 355–390 | Actual FD remains open while a fixture-retained task outlives its cancelled waiter; eventual capabilities/stage drain. The retained task models the mailbox; it is not a C/Host inspector execution. |
| `testCandidateSurvivesOldArchiveCachePurge`, 392–405 | Real old-cache purge leaves private stage and prepared custody intact. |
| `testCancelledLoadWaiterCannotRecycleRetainedDescriptor`, 407–444 | Real FD survives waiter cancellation and Host disable while explicitly retained; eventual capability release. |
| `testConsentRetirementDuringInspectionDoesNotPublish`, 446–459 | Native consent change invalidates prepare; original bytes/staging assertions. |
| `testSourcesAndStagesHaveIndependentFiniteBudgets`, 461–477 | Real 8/8 admission/release boundaries. Does not exercise the registry's 64-capability ceiling. |
| `testPreparedCandidateCannotSurviveBridgeEpochReplacement`, 479–489 | New readiness epoch invalidates prepared candidate; installed bytes unchanged. |
| `testV1ManifestChunkCheckReleaseExactShapesAndNoRawFD`, 491–534 | Exact proof/reply keys, bytes, Bool/negative/oversized read bounds, foreign release, idempotent release and stale read. Only one ticket/offset-zero data read. |
| `testV1InspectionClaimUsesExactProofAndChunkTransport`, 536–544 | Actual native registry wire claim/read/check/release, duplicate-claim rejection and descriptor/ticket drain. No C gate. |
| `testManifestRejectsAmbiguousReceiptsAndActualFinishReclaimsTickets`, 546–566 | Two active receipts fail; one succeeds; clearing native TLS reclaims ticket/capability without Python release. Does not itself drive Host's completion callback. |
| `testManifestReadRefusesSourceReplacementAndAllowsRetiringRelease`, 568–580 | Source replacement rejects check/read and still permits release. Despite its name, it does **not retire the Host owner**. |

Focused missing assertions are the NFD-01 stolen-stage cleanup case, NFD-02
preflight cases before retirement, NFD-03 stable failure fields, actual fsync
failure, two independent ticket offsets/EOF, true retiring-owner wire release,
and the complete normal update through Host reservation with changed entry and
metadata permissions. The final owner join also needs its actual execution and
cleanup assertions. These are evidence gaps, not additional claimed source bugs.

## Verification scope and supplied receipts

- Here: read-only source/AST/hash checks; exact eleven-key native descriptor and
  issuance sets; five operation routes; 21 test definitions. One bounded in-memory
  static/load-policy helper produced the two NFD-02 witnesses above. No native
  filesystem test or Swift compilation was run on Windows.
- [C gate receipt](../elyx-c-gate-validation.md): **7/7 per 3.12/3.14**, each with
  **61 calls, 60/60 freed buffers, 33/33 released contexts**, through real C and a
  C recorder. It proves transport/context/buffer behavior, not this FD registry.
- [POSIX followup](../elyx-posix-host-followup.md): the preserved **42 passed,
  0 skipped** Python result belongs to `ff9134924cdc1c41aeecb2af1f4cf194a1963550`.
  It excludes the new native Files/Descriptor provider. The later compiler
  diagnostic is historical; the coordinator's typed permission-predicate rewrite
  is present. It is not treated as a new finding or as compilation success.
- `tools/compat/tests/test_native_elyx_files.py:17–37` prepares local native build
  and test phases with 120-second compile / 30-second runtime bounds. Its Windows
  skip is not a positive FD result. The new 21-test suite remains unexecuted here.

No external archive/plugin, account, HTTP, CI or progress-poll operation was used.
No implementation, test, existing receipt or SDK original was edited. This report
does not certify the pending Root/NativeStartup entrypoint or broaden into a
Python/JVM security audit.

## Read-time source pins

These are raw-byte SHA-256 values for the 26-file later read image. Corpus hash:
`b1d9b31e810cfe989de8a67e663672a06c5bc2987ab9a3e4123b0e0a10e5e81a`.
Algorithm: SHA-256 of sorted UTF-8 `path + NUL + sha256_hex + LF` records.

The initial Files/Descriptor hashes were `e8382f29bb7967c3de7e635158b0d312b62b4ecde9ea9b336dbf482d04895ede`
and `4146d16f51d345280cea3a85a1b364e30f599d4fdbf40cddb4c833fb971b48ba`.
Concurrent activity/readiness additions explain their later hashes; cleanup,
preparation and publication bodies were reread and independently span-pinned.
These hashes are read-time anchors, not a claim that an active shared worktree
has stopped changing.

Post-write integrity check: **25/26 raw input pins still matched**. The parallel
Host file advanced to `9d9036b5f45c38a8ba406c10e6cda74990276acc66aa674bf575caf9e6503ba3`;
its three named method bodies retained exactly the hashes below, with line ranges
shifted by one to 1099–1146, 1688–1777 and 1018–1055 respectively. All nine scoped
bodies matched when located by their names. This is recorded source movement,
not an additional finding about the pending join.

<details>
<summary>Raw input manifest</summary>

```text
7c1d62d040f75b900bdd0ece50335797fd0596fde5ddb38f8e77b449c3e3c83c docs/wave-2/elyx-source-descriptor-v1.json
f6be049d281245e5633747a2ebc07f46a8a145a2b0f41c26e1dfbfd02745091b docs/wave-2/native-elyx-developer-remediation.md
e913e3069968312ba617c36699ceea809c1cfe235b379c4d066ba65e3fc36745 docs/wave-2/native-elyx-developer-files-root.patch
3b5fbd409139999e31244c8ad45fd2633ee2353f0f43c5bbc356e83d7261b2dd swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperFiles.swift
24aa4fc3e79b2f9d907f9f97188e31f7f25e64b56c801a028c194aced44ad146 swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift
ed22be0fe9deb8abb60d5614dc29ad96c1a40f4f4b59425654a6fd5d26b650d4 swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperTransaction.swift
82f9655ccd392d4b76cd6df46e547d8d9e1b494a03e5256994f05be7b5e85eca swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperRequest.swift
adebf1552551bbc7faa826821596dfec50fbcded9ed59cc369da6613e8029e21 swift/PluginHost/Sources/PluginHost/PluginElyxArchiveCandidate.swift
fc1d977df4c278ea89fd745872e8ace0de98c8854255e87b0e51add8d3c3bab6 swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift
3de3e85b1d06b6edb22c817b5f84e4545ae02a4396ab259288dd131201526c7a swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperTests.swift
04169c2cdd57e4c41ae4f30c400ac574242a44e0366121b300b3d6a564991cda swift/PluginHost/Tests/PluginHostTests/HostLifecycleTestSupport.swift
d5cf1997b54359323a38db2dbe39002a59a59642514b8fc27db66dc7184c3815 swift/PluginHost/Sources/PluginHost/PluginServiceModels.swift
1926e6aad7bd145cb0438ea56080e812e3e0fb962c963f1c7640a13b632f8c8e swift/PluginHost/Sources/PluginHost/PluginRuntimeProtocol.swift
2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2 python/bridge/_exteraless_bridge.c
f68ed0c19989f959fd376fe94a3ca75365ade9be0e68244de3c29ab5a204773e python/exteraless_runtime/_archives.py
a2b999fb1113249c557a5c9fb90e57476b06bac05b597b9bbebb3e688e926690 python/exteraless_runtime/_elyx_developer.py
73ba9424868df41d20a861fb57e5ffc0362dd7568ce7401d77b7d57a43414694 swift/PluginHost/Sources/PluginHost/BridgeServices.swift
086a9cc737f991fb5b03c59748d2b9cb4312e10ddd580ee4270244d260fe490a swift/PluginHost/Sources/PluginHost/PluginHost.swift
10a00a89ddd35dc08eeb21014aab74f77284d6064ff90e297d9eba56985383e0 swift/PluginHost/Sources/PluginHost/PluginModel.swift
5880f3e6d9a3c00fb6793de3fa286b571350fbb81f4db7287ef8a6f498ea9ca8 swift/PluginHost/Sources/PluginHost/PluginTrustLevel.swift
2f01f17fd5e12d1d561339097a25270f4277766cda58f38c36b0f0005dd43c60 swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift
db83737d655fc22e84e5b00341ba7a9dc1ab632ca43a65a068b8eb61de49050f telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginElyxDeveloperIngress.swift
d7879346ce8852f7105235f18f66191b9ce0e07504fc650adf4aa5693c9529c5 telegram-ios/submodules/TelegramUI/Tests/PluginElyxDeveloperProtocolTests.swift
fc60e05b1cd9493f29a0d4aed79577b2561891bf70438a644e0dd60d1ef99dd4 tools/compat/tests/test_native_elyx_files.py
2108d4da990b18325530797d53bd2f6ffa5675dc5795f2f35e6a1c6a4baf8004 docs/wave-2/elyx-c-gate-validation.md
293f7eba6ee63aea1a21b924faef8cb977ecf24a9760ed3b7b0d24f9217be75f docs/wave-2/elyx-posix-host-followup.md
```

</details>

Span hashes: inclusive lines, UTF-8 with LF, original indentation, one final LF.

| Span | Lines | SHA-256 |
|---|---:|---|
| `F#elyxRemoveOwned` | 422–443 | `09265e71d33997724e6691cdc1002085e71c94184aef857e2b3cc479ce4cfa53` |
| `F#ElyxStage.deinit` | 512–521 | `00317ec6b918a08ac893410cd89039e0d7abac40fc9ba0160753660dcee45e43` |
| `F#ElyxFileSource.checkCurrent` | 652–660 | `2f6d186354cdc079a95e9922e3d54ad97348f19d75e66592136072771667fa44` |
| `F#ElyxFileSource.prepare` | 680–715 | `3956c990e4fa6b9d0d67dfaf7063ebaa4ca519dfa2332a930b4d5092317a16d9` |
| `F#ElyxPreparedFile.publish` | 742–838 | `2c55213229a58dbba62e960b77e895283412fa706ee7a4f9273132b7f1a47f85` |
| `H/PluginHost.swift#publishElyxDeveloper` | 1098–1145 | `485ff9d470d5ba26205f8bcdb576fb22834014c0f712f3ec1a03d5cba0416344` |
| `H/PluginHost.swift#loadPlugin` | 1687–1776 | `fa2e608df7fe05f8306e30a7e6333329abd45228126bc73b6ed1ff5fa81edce7` |
| `H/PluginHost.swift#inspectElyxDeveloperDescriptor` | 1017–1054 | `5d2336d961b315be1e3fbd43a58f74aab57c39a35c6addd0301fb8964d064663` |
| `H/BridgeServices.swift#dispatchJSON` | 232–296 | `535556fe943723cf69e0dbf745e54c27bae412ffc2c52b3e9c1ab4bd94eb6a8c` |
