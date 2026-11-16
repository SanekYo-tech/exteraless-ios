# Elyx C gate — fresh bounded ABI validation

**2026-11-16: 7 passed on CPython 3.12.10 and 7 passed on 3.14.8; zero
failures, errors or skips in the final runs.** Both extensions were freshly
compiled from the current C bytes into separate approved TEMP build directories.

This receipt covers the real `xt_elyx_source` C gate with an explicitly installed
native C recorder. **Native FD-registry and Apple execution are not established
by these results.**

## Authored files and build method

- `tools/compat/tests/test_elyx_c_gate.py`: build driver and seven isolated cases.
- `tools/compat/tests/fixtures/elyx_c_gate_probe.c`: native recorder, pending-error
  injection, actual module-clear-slot invocation and response-free observation.
- `docs/wave-2/elyx-c-gate-validation.md`: this handoff.

The binaries are **test-instrumented extensions**, not shipping artifacts. The
fixture includes `python/bridge/_exteraless_bridge.c` directly, with its source
bytes unchanged, and exports the genuine `PyInit__exteraless_bridge`. Its sole
bridge instrumentation redirects `free()` through an observer which calls the
normal allocator's `free()`. No dispatcher, identity, marshalling, handle-table,
GIL or terminal-state implementation is substituted. A second, main-interpreter
test module installs the recorder via the actual
`EXLPythonBridgeInstallDispatcher` / `EXLPythonBridgeUninstallDispatcher` ABI.
Responses use the real `EXLPythonBridgeBufferCopy`; the observer counts their
actual destruction by the bridge, including error paths.

Builds use the existing setuptools installation under Python 3.11.9 and MSVC
`14.51.36231/HostX86/x64/cl.exe`, with each target Python's own headers, import
library and extension suffix. Each build has independent `build-lib` and
`build-temp` directories. The driver bounds compile/link to **120 seconds**;
measured compile/link times were **3.750 s / 3.891 s** (3.12 / 3.14).

Each test child runs with `-I -S -B`, imports both C modules by the exact staged
binary path, validates its SHA-256 and current C/header/fixture/contract pins,
and has a **30-second** subprocess deadline. The OWN_GIL rendezvous itself is
bounded to two seconds. Pytest third-party plugin autoload is disabled.

## Exact source and binary pins

| Input | SHA-256 |
|---|---|
| `python/bridge/_exteraless_bridge.c` | `2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2` |
| `python/runtime/include/EXLPythonBridge.h` | `6ecab9d92438e62bd3f0d7218f9646b78f9e3f764cc5d4e9f9e5a78b85b6166d` |
| `docs/wave-2/elyx-source-descriptor-v1.json` | `7c1d62d040f75b900bdd0ece50335797fd0596fde5ddb38f8e77b449c3e3c83c` |
| `tools/compat/tests/test_elyx_c_gate.py` | `040e0e607172dceac14b0b22531093b8ca5c5fd9d8073a1f983e438794fba879` |
| `tools/compat/tests/fixtures/elyx_c_gate_probe.c` | `fad9f8b5ceb5063fe5e6024615c30d7b0ed541002826708e3eba59b811fe8161` |

TEMP root: `C:/Users/sasha/AppData/Local/Temp/opencode/`.

| Fresh binary, relative to TEMP | SHA-256 |
|---|---|
| `elyx-c-gate-py312-r3/build-lib/_exteraless_bridge.cp312-win_amd64.pyd` | `cafcbcbb9ab712122f139e91870bb719d404601cc5fc99369e22c244c2146d4a` |
| `elyx-c-gate-py314-r3/build-lib/_exteraless_bridge.cp314-win_amd64.pyd` | `ceeb6fe8ed3d54e73662d2694840f3404baf3041e2e83f6bdc2d3cba8855049a` |

The project C/header/fixture hashes were checked before and after compilation,
in every worker, and again when assembling this receipt.

## Observed contracts

The following counts are **per Python version**; both versions produced the same
native metrics. Calls count actual entries into the C recorder, including its
deliberate error responses.

| Case | Native calls | Response buffers freed/allocated | Registered contexts released |
|---|---:|---:|---:|
| `preflight` | 12 | 12/12 | 1/1 |
| `identity` | 9 | 9/9 | 1/1 |
| `responses` | 26 | 25/25 | 26/26 |
| `retention` | 2 | 2/2 | 2/2 |
| `terminal` | 1 | 1/1 | 1/1 |
| `legacy_bypass` | 5 | 5/5 | 1/1 |
| `own_gil` | 6 | 6/6 | 1/1 |
| **Total** | **61** | **60/60** | **33/33** |

