# NFD-02 — independent closure

**NFD-02 is source-closed at the sealed `72380885` / `d0a4b5a5` inputs.** Both
byte-identical earlier witnesses now fail in FD candidate inspection, with read
ticket release before the error reaches the caller. No remaining P1/P2 was found
in this specific known-load-policy gate.

Review: **2026-11-16**; observed HEAD
`31287b9204aef5384b85d75f97f233dccf230409` plus WIP. Source/test pins matched
[`elyx-nfd02-inputs.json`](../elyx-nfd02-inputs.json) before and after verification.
This follows only [NFD-02 in the original review](native-elyx-fd-authority-review.md#nfd-02--p2-known-unsupported-load-constraints-pass-fd-inspection)
and [the remediation at line 490 onward](../elyx-archive-remediation.md).
Only this new document is authored here.

## Exact witnesses: previously accepted, now refused

The original ZIP bytes were reconstructed with their original hashes, then sent
through the actual `_elyx_developer.inspect_fd_json` →
`_archives.inspect_developer_descriptor` functions. The source gate was the
explicit `IssuerRecorder` from the sealed test file, with an owned read-only
file and the real Python reader/validator. It is **not the production C/native FD
registry**. Approved dependency metadata was supplied to the real
`ProvidedDependencies` resolver; entry execution was not performed.

| Original witness | SHA-256 | Observed FD-inspection result |
|---|---|---|
| 512-byte archive; `requires={"other_archive": null}` | `1a44cc6e9b555f5dadc4a65e1d409583e99576a044afa3273e54e88562627335` | `UnsupportedSurfaceError: Elyx requires cross-plugin imports have no iOS cross-owner module provider: other_archive; dependency URLs are metadata only` |
| 1,130-byte archive; pure `py3-none-any` wheel with `Requires-Python: >=99` | `4a94373036c53355d533ec900507f29ccd432029757dc28b0bf6638a3a432858` | `UnsupportedSurfaceError: local wheel requires Python >=99; running 3.12.10` |

For each, the recorder observed exactly one `release`, **before** the caller's
inspection-error event. No metadata was returned, and the input file's bytes
remained identical. This replays the original witnesses, not merely similar new
helper inputs.

## The actual gate and before-retirement ordering

Paths below are relative to the repository.

1. `python/exteraless_runtime/_archives.py:694–722` now defines the shared
   `_preflight_load_policy(inspection, dependencies)`. It rejects nonempty
   cross-plugin `requires`, parses and checks local-wheel `Requires-Python`,
   reports invalid specifiers explicitly, and checks both archive requirements
   and wheel Requires-Dist through the supplied dependency resolver.
2. `inspect_developer_descriptor:867–877` calls this validator at line **875**,
   inside the existing `_native_source_read` scope, after bounded byte/archive
   validation and ID agreement, **before** final check and metadata return.
   `_native_source_read:855–864` calls `reader.close()` in `finally`;
   `close:845–852` issues release and clears the local ticket. On an existing
   policy error, a release error does not replace the original exception.
3. `python/exteraless_runtime/_elyx_developer.py:89–96` serializes only a successful
   provider return. It has no catch that turns this policy failure into metadata.
4. `swift/PluginHost/Sources/PluginHost/PluginHost.swift:1018–1055`
   (`inspectElyxDeveloperDescriptor`) invokes that exact Python entrypoint and
   propagates errors. Native worker completion retains the issued descriptor and
   clears its execution context.
5. `PluginElyxDeveloperFiles.swift:730–765`, in the same Host source directory,
   awaits `bridge.inspect` at lines **755–756**. A thrown policy error prevents
   the metadata guards and `return ElyxPreparedFile` at line 763.
6. `PluginElyxDeveloperTransaction.swift:185–193` awaits successful prepare before
   calling publish. Host's old-owner retirement is inside the later
   `publishElyxDeveloper`, at `PluginHost.swift:1127`; byte publication is later
   still, at line 1141. Neither is reachable from a rejected inspection.

Private candidate staging precedes inspection in the native prepare method.
The closed defect is admission to a successful prepared candidate and subsequent
old-owner retirement/publication. Untouched `installed.elyx` / `old-owner.json`
files in the Python tests are fixture receipt inputs; the real Host ordering
above is source evidence, not an executed native transaction receipt.

Load also calls the **same** validator at `_archives.py:1253–1260`, after its
existing configured-provider path setup and before Original SDK delegation.
The focused tests verify identical inspection/load refusal and zero Original
delegations for the rejected cases. Accepted controls reach the stated delegation
recorder once.

## Explicit dependency snapshot and controls

`_inspection_dependencies:725–741` obtains the existing approved provider, copies
Name / Requires-Python / Provides-Extra metadata, version and a tuple of dependency
requirements, then constructs a separate `ProvidedDependencies` with no vendor
directory. Policy evaluation performs no provider discovery or path restoration.
The existing provider factory itself retains its usual approved-vendor path setup
at `_dependencies.py:211–212`; the snapshot does not retain lazy distribution
filesystem reads.

`python/exteraless_runtime/_dependencies.py:90–150` is the real resolver: it
rejects URL requirements, evaluates markers using the running interpreter/OS,
checks approved distribution presence/version/Python version, validates requested
extras and recursively checks active dependencies. Snapshot creation reads
approved bundle metadata (`153–213`), rather than importing the candidate wheel
or its plugin. These paths contain no pip/download or permission-grant operation.

**Fresh checks:** the three sealed `load_policy_*` children all passed under
CPython **3.12.10**, `-I -S -B`, run independently in parallel with **20 seconds per
child / 30 seconds outer bound**; total wall time **0.734 s**. Their cases cover
empty/nonempty requires, `>=99`, invalid `>>>3`, compatible `>=3.0`, provided and
mismatched versions, missing wheel dependency, URL requirement, and native-member
refusal (`tools/compat/tests/test_ios_elyx_source_authority.py:243–346`).

One additional bounded, isolated helper replayed the exact archives above and
checked the remaining declarative controls through the same FD inspection hook:

| Control | Observed result |
|---|---|
| Empty requires + compatible wheel + provided `cachetools[feature]>=8`, with declared extra and provided `idna` dependency | Accepted metadata |
| Unknown requested extra | Rejected: `does not provide extras ['missing']` |
| Declared extra activates an absent transitive dependency | Rejected: missing provided `idna` |
| Absent dependency with inactive `python_version < '0'` marker | Accepted metadata |
| Same dependency with active `python_version >= '0'` marker | Rejected: missing provided distribution |
| Known declared permission `native` | Preserved as metadata only; no grant operation in the reviewed route |
| `permissions=['native', 'native.unknown']` | Rejected: `MetainfoError: unknown permission 'native.unknown'` |

All **nine inline cases**, including the two exact witnesses, observed one
release before return/error. No `ElyxPlugins.*`, candidate wheel `own`, or SDK
plugin loader module was imported. The helper verified that the inspection
snapshot is a distinct provider/metadata copy. Fixture distribution versions are
explicit test inputs, not an app-vendor installation receipt.

Unknown permission rejection remains the Original SDK validator at
`python/sdk/extera_utils/metadata_parser.py:205–228`, reached by Elyx metadata
parsing. Successful policy checking does not convert declared permissions into
native consent.

## Preserved behavior and evidence boundary

- Ordinary `_inspect_archive_bytes`, `inspect_archive`, `read_metadata` and
  `metadata_json` preview retain their parse-only behavior. The sealed tests
  still preview valid-but-unloadable archives before FD candidate refusal.
- A **memory-only inverse** of the two added helpers, the FD-inspection call and
  the record-loader replacement reproduced the exact preceding `_archives.py`
  hash: `f68ed0c19989f959fd376fe94a3ca75365ade9be0e68244de3c29ab5a204773e`.
  No file was reverted. This anchors preservation of native-wheel/bytecode
  restrictions and the `darwin`/`ios` selector; `_audit_paths.py` also still matches
  its preceding platform-fix pin.
- The owner's **12 passed / 3 POSIX skips** is retained as its reported broader
  receipt. This review freshly ran only the three focused children plus the
  bounded inline controls described above.
- No C gate, native FD registry, Swift Host retirement or iOS filesystem execution
  is claimed by the contract recorder. The native owner's fifth real C/Swift case
  remains the forthcoming execution evidence for the actual before-retire path.
  Known policy admission is closed here; arbitrary entry execution is not
  pre-executed or certified by metadata inspection.

No implementation/previous report was edited, and no CI, account, network or
foreign-plugin operation was used.

## Read-time pins

Raw-byte pins rechecked at **2026-11-15T23:21:27Z** (machine UTC); native route
spans captured at **23:21:55Z**. The sealed source/test remained identical through
the checks.

```text
3d81fa189e30fa98d90c7abc9551b2709e2af8d6a5da8bf2c20b9cea47d342fe docs/wave-2/elyx-nfd02-inputs.json
e8970fc67bdb0778418476eb37496477c405e817326720ea29de6e0abc98c9f7 docs/wave-2/elyx-archive-remediation.md
b025b0368fa0ae787e14701073c4b0116cf1378a938bc27bd47d3ceede0cae08 docs/wave-2/reviews/native-elyx-fd-authority-review.md
7238088539f31c414307e1f9e8b986940a87d4525ce6b31e5020b09871b555da python/exteraless_runtime/_archives.py
d0a4b5a51ad04c9e582c0c74453a8b924d7629b449574e9f5679f674c022ba23 tools/compat/tests/test_ios_elyx_source_authority.py
30669ce63a2d5707a0ef34b89a0b93a7e96517f103cb40a31a6d1f5acfa61a16 python/exteraless_runtime/_dependencies.py
da7fcc6c4c5ea4cef9fbb7576f26f858eb63276961569a7fe1d8f6aef0b8b40e python/exteraless_runtime/_audit_paths.py
a2b999fb1113249c557a5c9fb90e57476b06bac05b597b9bbebb3e688e926690 python/exteraless_runtime/_elyx_developer.py
272d66cc7a86606b45114ed4f8596524d2a4435b5805a66d48a92bc5587e0c13 python/sdk/extera_utils/metadata_parser.py
```

Span hashing: inclusive lines, UTF-8/LF, original indentation, one terminal LF;
Python decorators included. `A` below means `python/exteraless_runtime/_archives.py`;
`H` means `swift/PluginHost/Sources/PluginHost/`.

| Span | Lines | SHA-256 |
|---|---:|---|
| `A#_preflight_load_policy` | 694–722 | `73f383ab02a0d97844312bfb362dfa968ceedf8ba57d6c8a568055a9f77aa6a7` |
| `A#_inspection_dependencies` | 725–741 | `f07c847e723b539b9ba1f81b33817c44b2469964eb69e0800a22df20fe0b8198` |
| `A#_native_source_read` | 855–864 | `e5cacb8340efe9d2ffee030f2172ce957f5a015cf99a2299eb6749869b9a17d4` |
| `A#inspect_developer_descriptor` | 867–877 | `49cf8712edbf834375bccb1d39a44d15956941364639a8d5fb062ec1bdc4a82d` |
| `A#ArchiveAdapter._load_record` | 1253–1260 | `1979f842f3062bd696b622439944ff759a80288e5d4d084870cf951a165069ff` |
| `H/PluginElyxDeveloperFiles.swift#prepare` | 730–765 | `3956c990e4fa6b9d0d67dfaf7063ebaa4ca519dfa2332a930b4d5092317a16d9` |
| `H/PluginHost.swift#inspectElyxDeveloperDescriptor` | 1018–1055 | `5d2336d961b315be1e3fbd43a58f74aab57c39a35c6addd0301fb8964d064663` |
| `H/PluginHost.swift#publishElyxDeveloper` | 1107–1160 | `b4bf03ea332f7359b512c201f457a065d85eac0c809be95d87a1316bfcca455a` |
| `H/PluginElyxDeveloperTransaction.swift#candidate-to-publication` | 185–193 | `a944f409b0284e3c359dc00ce21313924cc111c353312a216d1610fbaf13f9ef` |
