# ARCH-01/02/03 — independent P1-fix closure

2026-11-16. **Known P1 counterexamples: closed in the reviewed source routes.
Overall iOS source closure: PARTIAL — one concrete P2 remains in platform
selection for descriptor/path handling.** Positive POSIX/Swift execution and
native source-capability acceptance are not claimed here.

`native_execution_claimed: false`.

Inputs: [`elyx-archive-p1-inputs.json`](../elyx-archive-p1-inputs.json),
[`elyx-archive-remediation.md:238+`](../elyx-archive-remediation.md), and both
coordinator-applied patches. All **14/14 owner pins match**. The previous
[`elyx-archive-source-closure.md`](elyx-archive-source-closure.md) remains
byte-identical at
`f76ec27837b44776e0f2bee18d84e9da480962c3e9214a77b3eefdc0db327cfb`.

## Verdict by original finding

| Finding | Current source route | Verdict / evidence boundary |
|---|---|---|
| ARCH-01: source cache preserves forged nested filenames | `_Image.member` → `_SnapshotLoader.get_code` → `_bind_code`; both SDK factories and explicit wrapping-loader construction use this path | **Closed in source.** Cached-source control still reproduces the old issue; the adapted route returns captured source and owned code labels. Portable regression passed. |
| ARCH-02: files-only owner can replace executable cache bytes | `ArchiveCodePaths` is installed for every configured owner before entry; module resolution and execution consume the immutable image | **Original P1 closed in source.** Current files-only writer regression denies code/topology writes and permits ordinary asset data. iOS descriptor compatibility remains **P2-01** below. |
| ARCH-03: checked ancestor is reopened through a mutable pathname | Python `_Directory/_Extraction`; native `PluginArchiveCacheLease/ArchiveDirectory`; Host captures before unload await | **Original pathname-redirection P1 closed in source.** Actual fd-relative implementations replace the vulnerable full-path I/O. Windows refuses the unavailable POSIX backend. Positive POSIX/Swift execution remains separately pending. |

This verdict concerns these three counterexamples and their fixes. It does not
advance the old SDK symbol flags or establish the separate native developer
registry's authority.

## P2-01 — Python Darwin selectors omit the actual `ios` platform

**Locations:**

- `python/exteraless_runtime/_audit_paths.py:170–175` — OS-root lexical aliases.
- `python/exteraless_runtime/_audit_paths.py:181–193`, especially **186** —
  descriptor resolution chooses `F_GETPATH` only for `sys.platform == "darwin"`.
- `python/exteraless_runtime/_archives.py:913–921` — raw OS-root alias pinning
  has the same Darwin-only predicate.

The embedded iOS runtime identifies itself as **`sys.platform == "ios"`**.
The retained `runtime_probe.c:161–164` writes that exact expression, and
`build/artifacts/python-runtime-43738810843/runtime/simulator-smoke.json:3,10`
records CPython 3.12.16 / `ios`. This old artifact is used **only as a platform
identity datum**, not as execution evidence for these fixes. The reviewed
bootstrap does not rewrite `sys.platform`.

For `ios`, `_descriptor_path` selects neither Darwin nor Linux and returns
None. `ArchiveCodePaths.fd_path:250–260` then raises for an ordinary regular-file
descriptor. Consequently an otherwise allowed asset operation such as
`os.write(asset_fd, data)` or a relative write through `os.open(..., dir_fd=...)`
fails in the new guards (`_audit_paths.py:307–337`). It fails closed; this is not
the old unguarded code-write P1, nor a claim that all pathname asset writes fail.

The same omitted platform value skips the documented `/var`, `/tmp`, `/etc`
handling. In the fd walker a raw iOS root alias is treated as an untrusted
symlink. Canonical `/private/...` cache paths need not encounter that branch,
but the promised raw-alias path is not implemented for `ios` by these selectors.
The Swift `#if canImport(Darwin)` path does include iOS, so it does not repair
the independent Python selection.

### Independent bounded dispatcher witness