The empty-response fault accounts for the one call without an allocated buffer.
Outstanding tracked response buffers, releases during active callbacks and
reported GIL faults are all **zero**.

1. **Pre-dispatch bounds:** 26 rejected calls cover argument types/arity/keywords,
   invalid operation spelling/length, embedded NUL, empty/oversized payloads,
   and unencodable Unicode surrogates. Each rejection adds zero native calls.
   All five operations accept exactly 4096 UTF-8 bytes, using both ASCII and
   multibyte JSON controls; 4097 bytes are rejected. Escaped JSON `\u0000` is
   distinguished from an actual embedded NUL.
2. **C-owned caller context:** the recorder verifies both the ABI caller bytes
   and the exact envelope. An unset ID yields `@elyx-inspection` and a present
   `ownerToken: null`. Binding an ID changes that context; a later token binding
   adds its exact immutable value. Same-value binding is idempotent. Unset,
   malformed and different-value attempts fail without altering later calls.
   Nested forged IDs/tokens/op/fd/handle fields stay payload text for every
   operation. A str subclass cannot author the outer context. Switching the
   existing desktop handle realm does not switch owner identity.
3. **Exact error boundary:** missing dispatcher raises `RuntimeError` before
   binding and the exact bound `GateError` afterward. Eighteen malformed response
   cases cover null/zero/oversized buffers, UTF-8 versus UTF-16, invalid JSON,
   embedded-NUL tails, envelope shape, typed Bool `ok`, missing value/error
   message, invalid byte tags and a dangling handle. Native refusal retains its
   kind and Unicode message; nonzero status retains its code. Real C callbacks
   deliberately leave `PyErr` pending with status 0 and 29: both become the
   pending-exception bridge error, with clean successful calls immediately
   afterward. Every allocated response is freed on these paths.
4. **Retained registration:** an occupied installation returns -2 without
   taking context ownership; a mismatched detach returns -1. Detaching inside
   the active callback keeps that context alive through the rest of the
   callback, releases it once after return, and blocks subsequent gate entry.
   A replacement registration then works and drains normally.
5. **Terminal state:** the actual `PyModuleDef.m_clear` slot runs twice. A retained
   handle's finalizer tries all five operations during clear; all are rejected
   by the built-in `RuntimeError`, without invoking the bound error constructor
   or the dispatcher. All five operations also reject after clear. The handle's
   weak reference is dead. Closed-state rejection precedes argument parsing;
   handle-count access itself rejects once terminal.
6. **Legacy bypass:** actual `xt_register_service` entries include `java.call`
   and Elyx-looking names. A tiny explicit manifest permits a real
   `BridgeBackend.call` positive control: exactly one legacy callback executes.
   Gate calls produce **zero legacy callbacks**, both when native dispatch is
   missing and when installed. Installing the existing mock afterward still
   cannot satisfy a gate call.
7. **Two OWN_GIL owners:** Python 3.12 uses `_xxsubinterpreters.create(isolated=True)`;
   3.14 uses `concurrent.interpreters.create()`. Real interpreter IDs 1 and 2
   simultaneously enter the same native recorder on their calling threads. The
   first waits without `PyEval_SaveThread`, and the second releases its bounded
   rendezvous: `peak_active=2`, two arrivals, one successful overlap, no timeout.
   Both start with exact inspection context, then retain distinct child tokens.
   The parent deliberately shares child one's plugin ID but retains its own
   token, including after both children dispatch.

All six open-state cases end at `xt_handle_count() == 0`. The identity case also
keeps an existing sentinel handle unchanged through gate calls and releases it
explicitly. Terminal cleanup is checked by finalizer/weakref evidence because a
closed module correctly refuses further handle-count queries.

## Helper-class causal counterexample (CoreSky question)

The `responses` child executes this owned minimization against the real,
unconfigured gate:

```python
class Helper:
    receipt = bridge.xt_elyx_source("claim", "{}")
```

It raises `RuntimeError: bridge: native Elyx source dispatcher is not installed`,
with zero dispatcher entries. Class creation/continuation never completes:
the failure is in the helper's class body, before any later plugin-class
selection. Catching exceptions while enumerating helper classes cannot repair
that missing native prerequisite. This is a bounded causal example for the
helper-class question, not a CoreSky source diagnosis or external-plugin run.

