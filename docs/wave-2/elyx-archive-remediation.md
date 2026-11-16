# ELYX-GAP-01: native archive admission and SDK adapter

## Status and scope

Implemented `.elyx/.eaf` inspection, native installation/replacement and SDK
loading in PluginHost. This is an implementation change, not a change to the
source-route classification in `sdk-symbols/elyx.json`.

**Python evidence:** 12 owned archive cases passed; one filesystem-symlink case
was skipped because Windows cannot create symlinks without the required
privilege. The 13 existing owned source-runtime cases also passed. Swift/native
Mac execution and file-picker UI verification are coordinator handoffs, not
claims based on earlier Mac/IPA receipts.

### Exact files authored for this remediation

- `python/exteraless_runtime/__init__.py`
- `python/exteraless_runtime/_archives.py` (new)
- `swift/PluginHost/Sources/PluginHost/PluginHost.swift`
- `swift/PluginHost/Sources/PluginHost/PluginModel.swift` — upper Plugin/format/ID
  declarations only; concurrent PermissionsModel/PluginStore work belongs to
  the trust-level author.
- `swift/PluginHost/Sources/PluginHost/PluginRuntimeProtocol.swift`
- `swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift`
- `swift/PluginHost/Sources/PluginHost/PythonRuntime.swift`
- `swift/PluginHost/Tests/PluginHostTests/PluginArchiveHostTests.swift` (new)
- `swift/PluginHost/Tests/PluginHostTests/PluginServiceStorageTests.swift` — invalid
  ID expectations updated for the native union grammar.
- `tools/compat/tests/test_ios_elyx_archives.py` (new)
- `tools/compat/tests/test_ios_runtime.py` — the unsupported-extension fixture now
  uses generic `.zip`, rather than the newly supported `.elyx` suffix.
- `docs/wave-2/elyx-archive-coordinator.patch` (new, **not applied here**)
- `docs/wave-2/elyx-archive-remediation.md` (this report)

No Original or SDK Elyx file was edited. A static raw-byte comparison confirmed
**12/12** `python/sdk/elyx_runtime/*.py` files equal their counterparts under
`third_party/exteraless-android/TMessagesProj/src/main/python/elyx_runtime/`.
Existing source pins are for the coordinator to refresh after integration.

## Actual format traced

The preserved `elyx_runtime/archive.py` discovers root `refmap.yaml`,
`refmap.yml`, then `refmap.json`. Refmap points to `main`, `metainfo`, optional
`strings`/`locales`, `assets`, and a directory of direct `.whl` children.
Metainfo defaults to root YAML/YML/JSON; an explicit pointer can select `.py`.
The same Python mapping reader is used by localization.

`elyx_runtime/metadata.py:58–71` actually executes Python mappings in Original.
The adapter replaces that seam with bounded literal assignment parsing. It
reuses the preserved `build_metadata`, localization, namespace/environment,
BasePlugin construction and outer SDK lifecycle. It does not duplicate the SDK
loader. Test profiles observed the preserved `load_plugin_record` and
`_load_elyx_plugin` bodies executing.

Original requires syntax is `{ "dep_id (min_version)": "optional URL" }`.
SDK normalization produces `{id: {min_version, url}}`; Plugin decoding now
converts this to native `[minVersion?, url?]` values. Existing native arrays also
decode. Inspection does not resolve these URLs.

## Native and owner integration

- `PluginFileFormat` persists `.source`, `.elyx`, or `.eaf`. Legacy persisted
  models infer the format from their path. Archive installation preserves the
  archive extension; source installation retains the existing `.plugin` format.
- Swift bounds the archive copy, re-inspects the exact staged bytes, verifies
  their ID before retiring an existing worker, then performs native replacement.
  The target archive filename uses the existing ID-plus-UTF-8-hex component so
  case-distinct IDs do not alias on iOS. The Plugin ID itself is unchanged.
