# ELYX-GAP-01 — independent archive source-closure review

2026-11-15. **Verdict: PARTIAL / NOT CLOSED.**

The previous `.elyx/.eaf` admission, preserved-extension installation, format/ID
plumbing and `requires` decoding gaps have concrete source routes now. The
requested **code-identity and filesystem-ownership closure still has three P1
defects** below. Four small Windows helper witnesses confirmed the relevant
branches without executing plugin code. Darwin/Swift/iOS archive execution is
pending; `native_execution_claimed: false`.

Reviewed implementation:
[`elyx-archive-remediation.md`](../elyx-archive-remediation.md), plus the applied
UI/Core hunks from
[`elyx-archive-coordinator.patch`](../elyx-archive-coordinator.patch).
This report does not promote the historical 262-symbol map or reuse old
Mac20/e16/runtime acceptance as archive execution evidence.

## Remaining findings

| Finding | Priority | Main source location | Result |
|---|---|---|---|
| ARCH-01 | P1 | `python/exteraless_runtime/_archives.py:372–394` | Source-backed cached bytecode escapes recursive filename rebinding. |
| ARCH-02 | P1 | `_archives.py:578–582,672–695`; `python/sdk/extera_utils/audit_gate.py:661–679` | Executable cache files lose the existing protected-plugin-code boundary and are reread without member-hash enforcement. |
| ARCH-03 | P1 | `_archives.py:528–553,672–695,733–757`; `PluginServiceStorage.swift:79–99` | Checked ancestor names are reopened through mutable paths; extraction and purge are not fd-relative/nofollow through every component. |

### ARCH-01 — cached `.pyc` under a `.py` route retains forged nested filenames

**Location:**
`python/exteraless_runtime/_archives.py:372–394`, especially the
`isinstance(..., SourcelessFileLoader)` condition at line 373.

The archive validator accepts compatible `.pyc` members, including ordinary
`__pycache__/name.cpython-312.pyc` paths (`:76–86,220–222`). The preserved SDK
selects `SourceFileLoader` when a `.py` member exists
(`python/sdk/elyx_runtime/namespace.py:139–147,338–347`). That loader can read an
archive-supplied unchecked-hash cache even with `writeBytecode=false`.

The new wrapper recursively relabels code only for **SourcelessFileLoader**.
CPython's source-loader cache handling repairs the outer code filename but
does not repair a nested code object which already has a different filename.
That is not equivalent to the adapter's recursive `code.replace` operation.

**Minimal reproduction:**

1. Supply `main.py` plus its compatible unchecked-hash cached `.pyc` in a tiny
   owned archive. The cache's outer code is labelled `unowned-build/main.py`;
   one nested function is separately labelled
   `unowned-build/forged_callback.py` using `CodeType.replace` before marshaling.
2. Select `main.py` in refmap, or import a source-backed helper with that cache.
3. Obtain code through the real `_owned_module_exec` and `SourceFileLoader`.
   The nested filename remains the forged value. A direct `.pyc`/Sourceless
   control is relabelled correctly.

Independently observed on **CPython 3.12.10 / Windows**, using `get_code` only:

```json
{
  "source_top_filename_rebound": true,
  "source_cached_nested_filename_rebound": false,
  "source_cached_nested_filename": "unowned-build/forged_callback.py",
  "sourceless_nested_control_rebound": true,
  "plugin_code_executed": false,
  "native_execution_claimed": false
}
```

**Why P1:** source/member paths are registered at `_archives.py:683–685`, but
the surviving function label is not one of those paths.
`plugin_loader.py:819–835,854–866,892–926` attributes execution through
`co_filename`. `audit_gate.py:506–508` exits when no plugin frame owner is
found. A subsequently dispatched function with a nonexistent forged filename
can therefore lose its plugin attribution; the bound C owner token does not
repair the Python audit's early return. The source-loader branch also bypasses
the new code-graph depth/node check at `_archives.py:378–386`.

**Required closure:** apply the owned-code transformation to code returned by
both source and sourceless loaders, or reject archive-supplied source caches
and guarantee compilation from the captured source bytes. The regression must
include an unchecked-hash source cache with **different outer and nested
filenames**, assert every nested filename/owner, and assert an ungranted
file/network audit operation remains denied when the callback is dispatched.
`case_bytecode_owner` in `tools/compat/tests/test_ios_elyx_archives.py:455–469`
currently covers a direct `.pyc` entry, not this branch.