## Execution boundary

These Windows desktop tests exercise the current C extension, real C
`BridgeBackend`, immutable interpreter context, response allocator/decoder,
handle ownership and native dispatcher retention. The recorder does **not**
issue capabilities, hold file descriptors or implement any native source
registry. Its echo reply and opaque input payloads are deliberately transport
controls, not valid Elyx claims or readiness proofs.

Payload JSON syntax and descriptor/operation schemas are provider/consumer
boundaries: for example, the C recorder receives `not-json` unchanged. The C
decoder checks the existing `{ok,value/error}` envelope; exact claim/read/check/
release proof validation lives in the native provider and `_NativeSourceRead`.
The latter was inspected as source only. No Elyx archive was loaded and Windows
POSIX limitations were not replaced by positive load results.

Native FD custody/version/namespace checks, native Developer/Swift Host wiring,
Apple Foundation/UIKit/device execution, production RPC and a new Mac snapshot
remain outside this receipt. The existing C219 state/handle/account-SID probe is
separate evidence; this gate test uses the existing interpreter/realm APIs.

Static raw-byte comparison after the runs confirmed **36/36 OriginalSDK Python
files byte-identical** between `python/sdk/` and
`third_party/exteraless-android/TMessagesProj/src/main/python/`. Their individual
hashes are in the local aggregate receipt. All authored changes are the three
files listed above; shared C/provider/archive sources, SDK inventories and
workflow integration remain coordinator/owner inputs.

## Commands and receipts

Working directory: `C:/exteraless-ios`. Recorded build commands (the builder
requires a fresh output directory):

```powershell
py -3.11 -X utf8 -B tools/compat/tests/test_elyx_c_gate.py build 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\python.exe' 'C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-py312-r3'
py -3.11 -X utf8 -B tools/compat/tests/test_elyx_c_gate.py build 'C:\Python314\python.exe' 'C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-py314-r3'
```

Final focused runs:

```powershell
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
$env:EXTERALESS_ELYX_C_GATE = 'C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-py312-r3\build-lib\_exteraless_bridge.cp312-win_amd64.pyd'
py -3.12 -I -X utf8 -B -m pytest tools/compat/tests/test_elyx_c_gate.py -q -p no:cacheprovider --basetemp='C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-tests-py312-r2' --junitxml='C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-py312-r2.xml'

$env:PYTHONPATH = 'C:\Users\sasha\AppData\Local\Programs\Python\Python312\Lib\site-packages'
$env:EXTERALESS_ELYX_C_GATE = 'C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-py314-r3\build-lib\_exteraless_bridge.cp314-win_amd64.pyd'
py -3.14 -X utf8 -B -m pytest tools/compat/tests/test_elyx_c_gate.py -q -p no:cacheprovider --basetemp='C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-tests-py314-r2' --junitxml='C:\Users\sasha\AppData\Local\Temp\opencode\elyx-c-gate-py314-r2.xml'
```

Python 3.14 uses the existing pure-Python pytest installation via `PYTHONPATH`;
its actual fixture children discard that path with `-I -S`. Console results were
**7 passed in 0.93 s / 0.98 s**; JUnit suite times are **0.818 s / 0.932 s**.

| Receipt, relative to TEMP | SHA-256 |
|---|---|
| `elyx-c-gate-py312-r3/build-inputs.json` | `0064df56598012b0e1d5212240665bb00124917d32167ba285e248b1feb170af` |
| `elyx-c-gate-py314-r3/build-inputs.json` | `25a1654364d0901b51faa8626cf22550c8c55b75d88199ab799bbcf625b15b7e` |
| `elyx-c-gate-py312-r2.xml` | `4fb240318aadd440c62c9b213a481b3cbe99b75ae797a9496fcfa11419a357e3` |
| `elyx-c-gate-py314-r2.xml` | `9a24d3952c4d89896a374233d651fe67b6530779877754991497e722a2312a38` |
| `elyx-c-gate-validation-receipt.json` | `8307d7423df6a3bf602f68d94ef52a211a62d2f35a93d2227d61a7b2ebe61782` |

The aggregate contains the 14 individual child-report hashes, current source
pins, binary/build-log hashes, exact native metrics, JUnit counts and all 36 SDK
file hashes. Native-gate snapshot owners can consume the two new test sources
and this receipt alongside their current C/header/contract snapshot; native FD
provider validation requires its own real-provider execution.