I called the **actual** `_descriptor_path` / `fd_path` code with a real owned
Windows regular-file descriptor. A counted `fcntl` stand-in isolated platform
selection; `audit.sys` was locally supplied as `ios`, then `darwin`. This is a
portable branch witness, **not a Darwin syscall or iOS execution result**:

```json
{
  "ios_f_getpath_calls": 0,
  "ios_descriptor_path": null,
  "ios_regular_asset_fd_error": "cannot verify a filesystem descriptor for archive code protection",
  "darwin_control_f_getpath_calls": 1,
  "darwin_control_path_returned": true,
  "native_execution_claimed": false
}
```

**Required source/test closure:** select the Darwin-family implementation for
the real `ios` platform in all three sites. Add platform-selector regressions
covering `ios`, plus a real iOS/Darwin descriptor check: allowed asset fd write,
denied code fd/dir_fd write, and held raw `/var`/`tmp`/`etc` aliases. A green
Linux or macOS-only case cannot exercise the omitted `ios` selector. No source
fix was authored by this review.

## ARCH-01: immutable image, loader selection and code labels

The actual implementation is in `python/exteraless_runtime/_archives.py`:

1. `_inspect_archive_bytes:647–686` and `_wheel:614–638` retain immutable `bytes`,
   mapping proxies and per-member hashes. `_Image:427–453` copies the manifest
   into read-only blob/label maps and checks each member digest.
2. `_Image.member:460–468` checks image/held-root liveness and **consumes the
   hash against the captured bytes**. It does not hash a file and then reopen
   its pathname.
3. `_sdk:575–605` changes module-local namespace filesystem predicates to
   `_ManifestPaths` and replaces **both** SourceFileLoader and
   SourcelessFileLoader factories with `_SnapshotLoader`. A disk-only injected
   module does not become a finder result. Existing package/source precedence
   and empty package search locations stay with the preserved SDK finder.
4. `_owned_module_exec:520–527` also covers callers passing an ordinary source
   or sourceless loader directly to the preserved wrapper.
5. `_SnapshotLoader.get_code:503–514` compiles the captured `.py` bytes with
   `dont_inherit=True`; it never consults an unchecked-hash source cache. An
   explicit `.pyc` is decoded from captured bytes after header checks, then
   passed to `_bind_code`.
6. `_bind_code:383–414` recursively handles `CodeType`, tuples and frozensets,
   including nested constant containers. It rejects unsupported mutable/cyclic
   graphs, bounds depth/nodes and rewrites every code filename. The memo retains
   shared code-object identity.
7. `_image_key:417–418` handles NFC lookup aliases, while
   `_SnapshotLoader:481–489` selects the original manifest label and updates
   `spec.origin`. That is the label registered during materialization at
   `:1249–1251`, keeping `co_filename`, `__file__` and audit ownership aligned.

`cached_source` and `snapshot_mutations` passed independently. They include the
unadapted source-cache counterexample, adapted source/sourceless controls,
forced disk mutation/replacement, package and data-module selection, refusal
of a new disk-only module, immutable blob maps and NFC-labelled lookup.

An additional in-memory call of the production `_bind_code` used one forged
code object shared inside a tuple and a frozenset. All three code occurrences
(outer plus the two references) had the requested registered label afterwards;
the shared nested code identity was preserved. No resulting code was executed.

## ARCH-02: cross-owner code guard and ordinary asset control

`_platform.py:243` calls `_audit_paths.install` during the ordinary provider
installation, before `configure` returns and before any plugin entry.
`_audit_paths.py:340–350,389–421` installs `ArchiveCodePaths` for **source-only
owners as well as archive owners**. A writer does not need to have loaded an
archive to recognize another owner's future `cache/<component>/elyx/...`.

`ArchiveCodePaths.reason/check:226–304` covers lexical and resolved paths,
case/Unicode-normalized aliases, executable suffixes, `__pycache__`, ancestor
and directory topology, both rename/link operands, and destination symlinks.
The fd guards resolve dir_fd arguments absent from CPython's `open` audit
event and cover descriptor writes/dup2. Unverifiable regular-file/directory
descriptors are denied. **The missing iOS selector above limits the usable
Darwin descriptor branch; it is not counted as completed iOS behavior.**