- Elyx uses its actual `[A-Za-z0-9_]{2,32}` ID grammar, including digit and
  underscore first characters. Source admission retains its original grammar.
  `exteralessMetadataInspector`, case-insensitively, has an explicit reserved-ID
  rejection. Native storage accepts the union of both grammars.
- Bootstrap passes the format to `configure`. Inspector and archive worker
  import paths exclude the shared plugins directory. There is no additional
  Host, process finalization/reinitialization, C-engine or GIL implementation.
- Python captures validated archive bytes once for a load. SDK archive reads
  and materialization use that snapshot, not a second mutable filename read.
  Successful native archive reloads refresh metadata while preserving path,
  format and enabled state.
- Extraction layout is
  `<native getCacheDir>/elyx/<sha256(id + NUL + native owner token)>/`
  `<archive-sha256>-<load-UUID>/contents`, with local wheels under sibling
  `wheels/<wheel-sha256>`. Member SHA-256 values are also computed. Canonical SDK
  names remain `ElyxPlugins.<id>.*`; files and code identities include the
  owner/content-qualified paths.
- Source/member ownership is registered before entry execution. Compatible
  `.pyc` is decoded only during owner/watchdog execution; nested code filenames
  are rebound to the registered member path rather than trusting a build-machine
  or forged filename inside bytecode.
- Every load gets a fresh extraction. There is no completion-marker reuse,
  filename-stem wheel cache, shared reference symlink or swallowed copytree
  fallback. `archive.reference_dir` returns the current owned extraction.
- Archive `file_utils.get_plugin_dir` uses the existing native files directory;
  its owned roots exclude the case-aliasing legacy shared `.data/<id>` location.
- Unload/failure evicts SDK state/modules, forgets member ownership, and removes
  only that load's resources. Callback/lease cleanup still runs in `finally`.
  Swift uninstall synchronously purges only `cache/<native-component>/elyx`
  while holding the existing per-ID mutation reservation. Delayed Python cleanup
  from an old owner cannot sweep a replacement's owner directory.

## Enforced archive/data budgets

| Boundary | Limit |
|---|---:|
| Archive bytes / native archive copy | 32 MiB |
| Expanded outer members **plus** expanded wheel members | 64 MiB |
| Expanded individual member | 16 MiB |
| Outer entries **plus** wheel entries | 2,048 |
| ZIP central directory | 2 MiB |
| Per-member expansion ratio | 200 × max(1, compressed size) |
| Member/refmap path | 512 UTF-8 bytes, 16 components, 255 bytes/component |
| Individual metainfo/refmap/locale mapping | 256 KiB |
| Refmap + metainfo + declared locale files | 2 MiB, at most 64 locale files |
| Rendered metadata JSON / description expansion | 1 MiB (replacement budget checked before joining) |
| Imported JSON/YAML/TXT data module | 1 MiB |
| Mapping/AST or bytecode code graph | depth 32, 16,384 nodes/constants |
| Mapping integer | 1,024 bits |
| Wheel METADATA/WHEEL header file | 256 KiB |
| Wheel Requires-Dist declarations | 128, at most 4,096 characters each |

EOCD and actual central-entry counts are checked before ZipFile can allocate an
unbounded entry list. All entry paths, types, declared sizes and nested-wheel
budgets pass before materialization. Deflate output is capped and checked
against the declared size and CRC, including the forged-size/prefix-CRC case
that ZipExtFile alone can truncate. Description placeholder expansion is also
bounded before allocation, so small locale files cannot produce a metadata
expansion bomb. Absolute/dot/dotdot paths, backslashes,
duplicates, case/Unicode aliases, file-directory collisions, special files and
ZIP symlink/reparse entries are rejected. Filesystem ancestors are checked by
component; extraction does not resolve a whole untrusted path through symlinks.

## Provider and compatibility boundaries