### ARCH-02 — moving executable content to cache removes its protected-write rule

**Locations:**

- New executable location/materialization:
  `python/exteraless_runtime/_archives.py:578–582,672–695`.
- Protection still limited to the old plugins tree:
  `python/sdk/extera_utils/audit_gate.py:661–679,756–771`.
- Native audit roots/override:
  `python/exteraless_runtime/_audit_paths.py:150–153,188–231`.
- Subsequent file-backed execution:
  `_archives.py:372–394` and
  `python/sdk/elyx_runtime/namespace.py:217–227,311–347`.

The old `.elyx_extracted/<id>/.../*.py` location was below `plugins_dir`, so the
SDK protected-write rule classified it as **plugin code**, requiring the
trusted `hooks` capability. New executable paths live below
`cache/<id-hex>/elyx/<owner>/<digest-load>/contents` instead.

`_protected_reason` returns at `audit_gate.py:670–671` for paths outside
`plugins_dir`, before checking executable suffixes. The iOS override does not
add archive cache roots to that rule: trusted runtime capture excludes native
cache roots, while the native protected paths published by
`TelegramPluginServices.swift:180–188` describe the client settings location,
not these archive execution directories.

A currently active **other** plugin with `files`, but without `hooks`, can
therefore modify these files using normal filesystem operations. This is a
representable capability set: `PluginTrustLevel.swift:26–32,58–61` permits
ordinary file consent at `.gated`, while dangerous `hooks/native` remain capped.
This finding does not depend on an expired worker passing native owner checks.

The captured ZIP `bytes` are immutable, but execution is still file-backed.
`member_hashes` is calculated at `_archives.py:519` and has no verification
consumer in the current adapter. A later helper import rereads changed disk
bytes under the victim's already registered member filename.

**Minimal reproduction:** load archive A with a not-yet-imported helper. From a
current files-only owner B, rewrite A's helper under its discoverable native
cache path. Let A import it. The code is attributed to A; neither the unchanged
captured ZIP digest nor `member_hashes` prevents reading the replacement.
No mutation of SDK globals or forged C identity is required.

Independent bounded helper witness, without executing the returned code:

```json
{
  "legacy_extraction_protection": "plugin code",
  "native_cache_extraction_protection": null,
  "materialized_source_no_longer_matches_captured_hash": true,
  "changed_code_object_accepted": true,
  "plugin_code_executed": false,
  "native_execution_claimed": false
}
```

The policy part evaluated the **exact production** `_protected_reason`,
`_within` and associated constants with the native settings/plugins layout.
The I/O part called the actual `_materialize` and source-loader wrapper with a
fixture ownership registry; it wrote only disposable owned files. Native
permission dispatch was inspected, not executed in this witness.

**Required closure:** protect archive executable roots and relevant ancestors
from files-only cross-owner writes, and make the executed bytes derive from
the captured member or an identity/hash-validated, pinned read. A hash checked
separately from a later pathname open is insufficient. Add a two-owner
files-without-hooks regression covering lazy source import, cached bytecode,
rename/replacement and symlink replacement. Verify both denial and unchanged
victim code; an ordinary same-filename reload test does not cover this.

### ARCH-03 — ancestor checking is not an fd-relative extraction/purge invariant

**Locations:**

- `_cache_root/_mkdirs`:
  `python/exteraless_runtime/_archives.py:528–553`.
- Extraction/open:
  `_archives.py:672–695` (`os.open` has nofollow only for the final file).
- Python cleanup:
  `_archives.py:733–757` (`shutil.rmtree(self.root)` reopens a full path).
- Native uninstall cleanup:
  `swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift:79–99`.

The code correctly rejects an already present symlink/reparse point when the
named component is checked. It does **not** hold an opened directory identity
across subsequent operations. `_mkdirs` checks a component with `lstat`, then
later calls `mkdir/open` by full pathname. Cleanup similarly checks parents,
then calls `lstat/rmtree` through those names again. `O_NOFOLLOW` on the final
file does not constrain a changed ancestor.