The source-installed guard precedes the old protected-write path; the old
files-only permission no longer makes archive code writable. The independent
`audit_owner` test used a tiny **owned writer plugin** with Python service
doubles: writes/replacements/hardlinks to code and topology changes were denied,
while an ordinary asset-file data write succeeded. It is a portable SDK/audit
test, not execution of native C, Swift or a foreign plugin.

Execution also has its own byte boundary: source and explicit bytecode read
`image.member`; data imports use `_data_module_exec:368–380`; loaded localization
uses `_strings_from_snapshot:1228–1233`. A forced raw disk mutation does not
become executed content. Ordinary asset content is deliberately filesystem
data under the existing owner/files rules.

The declared global unsafe and same-process trusted/native capability boundary
is retained as a scope condition. It is not relabelled as a new archive defect.

## ARCH-03: held directories, receipts and capture-before-await

### Python route

`_archives.py:59–61,866–868` requires actual POSIX dir_fd/nofollow support.
Windows has an explicit unsupported result; the previous pathname extraction
fallback is gone.

- `_Directory.open_native/child:902–974` opens OS `/`, descends with
  `openat`-style `dir_fd` calls and nofollow flags, verifies directory type and
  captures device/inode/type identity. `_Directory.verify:931–945` compares
  held `fstat` with each parent's nofollow stat. Root aliases are pinned in the
  Darwin branch, subject to P2-01's missing `ios` selector.
- `_Extraction.write:1029–1051` creates the leaf exclusively relative to the
  held directory, records the opened inode, rechecks the binding, writes via
  that fd and closes it in `finally`. A swapped pathname cannot redirect the
  held fd to the previous witness's outside directory.
- `_Extraction.cleanup:1053–1093` starts from the held load root, checks
  materialization receipts (NFC/casefold keys), enumerates with `scandir(fd)`,
  refuses replacement identities and removes via relative unlink/rmdir.
  It does not reopen or recursively follow a replacement root by full path.
- The per-load root remains digest/UUID-qualified. Python leaves its small
  owner parent for the native uninstall lease, rather than sweeping other load
  generations. Cleanup enumeration is bounded to 36,864 entries/depth 20.
- `_Directory` closes its owned fd; its weak pool tracks live held directory
  objects. `_Extraction.close:1095–1099` closes the held pool, and
  `ArchiveAdapter.cleanup:1318–1339` retires the image/unbinds protection/closes
  extraction in `finally`, including cleanup failure.

The raw parent-swap, replacement-inode, raw-alias and two-owner positive POSIX
tests are present in `test_ios_elyx_p1.py:254–404`. They were not executed on
Windows and are not substituted with junction/pathname emulation in this review.

### Native route and actual Host caller

`PluginServiceStorage.swift:76–95` now returns a `PluginArchiveCacheLease`.
`PluginArchiveStorage.swift` implements the actual Darwin/Glibc path:

- `ArchiveDirectory:123–199` holds the complete descriptor chain, nofollow
  metadata/openat and identity checks; deinit closes descriptors.
- `ArchiveLoadReceipt.capture:259–274` records existing relative file/directory
  identities under the held load root with a bounded budget.
- `purge/remove:230–252,276–294` traverses relative to the held root and checks
  captured ancestor/file identities before unlinkat. It does not discover new
  owner/load generations by rescanning names after the unload suspension.
- A newly added, uncaptured file/load makes its parent nonempty; removal retains
  that parent instead of recursively deleting the new contents. Replacement
  inodes are rejected. The one-shot lease drops its purge closure, releasing
  captured descriptors on success and failure (`:18–29`).

The coordinator hunk is **applied in the shipping caller**:
`PluginHost.swift:1190–1218` holds the per-ID mutation reservation, captures the
archive lease at **1201**, then awaits unload at **1210**, then purges **that
same lease** at **1213**. Consent removal remains in that flow. The old
post-await `purgeArchiveCache` recapture is not the caller's route.