- The configured pinned `ProvidedDependencies` provider checks archive
  requirements and wheel Requires-Dist declarations before entry execution.
  Runtime pip, URL requirements and unsolicited dependency downloads remain
  disabled. Local wheels do not impersonate pinned provided distributions.
- Local pure-Python compatible `none-any` wheels with WHEEL and METADATA are
  admitted as plugin-local code. Native extensions, native binary signatures,
  `.fwork`/framework payloads and native wheel tags are rejected; an app-bundled
  verified native provider is required. `.pth`, wheel `.data` relocation and
  nested wheels have explicit unsupported errors.
- Nonempty Elyx `requires` is inspectable and correctly decoded natively, but
  enabling it reports the precise missing **cross-owner module provider** and
  required IDs. It does not import a neighbouring plugin or fetch its URL.
- Python metainfo/locales support public literal assignments, simple builtin
  annotations and docstrings. Imports, calls and executable statements are
  explicitly unsupported, including at enable time. JSON/YAML data is restricted
  to bounded primitive values; YAML anchors/aliases, merges and nonprimitive tags
  are unsupported. No untrusted Python mapping executes during inspection.
- Supported containers are `.elyx/.eaf` single-disk stored/deflated ZIPs with an
  ordinary EOCD. Generic `.zip`, encrypted/multi-disk containers and other ZIP
  compression methods are not admitted by this route.

## Coordinator patch and native inputs

`elyx-archive-coordinator.patch` contains only:

1. File-picker suffix/types/text and a bounded 32-MiB native archive import copy
   in `PluginManagerController.swift`.
2. The native union ID grammar in `ToolsPluginSchemaCache.settingsFileName`, plus
   a targeted Core filename-codec test. Without this hunk, the existing
   `ExteralessPluginRuntime.settings` call rejects `_archive`/digit-first IDs
   before displaying their settings.

Archive installation needs no `_platform.py` hunk: `__init__.py` connects it
after the existing provider install. `ExteralessPluginRuntime.importPlugin`
already delegates to this Host. No BUILD source-list change is needed:
`prepare_telegram_runtime.copy_assets` copies `exteraless_runtime` recursively,
and `PythonAssets` globs the resulting resources. Shared-file hunks, trust-level
Host stitching and source-pin refresh belong to the coordinator.
When merging the trust-install hunk, use the post-staging `plugin` metadata:
archive re-inspection reassigns it before the old owner is retired. The earlier
caller-supplied `metadata` is retained for the ID check and enabled choice.

For a disposable **existing native fixture Host**, the required inputs are the
modified five Host sources above, `__init__.py`, `_archives.py`, the preserved
SDK, the pinned bundle including PyYAML/packaging, and the existing native
storage/bridge providers. The service root layout must match production:
`plugins/`, `settings/`, `files/<id-hex>/`, `cache/<id-hex>/`. Bind the existing
native callback-owner token before load, as the Host already does.

Generate tiny owned ZIP inputs without importing plugins:

```sh
python3.12 -B tools/compat/tests/test_ios_elyx_archives.py --emit-fixtures "$OWNED_TEMP"
```

Outputs: `owned.elyx` (`7_archive`), `owned-next.elyx` (same ID, changed module
and same-name wheel, version 2.0), `literal.eaf` (`_archive`, Python literal
metadata/locales), `requires.elyx` (explicit unsupported enable), and
`source.plugin` (`source_probe`). The generator prints each input's SHA-256.
It was run successfully here into
`C:\Users\sasha\AppData\Local\Temp\opencode\elyx-archive-handoff-7f11c903`.
These exact Windows-generated ZIP bytes have SHA-256:

| Input | SHA-256 |
|---|---|
| `owned.elyx` | `814cb173c1ccce7629824182effd6bbbbd2d43bc5f2a349db6a6ea06ccabcd3b` |
| `owned-next.elyx` | `5fea7ea543f7311cab945459953be1c7718c8bec7da48a45e7e04425a624d420` |
| `literal.eaf` | `5c901aa2a044532c41f922247dc7c482ba42ff8f98744e8e7df51176e6b756c0` |
| `requires.elyx` | `14e11847f190fbd2c13f49c07096a05383818c7850cece835935cc9f21c74f67` |