**Deterministic reproduction:** pause immediately after `_directory(owner)`
has accepted a real directory. Rename that checked directory aside and replace
its name with a link to another disposable directory. Resume the operation.

- `_extract` creates `<digest-load>/contents/probe.txt` in the link target.
- `cleanup` deletes the target's matching `<old-load>` tree, while the original
  checked tree remains in the renamed backup directory.

Both were independently exercised with **owned Windows directory junctions**:

```json
{
  "extraction": {
    "parent_checked_then_swapped": true,
    "write_landed_outside_cache_root": true
  },
  "cleanup": {
    "outside_cache_fixture_tree_deleted": true,
    "original_checked_tree_still_exists": true
  },
  "all_paths_within_owned_temporary_fixture": true,
  "plugin_code_executed": false,
  "native_execution_claimed": false
}
```

The interposition wrapped `_directory` **after its real check**; it did not
make the check report a false type. Extraction used the production `_extract`
and `_materialize` bodies. Cleanup used the production filesystem cleanup body
with no-op fixture SDK-registry removal. Every link/target was inside a fresh
approved temporary directory and was removed afterwards.

Darwin's fd-safe `shutil.rmtree` can protect the tree it opens, but it cannot
restore the identity of an ancestor already replaced **before** the root open.
The native method has the same source-level gap: it reads component attributes
and then invokes `FileManager.removeItem(at: target)` through the pathname.
That native branch was **not executed** on Windows. The per-ID Host mutation
reservation prevents a competing Host install; it does not pin filesystem
ancestors against a current files-capable writer.

**Required closure:** hold directory descriptors/identities from the trusted
native cache root, traverse/create/open/unlink relative to those descriptors
with nofollow, and verify the name-to-owned-inode relationship where removal
needs it. Native purge needs the equivalent invariant. The existing Core
descriptor implementation in
`swift/ExteralessCore/Sources/ExteralessCore/ToolsFileDescriptors.swift:133–188,195–220,278–307`
illustrates such primitives, but it is **not** on either archive cleanup route.

Add an interposed-parent-swap regression at extraction **and** purge, including
native `purgeArchiveCache`, rather than only a pre-existing-link test. Assert
the outside tree is untouched and a replacement generation survives. Current
`case_symlink_cache:412–432` and
`PluginArchiveHostTests.testNativeArchivePurgeRejectsSymlinkedParent:235–247`
cover static links/child-link cleanup, not this check/use interval.

## Closure of the previous functional gaps

These are source conclusions for the pinned snapshot, not native run receipts.

| Previous issue | Actual current route | Source conclusion |
|---|---|---|
| UI rejects archive suffixes | `PluginManagerController.swift:498–507,530–540,553–607` | `.plugin/.py/.elyx/.eaf` selection is connected; selected extension is preserved through the UI copy. |
| Current UI archive copy budget | `PluginManagerController.swift:577–593` | 64-KiB reads; accumulated bytes checked against 32 MiB before writing each chunk. Source files retain their separate existing copy branch; this is not a universal cap for all file types. |
| Native inspector/load reject archives | `PluginHost.swift:926–943,1400–1422`; `__init__.py:43–58,188–214` | Format reaches inspection and load; both archive suffixes are admitted, including the explicit upper-case SDK-dispatch adaptation. |
| Installation changes archive to `.plugin` | `PluginHost.swift:963–1008`; `PluginModel.swift:3–18` | Format-specific installed extension; archive filenames use ID plus UTF-8 hex, preserving ID and case isolation. |
| Mutable picker metadata retires the old owner | `PluginHost.swift:982–995` | Bounded native copy → inspect the staged archive → same-ID guard → preserve enabled choice → retire old owner. Reinspection failure precedes retirement. The same-native-path branch also re-inspects before retirement (`:1002–1008`). |
| Format persistence/reload | `PluginModel.swift:135–156`; `PluginRuntimeProtocol.swift:51–79`; `PythonRuntime.swift:111–135` | Persisted format/legacy path inference, load path/format check, configure argument and refreshed metadata are connected. |
| Elyx ID / native filename grammar mismatch | `_archives.py:63–73`; `PluginModel.swift:205–220`; `PluginServiceStorage.swift:23–27`; `ToolsPluginSchemaCache.swift:63–74` | Archive grammar includes digit/underscore-first IDs; source grammar remains distinct; storage/Core filename codec accepts their union and excludes the inspector ID. |
| Core settings entry fails on an archive ID | `ExteralessPluginRuntime.swift:437–451` → `ToolsPluginSchemaCache.settingsFileName` | Applied Core hunk reaches the actual settings request before `host.settingsJSON`. |
| `requires` object fails native decoding | `PluginModel.swift:150,159–175`; `PluginRuntimeProtocol.swift:29–48` | Object `{min_version,url}` and native nullable-slot arrays decode. URLs remain metadata. |
| Fake cross-owner dependency support | `_archives.py:646–663` | Nonempty `requires` gets an explicit cross-owner-provider error before entry execution. Ordinary requirements and wheel Requires-Dist go to the pinned provider. |
| Mutable source filename reread for ZIP load | `__init__.py:192–204`; `_archives.py:481–520,665–670` | One captured immutable byte string is validated and used for the SDK ZIP reads. This does not close later mutable executable-file reads: ARCH-02. |
| Completion-marker / wheel-stem reuse | `_archives.py:580–582,687–707,719–723` | Fresh owner/digest/load-UUID extraction, wheel-content digest directories; no old marker/stem decision. |
| Stale normal cleanup sweeps a new generation | `_archives.py:733–764`; `PluginHost.swift:391–418,457–490,1034–1050,1458–1485` | Python selects its own recorded load root; Host holds mutation/retirement reservations and native epochs through cleanup. No broad Python plugin-ID sweep. Filesystem redirection still defeats path ownership: ARCH-03. |
| Executable `.py` metainfo/locales | `_archives.py:252–280,292–352,423–445` | AST/literal parsing replaces executable mapping seams; imports/calls/statements outside the literal subset are rejected. |