Prepared tests include the real native descriptor swaps/replacement/uncaptured
generation cases in `PluginArchiveDescriptorTests.swift`, and
`PluginArchiveHostTests.testUninstallPurgeCapturesBeforeItsUnloadingAwait:227–254`.
The latter creates a later generation during the unload suspension and expects
it to survive. These are source/test-scope references; Swift execution remains
pending the delegated work.

## Applied C gate and preserved developer-source joins

The current source includes the authorized Host inspection/load/retention
joins; no routing hunk was overwritten:

- `PluginHost.swift:946–966` calls `_elyx_developer.inspect_fd_json` and retains
  the descriptor through actual execution completion.
- `PluginHost.swift:1640–1656,1981–1986` selects `load_verified_json` and retains
  its source lease at the native invocation boundary.
- `_elyx_developer.py:89–118` calls the concrete archive hooks.
  `_archives.py:817–863` holds a native ticket through verified inspection/load;
  `__init__.py:192` consumes `snapshot_for_load` rather than reopening the
  descriptor's pathname. Ordinary archive loads still capture their own bytes.
- `_archives.py:1295–1312` requests fresh native installed-source manifest bytes,
  not a walk of extraction or a cached snapshot.

The second coordinator patch is also **applied**:
`python/bridge/_exteraless_bridge.c:3524–3597` exposes the built-in
`xt_elyx_source`, bounds operations/payloads, injects immutable C identity (or
the unconfigured inspector identity), and uses the retained native dispatcher.
It does not use the mutable legacy service registry.
`BridgeServices.swift:200–234` handles the native-only envelope before ordinary
Request/reflection routing and rejects a missing FD registry explicitly.

**Native provider readiness remains separate.** In this reviewed snapshot,
the Host/app source search finds no production assignment to
`BridgeServices.elyxSourceDispatcher`. A nil dispatcher produces
`Native FD-backed Elyx source registry is not installed` at
`BridgeServices.swift:226–227`. The native developer registry is under its own
owner's work; its issuance/custody/ABA/completion authority is not established
by Python descriptor fields, decoder tests, or the existence of the C gate.
This missing join is disclosed, not promoted to an implementation or added as
a re-audit of that separate workstream.

## Checks and execution boundary

### Independently run in this review

On Windows CPython 3.12.10, with a 30-second outer budget and no pytest plugin
autoload/cache output:

```text
test_ios_elyx_p1.py::test_elyx_p1[cached_source]
test_ios_elyx_p1.py::test_elyx_p1[snapshot_mutations]
test_ios_elyx_p1.py::test_elyx_p1[audit_owner]
test_ios_elyx_p1.py::test_elyx_p1[backend]
4 passed in 1.68s
```

Each test's isolated child also retains its 20-second timeout. The code-graph
and iOS-selector helper witnesses were separately bounded to 30 seconds; no
code from their returned code objects was executed. All temporary data stayed
under the approved OpenCode temporary directory and was removed.

Data-only validation passed for the 14 owner hashes, three production Python
ASTs, and **36/36 Original/SDK Python files byte-identical**, including **12/12
Elyx files**. Only this new report is authored by this review.

### Scope not claimed by those results

- The owner's **25 portable passes / 17 explicit POSIX skips** and **3 protocol
  passes** remain owner-reported, with their original scope.
- Positive Linux/POSIX execution is delegated by the coordinator; its CI/session
  was not queried or polled here. Swift descriptor/caller execution is likewise
  not inferred from source or Windows refusal of an unsupported backend.
- Fresh C-gate 3.12/3.14 builds/tests belong to the SDK lead and were not
  duplicated. No native registry acceptance, signed app execution, network,
  account or foreign-plugin operation was performed.
- The historical iOS probe contributes only the literal `sys.platform` datum
  used by P2-01. It is not a fresh archive/POSIX/C-gate pass.

## Source pins

HEAD observed: `4bcf80a0d7160264accbb6b415facde82cf87928`.
Current working-tree raw bytes, including the applied C/Host joins, are pinned
below. The owner input manifest itself hashes to
`7c9474064d6afede795502b022f8a4e20ecde27fe44d92cd27d88b299fd927d5`.