Regeneration prints its own byte hashes (ZIP platform attributes can differ).

Mac handoff checks: inspect with zero entry execution; install/enable/settings;
replace/reload and observe changed code/wheel/metadata; disable/re-enable;
uninstall and verify owner cache removal with unrelated cache preserved; ID
codec/case isolation; filesystem-symlink rejection; no neighbor execution or
HTTP on requires. Keep each native child within 30 seconds and use one existing
process Host rather than finalizing/reinitializing CPython for each operation.

The new `PluginArchiveHostTests` exercise actual Swift filesystem/model/owner
logic with an explicitly fake metadata engine; real ZIP/CPython evidence is the
separate native handoff. Relevant Swift targets are PluginArchiveHostTests,
PluginServiceStorageTests, PluginRuntimeProtocolTests,
PythonRuntimeConfigurationTests, and the returned Core codec test.

## Checks actually run in this Windows session

- `py -3.12 -m pytest tools/compat/tests/test_ios_elyx_archives.py -q -s --tb=short`
  — **12 passed, 1 skipped**, 12.38 s; each isolated `-I -S -B` child has a 20-s
  hard timeout. The skipped OS-symlink test needs Windows symlink privilege;
  ZIP symlink-entry rejection ran successfully in the paths case.
- `py -3.12 -m pytest tools/compat/tests/test_ios_runtime.py -q --tb=short`
  — **13 passed**, 13.06 s; each existing child has a 20-s timeout.
- Static raw-byte equality/SHA-256 calculation for all 12 Elyx SDK/Original
  counterparts — passed; no SDK/plugin module execution in that check.
- Scoped `git diff --check` — passed (Git emitted only its CRLF conversion notices).
- `git apply --check docs/wave-2/elyx-archive-coordinator.patch` — passed; the
  shared-file patch was checked without applying it.
- AST parsing of the two Python production entry files and the new fixture
  test, plus owned-source/report trailing-whitespace checks — passed.

Swift is unavailable on this Windows PATH. Native Mac execution, Core patch
tests, iOS picker frames, CI and existing IPA jobs were not run or queried here.

## P1 follow-up — 2026-11-16 (ARCH-01 / ARCH-02 / ARCH-03)

The independent review in
`docs/wave-2/reviews/elyx-archive-source-closure.md` is retained unchanged. Its
four witnesses correctly disproved the earlier filesystem/code-identity closure
claim. The following implementation replaces those vulnerable branches; the
earlier Windows lifecycle receipt is **not** POSIX-FD acceptance evidence.

### ARCH-01: every SDK code path uses the approved execution image

`_Image` captures immutable member bytes, their SHA-256 values and the exact
owner-registered code labels. The SDK namespace finder retains its package,
alias and import rules, but its module-local filesystem predicates now resolve
only this manifest. Both source and sourceless factories create
`_SnapshotLoader`; direct construction of the preserved wrapping loader is
covered too.

`.py` is compiled from captured bytes with `dont_inherit=True`. No source cache
is consulted, including unchecked-hash `__pycache__` members. Compatible explicit
`.pyc` is decoded only on the plugin execution route. Every returned code graph
is bounded and recursively rebound, including code inside nested constant
containers. A separately forged nested filename therefore cannot survive either
route. NFC lookup aliases select the original registered member label, keeping
`co_filename`, `__file__` and audit ownership consistent.

The portable `cached_source` witness still asserts that the unadapted
`SourceFileLoader` reproduces the reviewed forged-nested-filename defect. It then
asserts that the production adapter returns approved source constants and only
owned labels. The POSIX `two_owners` case additionally dispatches the actual
callback and checks ungranted file/network **audit** denial without making a
network request.

### ARCH-02: protected code roots plus byte authority at execution

