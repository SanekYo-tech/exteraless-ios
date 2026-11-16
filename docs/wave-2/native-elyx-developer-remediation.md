# Native Elyx developer commands — applied startup and NFD remediation

Receipt updated **2026-11-16**.

## Status

**APPLIED in the shared production sources:** Runtime now calls the public
`PluginHost.activateElyxDeveloper(scope:isCurrent:)` path, which installs its native
registry, verifies readiness and constructs the FD provider. NFD-01 cleanup and
NFD-03 publication-outcome propagation are corrected. The fifth native child and
the coordinator-only executable/Tooling hunks are delivered below.

**Native compilation/execution is pending coordinator execution.** Current local
checks are recorded in [Applied closure and final handoff](#applied-closure-and-final-handoff).
The final raw-byte postimages are in
[`native-elyx-developer-final-inputs.json`](native-elyx-developer-final-inputs.json).
Earlier factory instructions, provisional layouts, pins and test receipts in this
development record are historical; they do not certify the final native sources.

This follows the steering about forged bytecode filenames, mutable code cache and
parent-swap races. The new path has **no fallback** to mutable extraction trees,
`ArchiveAdapter.snapshot`, path-only extraction/cleanup helpers or local Python
reload. The archive owner's `_archives.py`, `_audit_paths.py` and runtime
`__init__.py` were not edited here.

Starting review:
[`reviews/sdk-symbol-remediation-source-closure.md`](reviews/sdk-symbol-remediation-source-closure.md),
especially lines 275–299. It source-closes the earlier Python argument mismatch
but correctly finds the native handler's missing Elyx switch route.
[`elyx-archive-remediation.md`](elyx-archive-remediation.md) establishes the
format-preserving Host pipeline; its subsequent P1 fixes are separately owned.

## Ready files

| File | Responsibility |
|---|---|
| `python/exteraless_runtime/_elyx_developer.py` | Original ping/list on the captured owner; verified-manifest, FD-inspection and fresh-owner-load adapter hooks; direct Python `elyx_changes` refusal. |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperRequest.swift` | Closed Original command/parameter schema, normalized relative paths, payload budgets and structured failures. |
| `swift/PluginHost/Sources/PluginHost/PluginElyxArchiveCandidate.swift` | Native ZIP transformation; unchanged compressed bodies preserved, changed bodies stored, directory/file create/delete/move semantics. No filesystem effects. |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperTransaction.swift` | Captured target/consent values, command orchestration and explicit FD-authority/descriptor lease contracts. |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginElyxDeveloperIngress.swift` | Authenticated-ingress plan, credential stripping, account/session/deadline checks and response conversion. |
| `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperTests.swift` | Native request/ZIP/transaction tests, actual Host owner turnover with a canned engine, explicit file-authority recorders. |
| `telegram-ios/submodules/TelegramUI/Tests/PluginElyxDeveloperProtocolTests.swift` | Actual protocol auth, error-status preservation and session revocation assertions. |
| `tools/compat/tests/test_native_elyx_developer.py` | Bounded Original SDK state/C-script fixtures and owned archive/command emitter. |
| `tools/compat/tests/test_native_elyx_candidate.py`, `fixtures/native_elyx/` | Darwin Swift candidate executable followed by independent Python ZIP/CRC/body checks. |

The earlier three proxy/developer corrections are preserved. Original SDK and
third-party sources are inputs, not forked implementations.

## Shared-file patch — coordinator only

[`native-elyx-developer-coordinator.patch`](native-elyx-developer-coordinator.patch)
uses OpenCode's `*** Begin Patch` format. It was **not applied here**. Its hunks:

1. Install `_elyx_developer` after `_developer` in `_platform.py`, without starting
   a server or inspecting/executing a plugin.
2. Preserve an action payload's `ok=false` in `PluginDeveloperProtocol.response`.
   The current line 55 overwrites every successful handler return with `ok=true`;
   that would otherwise turn a failed reload into a successful wire response.
   Request `#` remains the outer protocol's value.
3. Add the Elyx branch at the beginning of `handleDeveloperRequest`, **before its
   first await**. Capture Host, account index, target IDs/owners, native consent
   snapshots and native manager store. Root account/context identity is checked
   again on delivery; the existing session is revoked by account/mode changes.
4. Add Host's native-only capture/read/FD-inspection/publication methods. Reads
   enter `invokePlugin(expectedHandle:, shouldExecute:)`, retaining the actual
   immutable C owner epoch and existing worker/watchdog machinery.
5. Carry an optional verified descriptor into the existing Host `loadPlugin`.
   The native Host retires the old owner, atomically publishes archive bytes via
   the FD authority, persists the existing Plugin model and creates a new owner.
   A verified descriptor is retained through `PluginInvocationRetention` until
   **actual native execution finishes**, including cancellation/abandon tails.
   Inspector descriptors likewise remain captured by `onExecutionFinished`.
6. Include the new protocol assertions in the existing native UI test source list.

The patch does not copy entire shared files. An in-memory hunk projection checked
that the contexts matched uniquely; shared trust-level work must be stitched by
the coordinator. Native source inclusion/patch projection is not compilation.

`elyxDeveloperFiles` is an optional native Root dependency. Its initial nil value
is intentional. No fabricated file authority is installed, and no manager bridge
method is exported to Python. The existing TelegramUI Swift source glob and
recursive runtime packaging include the new helper files.

## Original wire semantics and native route

Read bodies: `python/sdk/elyx_runtime/dev_commands.py:81–128,131–247`.

| Original request | New behavior | Current integration gate |
|---|---|---|
| `{"@":"elyx_ping"}` | Original `handle_dev_command("elyx_ping", {})` on a captured archive worker. With no loaded archive, use the existing data-only metadata-inspector worker. Return actual SDK version. | Shared Host/Root/install hunks and native compile. |
| `{"@":"get_elyx_plugins"}` | Capture the loaded/enabled native archive owners first; bounded sequential owner reads call the Original list handler. Revalidate the entire captured set before returning `plugins`. An empty set returns `[]`. | Same routing hunks; no extraction or file-authority fallback. |
| `{"@":"elyx_compare_folder","plugin_id":id,"hashes":{path:sha}}` | Compare client hashes to the **verified installed-source manifest**; same sorted `created_or_modified` and `deleted` result fields. Missing/null hashes mean `{}`. | Requires the reviewed FD authority and `developer_manifest` hook below. |
| `{"@":"elyx_changes","plugin_id":id,"changes":[...]}` | Validate all entries; construct a bounded ZIP candidate in native memory; statically inspect its FD; preserve native path, `.elyx/.eaf`, enabled state and consent; publish and reload through Host. | Requires all FD/verified-load hooks below. No publication on a missing provider. |

Changes accept Original `#` or `type` event names: `created`, `modified`,
`deleted`, `moved`. Conflicting names fail. Created/modified files overwrite or
create, with missing/null content meaning empty bytes. Directories have no body.
Deletion of an absent path is a no-op. Moves infer files/directories from the
source image, support empty directories and replace existing files, but reject
nonempty directory replacement, moving into itself and file/directory collisions.
New directory parents are implicit. Backslash separators normalize to `/`.

The native ZIP code retains unchanged stored/deflated bodies, CRC/size and method,
rewrites names/headers in UTF-8, and supports legacy CP437 input names. Full
inflation/CRC, Python metadata restrictions, matching bytecode and pure-Python
wheel checks remain the archive authority's static inspection obligation.
No runtime pip/download or debugpy implementation is introduced.

This intentionally treats installation bytes as source, not plugin-produced
extraction/cache files. Updating extraction and reloading an unchanged ZIP would
lose code/resources; the new transaction never takes that route.

## Authority and final guards

- Authentication stays at `PluginDeveloperProtocol.request` and
  `PluginDeveloperServer.process`. `elyx_ping` is authenticated; only plain
  protocol `ping` is free. Top-level `token` and `#` are removed before building
  a typed invocation. The socket credential is never an SDK argument/result.
- Each target retains the exact `CallbackOwner`, persisted model projection and
  `PluginPermissionSnapshot` including its revision. A replacement or an
  A→B→A consent edit cannot retarget the pending request.
- Runtime supplies the existing `PluginDeveloperSession`, a locked native
  manager-state predicate, captured account index and final MainActor
  account/context/Host check. Native reads recheck the same owner before worker
  entry and after return. The native operation has a 20-second admission/deadline
  predicate; worker read timeout is capped by its remaining time.
- Publication holds Host's existing per-ID mutation reservation. Only its own
  successful retirement permits the old callback owner to disappear. Final
  checks still require the same installed model, consent, source/namespace
  version, candidate and active session. Permission metadata never grants a new
  trust level or permission.
- After publication, the existing Host load receives a **new owner-bound verified
  descriptor** and checks it on that worker. The returned `reloaded=true` requires
  a loaded, error-free Plugin and a genuinely different current native owner.
  Late replacement/consent/source/session changes reject result delivery.
- `dev_server.dispatch` retains its original local token check. Direct
  `elyx_changes` now returns an explicit error and `reloaded=false`; it cannot
  call Original `_reload_loaded_plugin`, publish an archive or create an
  untracked generation. `load_verified_json` also refuses an already active SDK
  generation; descriptor authority remains native, not that Python check.

Malformed parameters and stale owner/session/consent before staging cause no
staging/publication call. Private staging may have occurred before a later
revocation; its cleanup must be FD-relative to that lease. Installed source and
model publication must remain zero on pre-commit refusal. A load failure after
an admitted atomic publication is reported as a failure, not an invented rollback
or a successful reload.

## Exact archive-owner / coordinator integration needs (blocking)

These are **handoff contracts**, not claims that implementations already exist.
Names may be mapped by the coordinator to the archive owner's reviewed API; do
not implement them by reading the retired path/cache helpers.

### Python hooks

1. `ArchiveAdapter.developer_manifest(*, expected_source_digest)` returns exactly
   `{"source_digest": sha256, "files": {relative_file: sha256}}` (directories
   excluded). It must use the active load's immutable **verified source-byte/FD
   authority**, validate its owner and native source namespace/version, including
   replacement/ABA, and reject a digest different from the captured native lease.
   Mutable `snapshot`, cached `.pyc` filenames or walking `extract_dir` is not a
   conforming implementation.
2. `_archives.inspect_developer_descriptor(descriptor)` runs full bounded static
   archive inspection on an issued read-only descriptor. It returns the existing
   metadata shape, with no Python mapping execution, entry execution or cache
   mutation. The Host method `inspectElyxDeveloperDescriptor` supplies its
   data-only inspector and retains the descriptor until the native read finishes.
3. `_archives.verified_developer_load(platform, path, descriptor)` is a context
   manager which binds/consumes the new owner's descriptor and pins its inspected
   bytes throughout the existing `load_json`/Original SDK pipeline. It must not
   reopen a mutable filename or trust cache code. The shim calls the existing
   `load_json` only inside this context on a fresh Host-created owner.

Descriptor envelopes are bounded to **4096 UTF-8 bytes**. Their concrete native
capability/FD layout is still to be agreed with the archive owner. Requirements:
native issuance, scope/purpose/owner validation, bounded regular-file input,
source digest and namespace identity, one invocation's authority, no listener
credential and no bare pathname as authority. Readers need independent retained
FD lifetimes; cancellation must not close/reuse an FD still used by an abandoned
native invocation.

Absent hooks raise the exact named `UnsupportedSurfaceError`. The new shim has
no compatible-looking success fallback.

### Native file authority

Implement and install `PluginElyxDeveloperFileAuthority` in Root only after the
above verified-byte APIs are usable. Its protocols are in
`PluginElyxDeveloperTransaction.swift`:

- `open(target)` anchors the native installation namespace and source descriptor;
  returns immutable archive bytes, SHA-256 and a revocable source/version lease.
- `source.checkCurrent()` checks descriptor/namespace/source version, not merely
  lexical path equality. It checks file custody rather than re-looking-up an old
  callback owner which Host intentionally retires under its reservation.
- `source.prepare(candidate, shouldExecute:)` privately stages via anchored
  directory FDs; invokes full static FD inspection; validates identity/format and
  **verified-load API readiness before old-owner retirement**. All error cleanup
  is FD-relative and bounded. No installed source/model/extraction write.
- `prepared.publish(shouldExecute:)` performs the final predicate plus native
  namespace/source-version CAS and atomic byte publication. It cannot publish
  by following a freshly resolved pathname. `checkPublished()` proves the exact
  installed candidate for native load and result delivery.
- `prepared.loadSource(newOwner)` issues the distinct retained verified-load
  descriptor. Host uses existing `PluginInvocationRetention` to keep it alive
  until the actual C/worker completion, not just an async waiter's cancellation.

This provider and concrete descriptor contract are the **remaining functional
gate**. With `elyxDeveloperFiles == nil`, compare/changes return
`ServiceUnavailable: FD-backed Elyx developer file authority is not installed`
before any source read, stage or publication. No unsafe path-only provider is
installed just to make this check green.

## Bounds

| Boundary | Limit |
|---|---:|
| Native line/request | 512 KiB |
| Change entries / decoded changed contents | 128 / 256 KiB aggregate |
| Hashes / archive entries | 2048 |
| Relative path / components | 512 UTF-8 bytes / 16 |
| Input/output ZIP | 32 MiB each |
| Outer expanded members / individual member / central directory | 64 MiB / 16 MiB / 2 MiB |
| Expansion ratio | 200× |
| Worker snapshot JSON / external reply | 2 MiB / native line budget with 2048 bytes reserved for framing |
| Captured target set | 64 (normal Host interpreter limit is lower) |
| Descriptor JSON | 4096 bytes |

The archive provider must also enforce its aggregate expanded **wheel** budgets,
mapping/AST/code-graph restrictions and reviewed code-source policy. Native ZIP
transformation alone does not certify those properties.

## Verification receipts and limits

**Windows CPython 3.14.8:** the new SDK suite passed **6 tests**, with **6 POSIX
archive-execution cases skipped**, in **6.17 s**. Each child is `-I -S -B` with a
20-second timeout and an owned root under the approved OpenCode temp directory.

Final combined check with the five earlier proxy/developer regressions and the
native candidate platform gate: **11 passed, 7 skipped in 11.00 s**. The seventh
skip is the Darwin Swift candidate executable. **36/36 SDK/Original Python files
remain byte-identical**. All 14 coordinator hunk contexts matched uniquely in an
in-memory projection; no shared-file patch was applied.

- State fixtures use a real source-loaded own SDK owner plus the **actual**
  `ElyxPluginState` type for an in-memory read-model fixture. They do not bypass
  the new POSIX gate or claim archive extraction/native publication execution.
- Actual Original `handle_dev_command` runs for ping/list, with string name and
  separate params under captured account 3. Wrong IDs/epochs/accounts and direct
  mutations are rejected. Read/refusal snapshots observed **zero filesystem
  writes**, and unload left zero handles.
- C variants use the already-built current bridge at
  `sdk-tl-self-bridge-py314/_exteraless_bridge.cp314-win_amd64.pyd` under OpenCode
  temp. The real C dispatcher/immutable owner binding executed **38/42/37** native
  recorder calls for read/manifest/refusal, each with eight bootstrap denials.
  Host-script expressions execute in CPython; native service bodies are explicit
  recorders. This is not a Swift engine or production FD-provider receipt.
- The first six archive attempts failed precisely at
  `Elyx extraction requires the POSIX directory-FD/O_NOFOLLOW backend`, before
  plugin entry. The suite now labels those cases POSIX-only instead of weakening
  the archive owner's new gate. Manifest/descriptor providers in state tests are
  explicitly contract recorders; missing-provider refusal is also exercised.

Prepared but **not run here** (Swift is absent on this Windows PATH):

- `PluginElyxDeveloperTests`: seven native tests for requests, ZIP semantics,
  missing authority, owner replacement, source-version checks, session/consent
  revocation and a real Host owner turnover with a canned metadata engine.
  Its file authority changes only memory and explicitly has no verified-load FD
  implementation. It is not a security/FS acceptance substitute.
- Three native UI protocol tests, including the real `ok=false` framing regression.
- `test_native_elyx_candidate.py`: builds the local Swift package (120 s compile),
  runs the actual native candidate transform (10 s), then independently checks
  CRC, code/resource bodies, deletion/move and unchanged compression via zipfile.
  This fixture writes only its own candidate, not an installed application archive.
- The earlier native loopback fixture remains available with the coordinator's
  **120 s compile / 10 s execution** budgets. New production FD/native Host
  publication and account/session scenarios still require the joined provider.

Owned native fixture input generation:

```text
python -B tools/compat/tests/test_native_elyx_developer.py --emit-fixtures OWNED_TEMP
python3 -B -m pytest tools/compat/tests/test_native_elyx_candidate.py -q -s
swift test --package-path swift/PluginHost --filter PluginElyxDeveloperTests
```

The generated `owned.elyx` is the existing archive fixture with one unused
`obsolete.txt`. `changes.json` modifies actual helper code and an asset, creates
and moves a directory, and removes only the unused file. The import-required
`note.txt` remains present for a subsequent real archive load.

The emitter ran into
`C:\Users\sasha\AppData\Local\Temp\opencode\native-elyx-fixtures-e766c109`.
Its ZIP SHA-256 is
`afc2926b82e8990b519f76728a3518930464e27c71256a0b7c3fc63cc4cfd2c3`.
The CP437 table was independently compared with Python's codec: **128/128**
high-byte characters match. Python syntax and authored-source whitespace checks
passed; neither check constitutes Swift compilation.

### Authored implementation pins (raw SHA-256)

```text
a2b999fb1113249c557a5c9fb90e57476b06bac05b597b9bbebb3e688e926690 python/exteraless_runtime/_elyx_developer.py
82f9655ccd392d4b76cd6df46e547d8d9e1b494a03e5256994f05be7b5e85eca swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperRequest.swift
adebf1552551bbc7faa826821596dfec50fbcded9ed59cc369da6613e8029e21 swift/PluginHost/Sources/PluginHost/PluginElyxArchiveCandidate.swift
ed22be0fe9deb8abb60d5614dc29ad96c1a40f4f4b59425654a6fd5d26b650d4 swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperTransaction.swift
db83737d655fc22e84e5b00341ba7a9dc1ab632ca43a65a068b8eb61de49050f telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginElyxDeveloperIngress.swift
edd3b7cee14c52840aa9017d5c433d2a4830d6078496c83a064850f0e219f9fc docs/wave-2/native-elyx-developer-coordinator.patch
bbaab67105779fc7c458069fc9b3a15a7ca6e09e074af285f9f56e0ad02bc133 tools/compat/tests/test_native_elyx_developer.py
aa40823e5de9608f36c3a7c25dfdc261f819da37adc258d818b13b35555a63e8 existing sdk-tl-self-bridge-py314 C extension
```

No CI/app status, accounts, external HTTP, commits or pushes were used. No
progress polling of the archive/trust owners was performed. Their source and
native execution closure remains their own/coordinator review task.

## 2026-11-16 continuation — concrete native file authority implemented

This section supersedes the earlier **missing file-engine implementation** status.
The earlier **11 passed / 7 skipped** receipt remains historical; it is not a
receipt for these new native filesystem operations.

### New implementation and ownership

- `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperFiles.swift` now supplies
  the real `PluginElyxDeveloperFiles: PluginElyxDeveloperFileAuthority`.
- `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift` supplies
  the native issuance registry, non-serializable execution contexts, descriptor
  leases, C-verifier entry, mandatory bridge/readiness adapter and native SHA-256.
- `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift` adds
  **17** tests using real native filesystem operations and the actual registry.
  Only the inspector/CPython engine is a stated fixture: it reads fixture JSON
  through the actual resolved read-only fd, not an in-memory file-engine mock.
- `tools/compat/tests/test_native_elyx_files.py` builds that local native package
  with a **120 s compile** budget, then caps its actual test process at **30 s**.
- [`native-elyx-developer-files-root.patch`](native-elyx-developer-files-root.patch)
  contains the Root factory and native worker TLS join. It is **not applied here**.

No direct changes were made to `_archives.py`, `_audit_paths.py`, runtime
`__init__.py`, `PluginArchiveStorage.swift`, shared Host or Runtime. Storage's
current helpers were read: its held-directory implementation is private to that
file, so the provider has its own narrowly scoped FD custody code rather than
rewriting Storage or using its old path-only operations.

### Actual filesystem sequence

1. **Native construction** requires a concrete readiness receipt for the same
   registry, ABI 1 and all three hooks. There are no default success closures.
   Open `/`, walk each directory with `openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`,
   compare pre-open entry identity with `fstat`, and retain the chain. The only
   alias exception is the actual Darwin OS-root `var/tmp/etc` symlink with the
   exact fixed `private/<name>` target; the alias inode/target is pinned. No broad
   Foundation `resolvingSymlinksInPath` is used.
2. **Source capture** accepts only the real native archive installation slot:
   `PluginServiceStorage.component(id) + .elyx/.eaf`, with the actual ASCII archive
   ID grammar, matching captured native owner/model/consent. It opens the regular,
   singly-linked source `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC`; captures
   device/inode/mode/link count/size/mtime/ctime; reads with bounded `pread`; hashes
   exact bytes; and rechecks both FD and directory entry. Source images and staged
   candidates remain limited to 32 MiB each.
3. **Namespace versions** combine held inode bindings, installation-directory
   metadata, an in-process operation nonce, and continuous kernel namespace-self
   observation: Darwin `EVFILT_VNODE` rename/delete/revoke, Linux inotify
   move-self/delete-self/unmount/overflow. Linux binds watches to the already held
   inode through `/proc/self/fd/<native-fd>`; this is a kernel fd link, not a caller
   symlink fallback. Notifications are drained synchronously; no listener/polling
   thread is created. Rename-away-and-back permanently retires the lease.
   Ordinary Host writes to ancestor `plugins.json` do not falsely revoke it.
4. **Preparation** creates a unique mode-0700 operation directory under the native
   sibling `.elyx-developer-staging`, not under an archive's cache/extraction.
   The candidate is created with `openat(O_EXCL|O_NOFOLLOW)`, bounded writes,
   `fchmod(0400)`, `fsync`, and a separate read-only open with fstat identity/content
   checks. The writer closes before inspection. The exact candidate is issued as
   an inspection descriptor. Full static ZIP/metadata/bytecode/wheel validation
   stays in the concrete inspector; success without native descriptor consumption
   is rejected. After await, owner, consent, source, namespace, candidate, bridge
   registration epoch and metadata ID/format/engine are checked again.
5. **Publication** runs under the Host mutation reservation and provider lock.
   After the final predicate and FD/version checks, Darwin `RENAME_SWAP` or Linux
   `renameat2(RENAME_EXCHANGE)` atomically exchanges the candidate and installation
   entry through their held parent FDs. Both actual resulting inodes, versions and
   byte hashes are verified, including the displaced source. Directory fsync and
   namespace verification precede a successful receipt. The prior source and any
   older prepared operations are retired by the new native operation nonce.
6. **Failure outcomes** are explicit: `refused`, `rolledBack`, `committed`, or
   `recoveryRequired`, with `sourceChanged` false/false/true/unknown respectively.
   A pre-confirmation race is exchanged back only while both captured slots still
   match. A replaced rollback slot is retained for recovery, never overwritten.
   A confirmed byte publication followed by durability failure is not reported as
   no-write, rollback, or successful reload. A second `publish()` cannot invalidate
   a previously valid published receipt.
7. **Cleanup** is FD-relative and nonrecursive. Only an operation's captured inode
   is moved to a unique no-replace quarantine and rechecked before unlink; unknown
   or replaced/nonempty entries are retained with a diagnostic. No plugin-id cache
   sweep can reach staging. Unproven stage capture, cleanup debt or recovery debt
   disables further staging writes; a new provider does not silently adopt a
   nonempty staging root. Limits are **8 source leases, 8 stages, 64 outstanding
   descriptors by default** (registry's configurable ceiling is 256).

Atomic exchange is the kernel publication primitive, not a claimed inode-CAS
syscall. Displaced-inode verification and guarded rollback handle a racing slot.
If recovery cannot prove both locations, the outcome is explicitly unknown and
staging is retained. Host mutation reservations serialize native manager writers;
the held namespace and post-exchange checks also address non-cooperating filesystem
replacement. This does not claim that transient exchanged names were never visible
to an external reader before a guarded rollback.

### Descriptor issuance and concrete C/Python join

The wire descriptor is exactly:

```json
{"abi":1,"registry":"native-registry-UUID","ticket":"64-character-native-random-ticket"}
```

It contains **no fd, caller-selected owner, pathname, hash-as-authorization or
developer-server authentication token**. Unknown fields are rejected. Only native
file custody can issue a registry entry. The entry retains its read-only FD backing,
purpose, plugin/format, exact native `CallbackOwner` for load, namespace/version,
SHA-256 and byte count. A ticket is consumed once. A wrong purpose, old/new different
owner, another registry, unbound/wrong inspection invocation, consumed token or
retired backing fails before a descriptor can be used.

The required tiny native-owned C verifier join is now concrete on the Swift side:

```text
registry.resolveFromBridge(descriptorJSON, purpose,
                           pluginId: C_module_state.plugin_id,
                           ownerToken: C_module_state.owner_token)
```

- The C/native callback must take identity from immutable C module state, **not**
  Python arguments. It passes the result's checked borrowed read-only descriptor
  and native claims to the archive hook. It must not expose issuance, inspection
  binding, context installation or a generic fd registration operation to Python.
- `PluginElyxDeveloperDescriptorExecution` is native worker TLS. The join hunk binds
  a unique inspection context after the actual inspector is reserved, installs it
  on that worker immediately before execution, and clears it at real completion.
  For verified load it installs the issued **new** callback owner's context.
  A reserved inspector-name string is not authentication.
- The verifier checks C identity against that TLS owner. Inspectors require the
  native inspection context and unbound C plugin/owner fields. Descriptors then
  resolve to their registry-owned backing; a forged own fd plus a matching digest
  cannot authenticate.
- The descriptor lease and any in-flight resolved reader hold backing resources
  independently of the cancelled waiter. Metadata execution retains the issuance
  in `onExecutionFinished`; load uses existing `PluginInvocationRetention`.
  Revoking a ticket prevents new resolutions without recycling an fd still used by
  an already running reader. Consumers must not close the borrowed fd; their own
  close/seek lifetime uses a duplicate.

`PluginElyxDeveloperDescriptorBridge` has three mandatory closures: current native
readiness receipt, actual Host inspection, and actual current-owner lookup. Its
readiness value must confirm ABI/registry, a fresh registration epoch, and
`manifest`, `inspect`, `verifiedLoad`. Source and prepared objects recheck it;
replacement/reinstallation cannot revive an old preparation by restoring names.
SHA-256 uses CryptoKit in Apple builds and the same standard primitive as Core's
portable checksum for Linux, without adding Core/UIKit dependencies to PluginHost.

The coordinator's concrete composition is:

1. Install the C verifier forwarding to this registry and join the archive owner's
   three Python hooks to it; expose their real registration/readiness epoch.
2. Construct the bridge with inspection forwarding to
   `host.inspectElyxDeveloperDescriptor(call.descriptor, format: call.format,
   shouldExecute: call.isCurrent)` and owner lookup comparing actual callback owners.
3. Call the new Root `installElyxDeveloperFileAuthority(registry:bridge:)` factory.
   It installs `PluginElyxDeveloperFiles` into `elyxDeveloperFiles`, with actual
   Host owner/model/consent predicates and the native installation directory.

The fd/layout implementation is complete in these files. The verifier registration
and the archive owner's currently owned Python hooks remain a coordinator join,
as requested; a permissive readiness closure is not a valid substitute. The concrete
Python-side immutable authority fields remain the archive owner's choice.

### New verification scope

The 17 compiled-test sources cover SHA vectors; actual create/seal/inspect/exchange;
old/new owner binding and replay; own-fd/digest/context forgery; missing verifier;
readiness/metadata refusal; same-digest different inode; namespace ABA; parent swap
before read and after exchange; candidate replacement and cleanup retention;
post-exchange revocation/rollback; unrecoverable slot replacement; post-commit error;
cancelled inspection/load waiter FD lifetime; old archive-cache purge; consent
retirement; independent source/stage budgets; and bridge-epoch replacement.

**Native compile/execution is pending Darwin/Linux**: `swiftc` is absent here.
The new driver ran on Windows and reported **1 platform skip in 0.02 s**. No native
green claim follows from that. Scoped source whitespace/Python-driver syntax checks
passed. The original routing handoff was applied by the coordinator during this
work; re-projecting it again correctly failed its already-consumed contexts. Checking
only the new file-authority/TLS join against the current shared tree then found
**6 unique hunk matches**. The new join was not applied here.

```text
python3 -B -m pytest tools/compat/tests/test_native_elyx_files.py -q -s
```

This command compiles local sources only, then runs the actual native tests with
the fixed runtime budget. No CI, app status, account, external network/plugin,
commit or push operation was used for this continuation.

## Joined archive contract v1 — supersedes the provisional descriptor layout

The archive owner supplied
[`elyx-source-descriptor-v1.json`](elyx-source-descriptor-v1.json), verified raw
SHA-256 **`7c1d62d040f75b900bdd0ece50335797fd0596fde5ddb38f8e77b449c3e3c83c`**.
All three Python hooks now exist in that owner's code and consume the real C
`xt_elyx_source` gate. The two new native implementation files have been adapted
to this exact ABI. **The earlier three-key wire example and borrowed-FD-to-Python
proposal in this document are obsolete. No fd is returned over the v1 wire.**

### Exact native wire implementation

`PluginElyxDeveloperDescriptorRegistry.dispatch(requestJSON:immutablePluginId:
immutableOwnerToken:)` is the concrete closure for
`BridgeServices.elyxSourceDispatcher`. It checks the exact C-context envelope
before handling the operation and returns the existing `{ok,value}` / native
error envelope.

Descriptors have exactly the contract's eleven keys: `abi`, `schema`,
`capability`, `purpose`, `plugin_id`, `owner_token`, `format`, `source_sha256`,
`byte_length`, `source_namespace`, `source_nonce`. The native registry constructs
them; `claim` compares the entire decoded descriptor to that registered proof.
Capabilities, namespaces and source nonces are native-issued **64 lowercase hex**
values. An inspection descriptor uses its own staging namespace/version and a
null owner; load/manifest use the held installation namespace and native owner.

Implemented operations:

- **claim:** one consumption of the exact issued inspect/load descriptor; replies
  with exactly `abi/read_id/descriptor/read_only/load_reader_abi`.
- **manifest:** requires exactly one live `Source.open` receipt for the current
  native/C owner and expected digest. No lookup by arbitrary path, mutable cache,
  or “first matching digest”. Concurrent matching receipts produce an explicit
  ambiguity failure. Its proof has purpose `manifest` and the same claim reply.
- **read:** caller-owned `read_id`, integer offset, count `1...65536`; returns
  exactly `offset/data_base64` for `min(count, remaining)`. Each ticket owns an
  independent native read-only fd duplicate and uses explicit `pread` offsets.
  FD/version/namespace/caller checks occur before and after reads. Full SHA-256 is
  checked at native capture/claim and by the Python reader, avoiding quadratic
  whole-archive hashing for every 64-KiB chunk.
- **check:** exactly `read_id/descriptor/current`, preserving the same proof.
- **release:** exactly `released: Bool`, idempotent for absent/released tickets.
  Only the recorded C owner may release its ticket; that cleanup remains allowed
  after the owner starts retiring. It never grants fresh read authority.

The native TLS context now also covers ordinary captured-owner manifest reads,
not just inspection and verified load. Its live predicate retains the actual
session/cancellation/owner admission. Inspection accepts C's **`@elyx-inspection`**
sentinel only alongside the native-issued inspection context and null C owner
token. The sentinel alone is not authority. Read tickets are reclaimed by native
execution-scope finish callbacks even when Python release fails or a waiter is
cancelled; backing descriptors remain retained through an in-progress native read.

### Coordinator join, now using the delivered C hook

Apply `native-elyx-developer-files-root.patch` after the routing and
`elyx-source-capability-coordinator.patch` changes:

1. Root's factory installs the concrete `registry.dispatch` closure into
   **`host.bridge.elyxSourceDispatcher`** before constructing the native file
   provider, restoring the prior dispatcher if construction fails.
2. Supply the mandatory bridge readiness epoch only for this registered registry,
   built-in C gate and the three actual archive hooks. Forward inspection to the
   actual Host inspector with its issued descriptor and captured predicate.
3. The Host hunks install native inspector/new-load/manifest owner context on the
   real worker, including its live predicate, and finalize all ticket cleanup on
   actual invocation completion. No source-registry installer or fd registrar is
   exposed to Python.

The archive owner controls its immutable Python source fields. No compatibility
fallback or edits to those owner files were introduced to consume the new API.

### v1 checks

The native suite now contains **21** tests, adding exact v1 inspection/manifest
reply shapes, chunk/read bounds, duplicate claim/release behavior, ambiguity,
source replacement and missing-release cleanup. These tests use the actual native
registry and filesystem, with a stated fixture inspector. Native compilation and
execution remain pending Darwin/Linux; the Windows platform skip is not a pass.

Data checks passed: the pinned contract SHA, exact native eleven-key set, all five
operation routes, no raw-FD public read method, and authored-source whitespace /
Python-driver syntax. These are source/contract checks, not native execution claims.

Final v1 provider pins (raw SHA-256):

```text
e8382f29bb7967c3de7e635158b0d312b62b4ecde9ea9b336dbf482d04895ede swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperFiles.swift
4146d16f51d345280cea3a85a1b364e30f599d4fdbf40cddb4c833fb971b48ba swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift
fc1d977df4c278ea89fd745872e8ace0de98c8854255e87b0e51add8d3c3bab6 swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift
fc60e05b1cd9493f29a0d4aed79577b2561891bf70438a644e0dd60d1ef99dd4 tools/compat/tests/test_native_elyx_files.py
e913e3069968312ba617c36699ceea809c1cfe235b379c4d066ba65e3fc36745 docs/wave-2/native-elyx-developer-files-root.patch
```

The v1 driver again reported **1 Windows platform skip (0.02 s)**; no Swift/native
execution was claimed. The six new Root/TLS hunk contexts matched the current
shared tree in memory. SDK/Original raw comparison remains **36/36**.

## Coordinator routing integration — 2026-11-16

All14 shared routing hunks are applied: platform installation, truthful protocol
status, Runtime ingress, native Host capture/read/publication/verified-load seams
and the three protocol tests' source-list entry. The descriptor is retained by
the actual invocation completion, not merely by the async caller.

The mandatory FD/source-byte provider and three archive-side hooks above are
being implemented by the native developer and archive owners in disjoint files.
The optional Root provider remains uninstalled until that concrete contract is
joined; compare/changes still report the documented missing-provider error.
No compilation or runtime acceptance is inferred from applying these hunks.

## Applied closure and final handoff

### Production startup/TLS join — APPLIED

The authorized edits are installed directly in `PluginHost.swift`,
`BridgeServices.swift`, and `ExteralessPluginRuntime.swift`. The old private
`installElyxDeveloperFileAuthority` factory has been removed from production.
The earlier `native-elyx-developer-files-root.patch` is a historical artifact and
must not be reapplied over this implementation.

- `PluginElyxDeveloperService.swift` owns a coalesced, retryable activation, a weak
  Host link, its registry/dispatcher epoch, and the resulting file provider.
  Readiness and filesystem construction run in a detached native task.
- Both `updateDeveloperServer` and authenticated `handleDeveloperRequest` call
  **`PluginHost.activateElyxDeveloper(scope:isCurrent:)`**. Request target IDs,
  actual owners, persisted model, consent revision and account index are captured
  before the readiness await. Account mapping, activation, Host, session, source
  version and final actor context are rechecked.
- `PluginElyxDeveloperActivationScope` is revoked synchronously on context changes,
  clear-context, termination, runtime-mode changes and settings maintenance.
  Context retirement precedes publishing the replacement platform snapshot;
  termination retirement precedes its first await. Host stop/maintenance also
  invalidate the Host-owned service slot.
- Every readiness attempt creates a fresh trusted metadata worker with Python
  threads disabled. `_elyx_readiness.probe_json` checks the built-in module origin,
  the exact `xt_elyx_source` builtin/module identity, `SOURCE_ABI`, and all three
  archive hooks. Its ordinary unknown-ticket `check` must receive exactly
  `bridge host error [Superseded]: native read ticket is unknown or released`.
  Native Host independently requires **one observation of that exact fresh nonce**
  in its installed registry under the issued inspector TLS context. A Python-only
  success receipt cannot establish readiness.
- Dispatcher install/epoch capture is atomic. Restoring the same closure still
  advances its epoch; an obsolete service removes only its own epoch. Failed
  attempts clear cached readiness and can retry. Native worker completion clears
  TLS and reclaims read tickets, including cancellation tails. Invalidation revokes
  retained entries without recycling FDs still held by actual execution.

There is no Python listener, Python reload, generic capability/FD registration,
authentication-token argument, or mutable path/cache source fallback in this join.

### NFD-01 — lost staging namespace retains data and records recovery

`elyxRemoveOwned` now checks the continuously captured namespace watch and held
directory bindings before lookup, after lookup (including ENOENT), before its
exclusive quarantine rename, and before unlink/restoration. A moved or ABA stage
causes retention and recovery debt. The operation-directory quarantine uses a
parent-only watch established while the full stage watch is still valid, so its
own expected rename does not disable ordinary cleanup.

`ElyxStage.deinit` rechecks after `beforeCleanup`; failed initialization uses the
same guarded cleanup. Initialization completes only after all throwing candidate
checks, preventing two cleanup owners after an initialization error. The existing
nonrecursive no-replace quarantine and moved-inode checks remain in force.
Publication rollback remains a separate guarded exchange of its captured slots.

Real-provider test definitions include the exact **move operation directory to
`stolen-stage`, release last prepared reference** witness: original candidate bytes
must survive and the next stage admission must fail. Additional definitions cover
loss after cleanup lookup, stage ABA at both hook boundaries, failed-init retention,
and successful reclamation/retry when custody remains intact. These tests have not
been executed on Windows.

### NFD-03 — commit knowledge survives the complete wire path

`PluginElyxDeveloperPublicationState` follows the native invocation from Root and
Ingress through Host/Transaction. Host records commit immediately after successful
`prepared.publish`, before `checkPublished`, `persistInstalledPlugin`, verified
load, and final session/owner/source checks. File-engine failures retain their
typed underlying kind. The loader's optional native error observer preserves its
original typed error instead of reconstructing it from `Plugin.loadError` text.

Every changes failure retains `ok=false`, the selected `plugin_id`,
`reloaded=false`, `error_kind`, `error`, and `errors`, with two additive fields:

| `publication_outcome` | `source_changed` |
|---|---|
| `refused` | `false` |
| `rolledBack` | `false` |
| `committed` | `true` |
| `recoveryRequired` | `null` |

Late Ingress/Root guards preserve known publication state, including errors after
successful model publication/load. Private absolute paths, capability/source
nonces and owner epochs are removed from error text, which is bounded to 4096 UTF-8
bytes. Native protocol framing preserves handler `ok=false` and the original `#`.
The socket server also preserves the handler's structured receipt when its task
is cancelled after handler return; its existing epoch/connection checks still
control delivery. A new deterministic loopback-fixture branch cancels its own
handler task and requires the committed receipt to survive on the actual wire.

Original `_cmd_changes`'s `ok/plugin_id/reloaded/errors` fields and compare's
`created_or_modified/deleted` fields remain stable. The additions are response-only;
request validation is unchanged. Original `dev_server.dispatch` uses
`response.update(payload)` and preserves additional output keys. Native protocol
tests assert the original fields and correlation ID alongside all four outcomes.

### NFD-02 join and the fifth real native child

The archive owner's sealed
[`elyx-nfd02-inputs.json`](elyx-nfd02-inputs.json) is consumed as delivered.
`_archives.py` raw SHA-256 is
`7238088539f31c414307e1f9e8b986940a87d4525ce6b31e5020b09871b555da`.
Its actual `inspect_developer_descriptor`/`inspect_fd_json` return is required
before old-owner retirement. No metadata fallback is used after a policy refusal.
`_archives.py`, `_audit_paths.py`, runtime `__init__.py`, and
`PluginArchiveStorage.swift` were not edited by this owner.

`tools/runtime/fixtures/swift_sdk_elyx_developer_probe.swift` defines
`SDKElyxDeveloperNativeProbe`, using the same public Host activation API as Runtime,
real `CPythonXCFrameworkEngine`, `NativeBridgeBinding`, registry and FD provider.
Its forwarding observer records execution; the three negative readiness attempts
only remove/change a real attribute in their own fresh inspector.

The child requires:

1. Missing gate, missing hook and wrong ABI refusals, followed by genuine readiness
   and retry through the installed native registry.
2. Native disabled install followed by load; data-only inspectors execute no entry.
3. Real FD-inspected changes containing nonempty `requires` and a wheel with
   `Requires-Python: >=99`. Both must refuse with `source_changed=false`, preserve
   old owner/source/model/consent, invoke no new loader, and leave no stage/ticket.
   SDK counters must remain exactly one load and zero unloads (**ZeroOldRetirement**).
4. Actual Host publication of a changed entry class, helper, asset, metadata version
   and same-filename wheel. A new owner must execute the new values via verified
   load, retain installed path/enabled state and consent, and produce clean compare.
   Declared `network` metadata must not grant native network permission.
5. Explicit stale-owner, cancelled-session, equal-byte source replacement,
   dispatcher-ABA, retired-scope and old-capability rejections. Replay checks the
   decoded `rejected == true` value; refusal checks cannot swallow their own failure.
6. Two actual plugin owners plus ten data-only inspector lifetimes, one process
   initialize/finalize, actual three-hook/five-operation observations, and zero
   remaining provider authorities, source leases/receipts, stages, read tickets,
   capabilities, SDK/C handles, callback leases, plugins and external effects.
   Retired extraction directories and installed source must be absent.

The six emitted input artifacts total **6,404 bytes**; the staged Python observer
adds **5,012 bytes**, for **11,416 bytes aggregate**, below 32 KiB. The native report
also has a separate 32-KiB bound. The process deadline remains **30 seconds**.

### Exact coordinator/Tooling packet

[`native-elyx-developer-startup-tooling.patch`](native-elyx-developer-startup-tooling.patch)
contains **12 exact hunks**, projected uniquely against the shared files without
editing them. The projected Python passes AST parsing. The packet:

- dispatches `--elyx-developer` before any existing executable helper startup;
- compiles the fifth Swift probe alongside the actual Host/C sources;
- stages the owned emitter/observer and verifies the NFD-02/v1/production inputs;
- invokes the fifth child with the existing process-group timeout runner;
- validates its detailed report through `elyx_developer_probe_driver.py` and only
  publishes overall success after all five children and source-pin checks pass.

Projection preimages (raw SHA-256):

```text
0b5287f71143e07bc22f91975546aba9136094499c59779b496c9292d3d8c742 python/runtime/smoke/swift_plugin_probe.swift
ccbb89f2800b34e556a85487e4ec56b5ad978c38130011e25bbee576e550ab49 tools/runtime/check_swift_plugin_embedding.py
```

Native execution commands after coordinator application:

```text
python3 -B -m pytest tools/compat/tests/test_native_elyx_files.py tools/compat/tests/test_native_elyx_ingress.py -q -s -p no:cacheprovider
python3 -B -m pytest tools/compat/tests/test_sdk_developer_native.py -q -s -p no:cacheprovider
python3 -B tools/runtime/check_swift_plugin_embedding.py --python /path/to/python3.12 --python-root /path/to/staged/python --output EMPTY_OUTPUT
```

The FD driver now selects **29 Files + 6 Activation + 12 Transaction/Host tests**.
The new ingress driver compiles the **actual** Foundation model, protocol, ingress
and **7 protocol/ingress XCTest definitions** with local PluginHost. It starts no
Python or listener. The loopback executable separately exercises the real native
listener; its existing ten-second runtime bound remains.

### Current local verification and source freeze

- Windows CPython **3.14.8**: **8 passed, 3 platform skips in 4.27 s**. These are four
  real readiness-helper rejection tests, independent emitted ZIP/command checks,
  and three existing Original SDK read/manifest/refusal state-fixture tests. The
  skips are the native FD/activation/transaction, native ingress, and Darwin
  listener drivers. They are not native passes.
- Data-only execution of the actual `_inspect_archive_bytes` and sealed shared
  load-policy validator accepted both positive emitted images and rejected both
  unsupported candidate images (**2 accepted / 2 refused**). This used host Python
  dependency metadata and did not execute a native FD registry or plugin entry.
- Eight authored Python files pass AST/whitespace checks; actual staging verifies
  ten pinned inputs, six emitted files and the 11,416-byte aggregate input bound.
  Scoped `git diff --check` passed. The Tooling projection has twelve unique hunks.
- **Swift compilation, the 47 core / 7 ingress test definitions, the updated
  listener witness, and the real fifth child remain pending coordinator execution.**
  The coordinator's earlier 53-pass POSIX cohort excluded this FD provider. Earlier
  11-pass/7-skip and 21-FS-test receipts are history, not verification of this cut.

**SOURCE FREEZE:** this owner's final delivery is sealed in
[`native-elyx-developer-final-inputs.json`](native-elyx-developer-final-inputs.json),
which lists each final changed file and its raw-byte postimage SHA-256, plus the
required shared/read-only input pins. Shared Host/Runtime postimages include the
coordinator's trust/settings/send-priority/archive changes. Native acceptance is
still pending. No CI/status queries, commits, pushes, accounts or external network
operations were performed for this delivery.

## DEV-LIFECYCLE-01 — developer-mode ABA delta (2026-11-16)

This narrowly scoped delta addresses the remaining P2 in
[`reviews/native-elyx-final-source-closure.md`](reviews/native-elyx-final-source-closure.md),
lines 255–309. The previous 41-file source inventory remains an unchanged
historical seal. New postimages and the coordinator's two compiler-only postimages
are recorded in [`native-elyx-mode-aba-inputs.json`](native-elyx-mode-aba-inputs.json).

### Actual Root write path

`ExteralessPluginRuntime.updateManagerPreference(_:authority:)` now treats
retirement as the irreversible part of **accepting** `.developer(false)`, before
creating/awaiting its detached writer. Before retirement it requires:

1. the existing manager store;
2. an uncancelled caller and current Root context (`!terminating`, `hasAccount`,
   `currentContext != nil`);
3. the native caller's live `PluginConfigAuthority`, when supplied.

Only after these checks does it synchronously call the existing
`stopDeveloperServices()`: the actual session is cancelled, the old activation is
invalidated, the service/file references are cleared, and the Host registry slot
is retired. The detached `store.apply(change, isCurrent:)` retains its original
write-time authority check and atomic persistence behavior.

Both independently queued production callers reach this exact method:

- `PluginDeveloperBridgeExtension`'s native stop command, through the actual Root
  developer-provider initializer's `apply(false, authority)` closure;
- `PluginConfigBridgeExtension.setPluginConfig("developerMode", true/false)`,
  through `applyGlobalPluginConfig` and the same Root writer.

The public manager developer control also uses the same writer. There is no new
mode flag or separate policy in a probe. If false and then true both persist before
either MainActor continuation resumes, both later `updateDeveloperServer()` calls
may observe true, but the old scope/session/registry have already been retired.
The first restart uses a fresh scope and registry epoch; subsequent on/start calls
coalesce onto that current authority through the unchanged activation path.

### Failure and control semantics

- Missing store/context, cancelled work, or expired owner/settings authority fail
  **before** retirement. A command rejected by native provider admission does not
  reach the Root effect at all.
- After Root accepts off, later write failure or write-time authority expiry cannot
  revive old work. The original typed error propagates. The preference store still
  publishes its cached state only after a successful atomic write; Root does not
  manufacture a persisted false result.
- A failed off write does not automatically restart the service. An explicit
  start/retry consults the store's last successfully published state and the normal
  Root guards, then creates fresh authority. The failed-write fixture preserves the
  old durable true file, restores its owned error barrier, and exercises this path.
- Already-off writes remain idempotent with no new activation/session. Ordinary
  on writes and listener-start retries do not retire a still-current authority.
- Engine/safe-mode/global-unsafe controls, native consent, the preference filename,
  serialized fields and default service/cache identity are unchanged.

### Observation API and native regression

`PluginManagerPreferences.init(url:legacyEngineEnabled:didPersist:)` adds one
optional, native-only observation closure, defaulting to nil. It is called only
after a successful real write and state publication, **after releasing the store
lock**. It cannot supply a write result, change admission, or replace persistence.
The regression uses it to hold the off writer and observe the on write before
either returns to MainActor. The shipping Root does not install an observer.

The separate fixture is
`tools/compat/tests/test_native_elyx_mode_aba.py`. It compiles **13 byte-exact shipping
source spans**: seven Root methods, its execution-requested property, both actual
provider initializer expressions, and the three actual Core command-queue/mutation
declarations. It also compiles the actual provider, store, session/protocol and
Ingress source files. There is no alternate Root writer or alternate queue.

The four `NativeElyxModeABATests` definitions cover:

1. **Two real native queues, two real writes.** Native developer-stop writes false;
   global-config writes true while the first writer is held. At the second durable
   publication the fixture records both disk/cache true, no resumed Root writer
   continuation, and retired old scope/session/registry/pending invocation/capability.
   The pending actual Ingress/Host call then refuses. Restart must produce a different
   registry and captured epoch; the unconsumed old native-issued descriptor must
   remain rejected by both registries.
2. **Real persistence failure.** An owned directory obstructs the actual atomic
   preference write while the previous durable file is retained. The Root returns
   the actual Foundation error, keeps the published true state, and leaves old
   authority dead. Native listener-start through the real provider creates fresh
   authority after the fixture restores its file.
3. **Rejected admission.** A real Host settings-grant revocation rejects the native
   stop request. The captured native permission predicate and a missing Root context
   also refuse at Root entry, leaving the previous developer authority and durable
   preference bytes intact.
4. **Already off / coalesced on.** False while already off creates no service; a
   subsequent on creates one. Real config-on and native listener-start calls reuse
   its scope, registry and session, preserving consent and engine/safe-mode state.

The fixture's boundaries are explicit: Python execution uses the existing canned
`MaintenanceTestEngine`; UI/context and transport effects are Foundation recorders.
The actual Host worker/TLS challenge, public activation, registry, issued descriptor,
store, providers, queues, and `PluginDeveloperSession` run. The transport recorder
has no listener or ready token. No account, UIKit frame, socket or external network
operation is required. This is not a new C/CPython/FS-preflight acceptance receipt.

### Checks and handoff

```text
python3 -B -m pytest tools/compat/tests/test_native_elyx_mode_aba.py -q -s -p no:cacheprovider
```

Compilation is capped at **120 seconds**; the standalone native test process at
**30 seconds**, using the existing owned process-group cleanup runner. The fixture
does not add tests to or edit the closed 47-core / 7-ingress suites.

Local Windows checks: Python AST/whitespace and scoped diff checks passed;
preparation verified 13 exact spans, 64 pinned inputs and eight byte-identical copied
UI inputs. The native driver reports **one platform skip (0.03 s)**. Native compilation
and the four regression executions remain pending the coordinator's native runner.

The coordinator's qualified Darwin/Glibc `S_IFMT`/`S_IFREG` constants and the single
outer-`try` filesystem-test loop correction are preserved as current read-only
postimages in the new seal. The previous seal itself remains byte-identical.
**Mode-ABA source freeze is the new delta manifest**, not a rewrite of the earlier
inventory. No CI/status query, commit, push, foreign plugin or real account was used.