```text
dc63398bc3a00ded23c94dbde615aa6cb45c528094b5c54b8b95670f299fe87a  python/exteraless_runtime/__init__.py
04a0403b7df7977b22714156394430a7760559252745a16d7d7bbcc3e5c9f824  python/exteraless_runtime/_archives.py
3e0d7444eb0dd7a035f55e92d438e1dcf54c62f79b7a83b1a68f4ccf87921e03  python/exteraless_runtime/_audit_paths.py
ecde8c195dfd7fbc5ec6aaa66705b4be4e74324e9d8de3306bae6b046d7625dc  swift/PluginHost/Sources/PluginHost/PluginArchiveStorage.swift
827ce0d50604b56694fbfa83fa7112b7943cf9c33b102de20c57ac9e4ea603d2  swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift
2925286baf7e3707f1e51b8c8f835a4450f5db7b5d623dd17e68576a0c5cf8fd  swift/PluginHost/Tests/PluginHostTests/PluginArchiveDescriptorTests.swift
0a1a4d02683f4908b80b86b20761975cd96e82f827b394b74ff546f69835692d  swift/PluginHost/Tests/PluginHostTests/PluginArchiveHostTests.swift
a235d6a114fef36ae3ed08cb0adac3a967d99d6d4f7301ed5f96308843d1a29e  tools/compat/tests/test_ios_elyx_archives.py
46ff2ceccd6483fb2c3e7983e40db4ea05f8a578bcead8de0122d2abb535a295  tools/compat/tests/test_ios_elyx_p1.py
cd6d8ad16cb9504b58bff7bc46be3fac8b71893c863135c58714eeb8bb20b6e9  tools/compat/tests/test_ios_elyx_source_authority.py
64ba745bbddc10ce4ea062f76589c33b103a6eab3ac5f6b7c88db76466f98ad8  docs/wave-2/elyx-archive-fd-host.patch
105b1854b0e369ab13d4b5ed449c2e7a7d1f757dbea8d7c092853af3d64e43ef  docs/wave-2/elyx-source-capability-coordinator.patch
7c1d62d040f75b900bdd0ece50335797fd0596fde5ddb38f8e77b449c3e3c83c  docs/wave-2/elyx-source-descriptor-v1.json
3f0e5db2da0870d1b2cb20754ba7e683aab30406d6b1a6cf47dae05bc3a7b7db  docs/wave-2/elyx-archive-remediation.md
2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2  python/bridge/_exteraless_bridge.c
5c256b20fc4ecce58c6e460aa1989836450abf499d9f3c7deb135fd5c2421de6  swift/PluginHost/Sources/PluginHost/PluginHost.swift
2b9d428135e67213a47e64f780d595f3ca92ebdbb300e6c042e915d581d0957e  swift/PluginHost/Sources/PluginHost/BridgeServices.swift
2b6050b372f8923bb7efb965bb0b79af73e29dad551e0ff85270359ad4d16932  python/exteraless_runtime/_platform.py
a2b999fb1113249c557a5c9fb90e57476b06bac05b597b9bbebb3e688e926690  python/exteraless_runtime/_elyx_developer.py
1b9a33a09318d0c19a7e64696028089def15cecff2a75a4c0ad6dfbde7d51966  python/sdk/elyx_runtime/namespace.py
bea9ef82832a61f21537150ddb4cff5f5bd4c2ccf4fca90b0d2307d0e8c2dff5  python/sdk/extera_utils/audit_gate.py
c90134bde58559d675ffeff313eecd4223f39d60edbe0992137b41461b6547f5  python/sdk/extera_utils/plugin_loader.py
9c79280f965d83ce9254a39d05b19a827f2fbb72375b256818e8d1c2758e6411  python/runtime/smoke/runtime_probe.c
1fb0fd2a8c234561bf983af158fde13c02a0e9fc1a8834ee8990f9bffc46575c  build/artifacts/python-runtime-43738810843/runtime/simulator-smoke.json
f76ec27837b44776e0f2bee18d84e9da480962c3e9214a77b3eefdc0db327cfb  docs/wave-2/reviews/elyx-archive-source-closure.md
```