`_audit_paths.install` installs `ArchiveCodePaths` in every configured owner,
including source-only owners. Its shared native cache layout rules cover other
owners and future archive loads, rather than protecting only the current
interpreter's cache. Code files, pycache paths and archive directory topology
are protected before entry execution. Lexical and resolved aliases, filesystem
case/Unicode aliases, rename/symlink/hardlink operations, relative `dir_fd`
operations, and descriptor writes are checked. Darwin/iOS descriptor lookup uses
`F_GETPATH`; Linux uses the OS `/proc/self/fd` namespace. The original audit and
frame attribution remain active.

Member hashes now have an execution consumer: `image.member` verifies the
captured immutable bytes used by `get_code` and data-module imports. Module
selection, source compilation, explicit bytecode and localization cannot fall
back to current disk content. This is not a check followed by a separate
pathname open. A forced disk mutation in an owned helper witness returns the
captured code, not the replacement. New files absent from the manifest do not
become modules.

Ordinary asset file contents remain filesystem data under the existing owner/
files permission rules; the writer-owner fixture verifies an allowed asset
write as well as denied code/topology changes. Global unsafe mode and the
general same-process trusted/native capability boundary remain the SDK's
existing rules; execution through this archive route still uses its captured
image.

### ARCH-03: real held descriptors and inode receipts

Python materialization now uses `_Directory` / `_Extraction`:

- Open the actual OS `/` anchor; pin documented Darwin `/var`, `/tmp`, `/etc`
  aliases and walk their fixed `/private` targets without following any
  untrusted descendant.
- Hold the full directory chain, compare `fstat`/nofollow `fstatat` identities,
  and use fd-relative mkdir/open/stat/unlink/rmdir. File creation is exclusive
  and nofollow. No extraction or recursive cleanup reopens a whole target path.
- Retain the load-root descriptor and original entry receipts through unload.
  Cleanup rejects changed directory bindings and replacement file inodes;
  root replacement cannot redirect it to an outside tree. Receipt comparisons
  account for filesystem Unicode/case aliases.
- Close the held descriptor pool on every success/failure path. Cleanup is
  bounded to 36,864 entries and depth 20; the existing 64-MiB ZIP budget remains.

Native `PluginArchiveStorage.swift` supplies `PluginArchiveCacheLease` and the
equivalent Darwin/Glibc descriptor operations. Capture records existing owner/
load generations and file inodes. Purge removes only those receipts, retains
new/unrecorded generations, and rejects replacements. Symbolic links are never
followed during descent or removal. Raw OS-root aliases are handled explicitly.

**Required coordinator caller hunk:**
`docs/wave-2/elyx-archive-fd-host.patch` captures the lease inside the existing
Host mutation reservation **before** the unloading await, then purges that same
lease afterwards. It preserves the trust owner's permission removal flow.
`PluginHost.swift` and lower `PluginModel.swift` were not edited in this follow-up.
`testUninstallPurgeCapturesBeforeItsUnloadingAwait` pins this caller ordering.
The new Swift helper is already covered by the existing PluginHost source glob.

Windows archive execution/materialization now raises an explicit unsupported
POSIX-FD-backend error. Metadata inspection and source workers still operate;
there is no racy Windows extraction/purge fallback. Positive FD/lifecycle tests
are skipped explicitly on Windows, rather than using source-only doubles as FD
evidence.

### Follow-up owned files

- Production: `python/exteraless_runtime/_archives.py`,
  `python/exteraless_runtime/_audit_paths.py`,
  `swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift`, and new
  `swift/PluginHost/Sources/PluginHost/PluginArchiveStorage.swift`.
- Tests: `tools/compat/tests/test_ios_elyx_archives.py`, new
  `tools/compat/tests/test_ios_elyx_p1.py`,
  `swift/PluginHost/Tests/PluginHostTests/PluginArchiveHostTests.swift`, and new
  `swift/PluginHost/Tests/PluginHostTests/PluginArchiveDescriptorTests.swift`.