### Actual shipping call chain and packaging

The production manager factory is
`telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginManagerController.swift:50–69`.
Its import action reaches `ExteralessPluginRuntime.importPlugin:395–403`, then
the existing Host's `importPlugin/readPluginMetadataImpl/installPluginImpl`.
There is no new or parallel Host introduced by the archive adapter.

`PythonRuntimeConfiguration.bootstrapScript` passes `plugin_format`; Python
`configure` installs `ArchiveAdapter` after existing providers
(`python/exteraless_runtime/__init__.py:61–94`). `load_json` activates the
snapshot before the preserved SDK load dispatch. `_load_record` validates
dependencies, then calls the captured original SDK `load_plugin_record`
(`_archives.py:646–663`). The SDK still owns namespace/environment construction,
record attachment and outer `on_plugin_load/on_plugin_unload` dispatch.

The resource graph includes the new adapter: `prepare_telegram_runtime.py:56,260–279,334`
recursively copies `exteraless_runtime`; root `BUILD.bazel:19–30` includes
`resources/python/**`; `telegram-ios/third-party/exteraless/BUILD:23–26` aliases
RuntimeResources and `telegram-ios/Telegram/BUILD:1957` consumes it. This is a
source-graph check, not a newly built IPA inspection.

### Bounds and deliberate compatibility restrictions

Checked in the implementation bodies:

- `_preflight_zip:111–137` checks raw 32-MiB size, EOCD layout/count, 2-MiB
  central-directory size and the **actual** number of central entries before
  `ZipFile` constructs its entry list.
- `_CheckedZip:157–222` validates all paths/types/sizes/ranges in that container
  before decompression. `_Budget` is shared with nested wheel validation:
  2,048 aggregate entries, 64 MiB outer plus expanded-wheel bytes, 16 MiB/member,
  ratio 200. Inflate uses `file_size + 1`, checks EOF/tails/exact size, then CRC;
  the forged-size/prefix-CRC issue is addressed.
- Mapping limits are 256 KiB/file, aggregate 2 MiB and at most 64 locale files;
  imported data modules have a 1-MiB read limit. JSON/AST/YAML depth/node and
  primitive-value restrictions are explicit. YAML aliases/anchors/merges are
  rejected. Description replacements are charged before the final join.
- Local wheels must declare compatible pure-Python `none-any` tags, carry WHEEL
  and METADATA, and satisfy pinned provided requirements/Requires-Python before
  entry execution. Native-name/framework/signature checks and explicit `.pth`,
  `.data` relocation and nested-wheel errors are present. This is a restricted
  local pure-Python wheel route, not arbitrary Android/native wheel support.