- Handoff: `docs/wave-2/elyx-archive-fd-host.patch`, this appended report, and
  `docs/wave-2/elyx-archive-p1-inputs.json` (exact input hashes).

The already applied UI/Core format hunks need no further edit. Shared
`_platform.py`, reflection/developer/hooks, Host send-priority, trust changes,
callbacks/C-owner tokens, C engine/GIL and SDK/Original sources are preserved.

### Follow-up checks and remaining execution handoff

Actually run:

```text
py -3.12 -m pytest tools/compat/tests/test_ios_elyx_p1.py tools/compat/tests/test_ios_elyx_archives.py tools/compat/tests/test_ios_runtime.py -q --tb=short
20 passed, 15 skipped in 16.17s
```

Each outer owned Python child has a hard 20-second timeout; the two-owner peer
has a 10-second timeout. The Windows passes comprise four P1 portable cases,
three bounded archive-inspection cases and 13 source-runtime cases. The 15
skips are explicitly positive POSIX archive/FD scenarios. Static comparison
confirmed **36/36 SDK Python files, including 12/12 Elyx files, byte-identical**
to Original. `git apply --check elyx-archive-fd-host.patch` passed without
applying the Host hunk.

The P1 suite provides real POSIX extraction-parent swap, cleanup-parent swap,
replacement-inode, raw OS alias and two-owner filesystem tests. Swift descriptor
tests additionally cover swaps during capture, after capture and immediately
before unlink, uncaptured generations/files, replacement inodes, raw aliases and
the Host capture-before-await route. Their assertions preserve the outside and
replacement resources, not merely an error string.

Local WSL, Docker/Podman and Swift are unavailable. **Positive Linux/macOS FD
execution and Swift compilation remain pending coordinator execution**, with
each native child capped at 30 seconds. No CI, network, foreign archive/plugin,
account, commit or push operation was performed here. The review findings are
not marked native-closed by these Windows results.

### Required native developer-source join — implemented Python side

The coordinator's 14 native routing/retention hunks are preserved. The three
requested hooks now have concrete implementations in `_archives.py`:

- `ArchiveAdapter.developer_manifest(expected_source_digest=...)` claims a fresh
  native **installed-source** receipt, reads/checks its exact bytes and returns
  the outer ZIP file hash map. It does not walk extraction or trust the active
  adapter's cached `snapshot`.
- `inspect_developer_descriptor(descriptor)` claims a native inspection receipt,
  performs bounded static inspection of its read-only FD bytes, checks its native
  namespace/version again and releases the ticket. It returns metadata only.
- `verified_developer_load(platform, path, descriptor)` holds a fresh-owner
  native read ticket through the existing `load_json` call. `__init__.py` now
  selects `snapshot_for_load`, which consumes those immutable verified bytes
  exactly once. The pathname is only a code/installation label and is not
  reopened. This joins the already applied `_elyx_developer.load_verified_json`
  wrapper and native completion retention.

**Exact ABI:** `docs/wave-2/elyx-source-descriptor-v1.json`. The 4096-byte envelope
contains ABI/schema, opaque one-shot capability, purpose, plugin ID, owner token,
format, source SHA-256/length and native namespace/version nonces. **No raw fd or
pathname grants authority.** The native registry retains the actual read-only
FDs and returns independently pinned 64-KiB reads through opaque tickets; Python
validates the received length/hash and native proof before/after inspection/load.
Replacing a path or recycling a descriptor cannot retarget a native ticket.

The native developer owner must implement/register this exact ABI in
`PluginElyxDeveloperFiles.swift`, including namespace/ctime/inode/ABA checks,
current native invocation/purpose/owner validation, one-shot claims, load-reader
readiness and actual-completion cleanup. A manifest ticket refers to the live
native `Source.open(target)` receipt; an ambiguous same-owner/digest receipt is
an error, not permission to guess a pathname/version.

**Minimal native gate join, not applied by this owner:**
`docs/wave-2/elyx-source-capability-coordinator.patch` adds the read-only
`_exteraless_bridge.xt_elyx_source` entry and
`BridgeServices.elyxSourceDispatcher`. C injects the existing immutable owner;
only an unconfigured metadata interpreter gets `@elyx-inspection`. The native
registry validates that context and its own issued capabilities. No owner-state,
handle realm, GIL, engine or callback lifecycle is redesigned. The gate uses the
existing retained native dispatcher, not the Python-mutable legacy service
registry. A missing built-in gate or native registry fails explicitly.

The Python adapter does not use envelope fields, `read_only=true`, Python module
state or a fixture factory as authorization. They are decoder checks on a
native-gated result; native issuance/custody is mandatory. The built-in transport
is captured before plugin entry. Inspectors contain no untrusted plugin code.

The new owned `test_ios_elyx_source_authority.py` exercises those hooks with an
explicit **FD-backed contract recorder**, not a production native authority.
It checks zero-execution static Python metadata, invalid/bare-fd rejection,
native refusal, source mutation, fresh manifest bytes despite a poisoned cached
snapshot, ticket release/replay and a verified context whose pathname is absent
and forbidden to reopen. POSIX-only cases add replacement with a live read FD
and the actual verified SDK load wrapper.

Final local joined check:

```text
py -3.12 -m pytest tools/compat/tests/test_ios_elyx_source_authority.py tools/compat/tests/test_ios_elyx_p1.py tools/compat/tests/test_ios_elyx_archives.py tools/compat/tests/test_ios_runtime.py -q --tb=short
25 passed, 17 skipped in 17.27s

py -3.12 -m pytest tools/compat/tests/test_native_elyx_developer.py -q -k "state and unit" --tb=short
3 passed, 9 deselected in 2.24s
```

The 17 skips remain explicit POSIX/FD positives, not passing emulations.
Both new coordinator patches pass `git apply --check`. Actual C-gate/native
registry execution, Swift compilation, native verified publication and POSIX
acceptance remain coordinator handoffs. The ready-input hash file records this
joined Python/FD source set; the native provider is not falsely reported ready.

## P2-01 follow-up — Darwin-family selection (2026-11-16)

Fixed all three Python selectors to accept exactly `sys.platform in
("darwin", "ios")`: descriptor `F_GETPATH`, lexical OS-root aliases and the
held-directory walk's qualified OS-root alias branch. The embedded BeeWare
CPython platform value `ios` is a Darwin-family value, not a Linux `/proc`
fallback. Linux selection, literal alias targets, descendant nofollow checks,
FD custody/cleanup and the source-reader ABI are otherwise unchanged.

Production edits are limited to `_archives.py` and `_audit_paths.py`. The new
`tools/compat/tests/test_ios_elyx_platform.py` covers macOS `darwin`, iOS `ios`,
Linux, F_GETPATH failure without Linux fallback, the `/var`/`tmp`/`etc` target
allowlist and negative aliases. Portable selection cases use counted stand-ins
plus actual owned-file reads; they do **not** claim iOS/Darwin syscall execution.
The separate POSIX case uses actual descriptors, a raw OS path and an actual
rejected descendant symlink on its executing OS.

Actually run: `py -3.12 -m pytest tools/compat/tests/test_ios_elyx_platform.py -q
--tb=short` — **4 passed, 1 POSIX skip**, 1.20 s on Windows. SDK/Original raw-byte
comparison remains **36/36 identical**. The small returned
`docs/wave-2/elyx-ios-fd-probe-coordinator.patch` passed `git apply --check` and
was not applied here. It adds an exercise to the existing source SDK fixture:
real embedded platform, owned asset-FD write, denied code-FD and code-dir_fd
writes from the plugin frame, actual F_GETPATH, raw native-cache OS alias and
negative descendant link. It records `actual_ios_fd_paths` only on an actual
`ios` run; no provider/tooling rewrite or additional Host is introduced.