- `_dependencies.ensure_requirements:90–150` uses existing provided
  distributions, rejects direct URL requirements and never downloads or runs
  pip. Nonempty cross-plugin `requires` is intentionally unsupported at enable,
  with the exact required IDs in the error.

The remaining defects concern identity/protection of executed content and
filesystem path races; they do not re-open the corrected ZIP size/CRC limits or
turn the explicit dependency restrictions into claimed implementations.

## Evidence and verification boundary

### Independently performed here

Four isolated `py -3.12 -I -S -B -` helper commands, each with a **30-second
outer timeout**, completed on Windows CPython **3.12.10**:

1. Source-cache code-object filename witness, with direct-sourceless control.
2. Actual archive extraction after a checked parent was replaced by an owned
   junction.
3. Exact protected-write policy comparison plus changed source `get_code` read.
4. Actual Python archive cleanup after a checked parent was replaced by an
   owned junction.

Junction creation used a five-second inner command limit. All fixture paths
were disposable children of `C:\Users\sasha\AppData\Local\Temp\opencode` and
were removed. Registry/Platform seams in these helper witnesses were explicit
test objects; no native host or plugin lifecycle execution is inferred. No
external archive, foreign plugin, HTTP, account or CI operation was used.

Data-only checks also parsed the reviewed Python files as AST and compared
**36/36 SDK Python files, including 12/12 Elyx files**, byte-for-byte with the
Original tree. These checks passed. Only this new review report is authored in
the repository by this follow-up.

### Existing owner-reported evidence

The remediation owner reports **12 Python archive passes + one Windows symlink
skip**, and **13 source-runtime passes**
(`elyx-archive-remediation.md:219–236`). I read their fixture/test source; I did
not rerun those suites or promote their results to a native receipt.

`PluginArchiveHostTests.swift` explicitly uses a fixture JSON metadata engine,
not ZIP/CPython (`:5–18`). Its staged-ID-before-retirement, preserved format,
case-ID, replacement, budget and Host reservation tests are relevant prepared
native checks. Its existence does not mean Swift ran here. The applied Core
codec test similarly remains source evidence in this review.

Darwin archive Host execution, interposed native purge tests and real iOS picker
behavior remain pending. The earlier Mac20/e16 and unrelated SDK/native passes
do not cover this adapter or the three remaining source defects.

## Source identity

HEAD observed: `897e3106618ab62a779ed26cfc3661115c0caff9`; the implementation has
working-tree changes, so the following **raw-byte SHA-256 pins** identify this
review. Concurrent lower PermissionsModel/PluginStore work is not given an
archive closure verdict. The archive-specific `PluginModel.swift` region,
lines **1–221**, separately hashes to
`f68ec53d81afa3774a9c0dfabff5f95edd83b2635450c77873b07ded1ce68ca9`
(raw `splitlines(keepends=True)` bytes, no newline normalization).