Coordinator-reported history is preserved separately: Linux POSIX run
`43768124344` / `ff913492` had **42 passed, 0 skipped**, including all 17 former
Windows skips and a fresh C build. That receipt predates these platform-selector
edits and is not an iOS selector receipt. The C/Swift capability gate and Host
cache-capture patches are coordinator-applied; registry work remains with the
native developer owner. This follow-up queried no CI and changes no native FD
provider, callback/GC lifetime or source-custody rules. Exact new inputs are in
`docs/wave-2/elyx-archive-p2-inputs.json`.

## NFD-02 follow-up — pre-publication load-policy admission (2026-11-16)

`inspect_developer_descriptor` now requires **known load-policy admission** before
returning metadata. It uses the same side-effect-free `_preflight_load_policy`
as `ArchiveAdapter._load_record`. The record loader retains its check before
delegating to the Original SDK entry pipeline.

The shared check rejects nonempty cross-plugin `requires`, incompatible local
wheel `Requires-Python` against the current interpreter, and invalid Python
version specifiers with a precise error. It also applies the existing approved
dependency/version/marker resolver to archive requirements and wheel
Requires-Dist. It does not execute plugin/module/mapping code, look up neighbors,
install packages, access the network or grant permissions. FD inspection obtains
an explicit policy-metadata snapshot from the existing read-only bundled
`ProvidedDependencies` provider; the validator itself neither discovers providers
nor restores import paths. Load supplies its existing configured provider.

**Hook semantic change for the native developer owner:** the existing opaque-FD
`inspect_fd_json` / `inspect_developer_descriptor` result is now a candidate
preflight result, not merely a metadata parse. Either reviewed witness fails
before successful return, while the reader is still scoped and is released by
its existing `finally`. Thus native `prepare` must refuse the candidate before
Host retirement/publication. No descriptor ABI or native provider edit is needed.

Ordinary `metadata_json` / `_inspect_archive_bytes` previews retain their previous
semantics: valid archives with `requires` or unsatisfied version requirements can
still be displayed. The fourth native archive child's `inspectInstall` uses
`readPluginMetadata` and normal disabled installation, so its
`requires.elyx` preview-then-enable-refusal remains valid. NFD-01/NFD-03 native
cleanup/publication-outcome changes are untouched.

Only production `_archives.py` and its owned
`test_ios_elyx_source_authority.py` test were edited. The three new bounded cases
exercise the actual opaque-FD hook using the explicitly identified FD contract
recorder: nonempty/empty requires, `>=99`, invalid `>>>3`, a compatible wheel,
native `.so` rejection, provided/mismatched/missing/URL dependencies. They assert
reader release, unchanged installed/old-owner receipt bytes, no stage/publication
operation, no entry or wheel-module import, no pathname fallback, and identical
load-time refusal before Original delegation. Positive cases use the real shared
version/dependency checks, not a success stub.

Actually run on Windows CPython 3.12 (20-second limit per child):

- `pytest tools/compat/tests/test_ios_elyx_source_authority.py -q -k load_policy`
  via `py -3.12 -m` — **3 passed, 7 deselected**, 2.09 s.
- `py -3.12 -m pytest tools/compat/tests/test_ios_elyx_source_authority.py tools/compat/tests/test_ios_elyx_platform.py -q --tb=short`
  — **12 passed, 3 explicit POSIX skips**, 4.30 s.
- Owned AST/whitespace checks and **36/36 SDK/Original byte equality** passed.
  `_audit_paths.py` still matches its P2 pin, and the `darwin`/`ios` selector in
  `_archives.py` is preserved.

No CI, native provider, native account, publication, commit or network operation
was run here. The two exact source/test hashes are sealed in
`docs/wave-2/elyx-nfd02-inputs.json` for the coordinator's next execution.