```text
1a748b9c6d3a8322e36aa1177bddaafa69bccc80924a500eb5e4e941161d2ffc  docs/wave-2/elyx-archive-remediation.md
1bde0b53e6a326a8891d8ec6faee870ce034368669972aa0147dfae2409dcd36  docs/wave-2/elyx-archive-coordinator.patch
cf1feebdc7534faf4237a76ed32b8f81fa1f8bf19bff3ef42a72c8164223c12d  python/exteraless_runtime/__init__.py
f5517d19cd481ce8c41142b0095262160fb8dd1c1d7fa802fb5943fa70ac2f8a  python/exteraless_runtime/_archives.py
b52cfc69b916a78ced37a7e9cb5fec489d28229c83caf80cb9b3359a6027c996  python/exteraless_runtime/_audit_paths.py
edce805b7fb3ef140ccf6bac731d39311dc04db52e2470f1e87cbe3212bb7dbe  python/exteraless_runtime/_platform.py
30669ce63a2d5707a0ef34b89a0b93a7e96517f103cb40a31a6d1f5acfa61a16  python/exteraless_runtime/_dependencies.py
a09eddf36ae77415fbf41e58aed3b09ccb4ce27759aea6ba9814ad8129bc0e12  python/sdk/elyx_runtime/loader.py
1b9a33a09318d0c19a7e64696028089def15cecff2a75a4c0ad6dfbde7d51966  python/sdk/elyx_runtime/namespace.py
dfedf130c7501ff0c67350ceba51ee068e8664c6faca3aaa1760b9dae4dc7bd3  python/sdk/elyx_runtime/metadata.py
d35fe1a2e0f2a28d2fce29d3b5f0fcbc7a8c05c5667b488c3c8afb180ca660c2  python/sdk/elyx_runtime/archive.py
c90134bde58559d675ffeff313eecd4223f39d60edbe0992137b41461b6547f5  python/sdk/extera_utils/plugin_loader.py
bea9ef82832a61f21537150ddb4cff5f5bd4c2ccf4fca90b0d2307d0e8c2dff5  python/sdk/extera_utils/audit_gate.py
b3f37a701aafe1704cc70fa1208b9ac1bf90d8473b67845b8fc9d8160947d83f  python/sdk/file_utils.py
d3bdb01d31f278589fbf9a083f43d44e94ea281e55c4e443dfdc696c7425865d  swift/PluginHost/Sources/PluginHost/PluginHost.swift
10a00a89ddd35dc08eeb21014aab74f77284d6064ff90e297d9eba56985383e0  swift/PluginHost/Sources/PluginHost/PluginModel.swift
1926e6aad7bd145cb0438ea56080e812e3e0fb962c963f1c7640a13b632f8c8e  swift/PluginHost/Sources/PluginHost/PluginRuntimeProtocol.swift
f2bf5c8ea2b8c9374ee13cdbdf8d04380b8758bb98e9aec7f0687295e5f6df92  swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift
1e9235e65f1fb860da218317a033d12e2b37f545b2b2dbdad33de29fce6544f1  swift/PluginHost/Sources/PluginHost/PythonRuntime.swift
5880f3e6d9a3c00fb6793de3fa286b571350fbb81f4db7287ef8a6f498ea9ca8  swift/PluginHost/Sources/PluginHost/PluginTrustLevel.swift
f6cd27841df8e616a7b4c2734d6a00c4499b53ea7cf94088f04f1c72e1947ca8  swift/ExteralessCore/Sources/ExteralessCore/ToolsPluginSchemaCache.swift
58be17374d0cf69ad690ccb3f8bb0ff0e467beabbbf260b2726a75dda464e119  swift/ExteralessCore/Sources/ExteralessCore/ToolsFileDescriptors.swift
d00e23e675e2c4b3120912caf5cf7edacc44cd84967536758a7d2f0ce8cd3986  swift/PluginHost/Tests/PluginHostTests/PluginArchiveHostTests.swift
7be6cb6571b0309b461bfa1922cd9e7960f806d1441be686a31a24a3cdaddf7b  swift/ExteralessCore/Tests/ExteralessCoreTests/ToolsArchiveIDCodecTests.swift
1ba92fe68a46e44a414d7a3e953103e975510a2832337ec4ecf22e24434a0cfe  tools/compat/tests/test_ios_elyx_archives.py
1936648c55f336a4bac0c9abcedfbb804c424a17dc81eb38eb7a0c95ee1a32c2  tools/compat/tests/test_ios_runtime.py
19ed41cc6da216871e6faaa0bcb5e91bfd043ae70f54a543513e172f8d19ea6c  telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginManagerController.swift
7d2a70683e9337fe56c2a2e33769876a908d198c24420250a48e1810dd594fa8  telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift
291507fe97af636bfd2aff7cfc60f1410712c3ec04468a6926523f9f0959ee87  telegram-ios/submodules/TelegramUI/Sources/Exteraless/TelegramPluginServices.swift
3d7489dfb28452859f9e3fadff855779a0b7ce21b83b952c8971d656e622ddef  BUILD.bazel
504ece0e8af13ddef81ec7330979614604a43fa4e27186ee7a86a1bf858d4c0f  telegram-ios/third-party/exteraless/BUILD
41d1ba1a4b595b9237f69bc6b72665b0746c4bd17833143ba43cb1175fdaebdf  telegram-ios/Telegram/BUILD
6c2ab92dac91aa722a437bfaa938bd756e42f6094a50f06a4561b20777b03709  tools/runtime/prepare_telegram_runtime.py
```
