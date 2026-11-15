# P2 remediation: reentrant handle clear — 2026-11-15

Remediation of the confirmed ownership leak in
[`reviews/native-owner-token.md`](reviews/native-owner-token.md). That independent
report was not edited. The reproduced finding was a lost C reference; this note
does **not** assert a baseline use-after-free or crash. Ready for independent
re-review against the source/artifact fingerprints below.

## Implementation

### Explicit clear

`realm_drop_entries` (`python/bridge/_exteraless_bridge.c`, line 702 in this
snapshot) first moves the handle array, reverse array and old capacity into local
variables. Before the first DECREF it publishes NULL arrays and zero live
capacities/counts. `key`, `in_use`, and monotonically increasing `next_handle`
are preserved.

The loop decrefs/frees only the detached snapshot. A finalizer's registration
therefore enters a new live table; a recursive clear sees that new table, not the
outer snapshot. Switching test realms or registering a C service during a
finalizer cannot make the outer clear reset the new state. No native registry
mutex spans a DECREF. The original Python exception is preserved around cleanup.

Consequently `xt_clear_handles()` can return with newly registered handles when
user finalizers deliberately create them. Those handles remain counted,
resolvable and releasable. This is explicit-clear behavior; terminal clear has
the stricter admission rule below.

### Terminal admission and owned references

`state_release_objects` (line 3637) marks the module state closed before anchor
invalidation or any DECREF, and repeated clear/free calls are idempotent.
`state_require_open` is used by the module, backend and current-interpreter
state accessors. Captured methods cannot bypass closure by holding the module
object directly. Reentry raises builtin `RuntimeError` without constructing a
user-bound exception type.

The terminal probe checks all **27 Python-visible entry paths**:

- 17 module methods, including identity binding, native dispatch, every handle
  operation, `xt_bind`, and the five process-registry/pointer helper methods.
- Nine backend operations: the seven native operations, `member_kind`, and
  `class_exists`.
- `BridgeBackend` initialization.

The C `xt_host_release_handle` path is additionally checked after explicit module
clear. It rejects the dead state under the already-held owner GIL.

The module's nine owned Python fields remain paired with traverse/clear logic:
`JavaInstance`, `JavaMemberError`, `backend_type`, `plugin_id`, `owner_token`,
`json_dumps`, `json_loads`, `dumps_kw`, and `mock_log`. The C manifest allocation
and both arrays of each realm are freed by their existing owners.

### Backend GC edge needed for real interpreter teardown

The first real `Py_EndInterpreter` validation recorded zero terminal-finalizer
calls. The ownership scan found the untraversed cycle:

```text
heap type -> module -> handle table -> JavaInstance -> BridgeBackend -> heap type
```

`BridgeBackend` now has GC tracking, traverse and clear slots. Traversal includes
its implicit heap-type reference and its three owned fields (`service`,
`fields`, `classes`); deallocation untracks before clearing. A cleared backend
rejects operations/reinitialization before finalizers can repopulate its fields.
With these edges visible, the unchanged real-End test executes the finalizer and
releases the resulting native payload.

The handle transaction ledger, owner-token representation, public C callback
ABI, engine and CPython compatibility layer were not changed by this remediation.

## Observed fresh verification

Windows CPython **3.12.10**, native `EXL_ENGINE_DEBUG_MEMORY=1`, desktop
`PYTHONMALLOC=debug`; each child process has a **30-second external timeout**.

- **219 native dispatcher calls passed**: all previous **213** plus **6** bulk
  clear calls. The original **169-call** subset is retained.
- Six explicit-clear groups run on each of two OWN_GIL workers: finalizer
  registration, recursive clear, explicit self-retention, native marshal inside
  a finalizer, 320-object reentrant table growth, and realm/service-registry swaps.
- Standalone safe reproduction: **new handle 2, count before release 1,
  release True, weakref alive False**. Liveness/count are checked before lookup.
- Forced terminal module clear: all **27 admission paths rejected**, repeated
  clear is idempotent, and one rejected registration's native payload is freed.
- Actual `Py_EndInterpreter`: native counters verify the finalizer and payload
  destruction. CPython may run a GC finalizer **before** `m_clear`; this run had
  one still-live admission at that earlier phase, and that payload was freed
  before End returned. Already-dead rejection is also accepted by this test.
  Across both terminal cases: **2 payloads created / 2 freed**.
- After End, the driver examines only native counters. It never executes Python
  in the destroyed child or reads/decrefs a retained child Python object.
- Existing desktop bridge tests: **24 passed, 1 skipped**. The skip is the
  Python-3.14 `concurrent.interpreters` test; native OWN_GIL coverage ran in C.
- `git diff --check` passed. No new iOS/macOS or CI execution is claimed.

## Reproduction and matching artifacts

Exact local build/run command (the launcher uses Python 3.14's MSVC tooling;
compiled/embedded Python is the explicit matching 3.12 installation):

```powershell
py -3.14 "C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-bulk-clear\check.py"
```

Artifact directory:
`C:\Users\sasha\AppData\Local\Temp\opencode\exteraless-native-bulk-clear`.
It contains `remediation-report.json`, `full-source-fingerprint.json`, the freshly
linked executable/extension, `native-console.log`, `weakref-console.log`,
`legacy-console.log`, and the standalone `weakref_regression.py`.

The **24-input full native fingerprint** follows the existing validator's source
set, including all native `.c/.h/.m/.modulemap` files, rather than only linked
translation units. It was captured before compilation and matched after all
three child processes. No old artifact fingerprint was rewritten to bless a
changed binary/source tree.

| Input/artifact | SHA-256 |
|---|---|
| `_exteraless_bridge.c` | `f9a94d4ed8cbaa7fae9e23f7b232313fa838a89c5407b60a603cebcea277f92a` |
| `bridge_callback_probe.c` | `dcd6a1d08e4ff17160ba37a527192637218506191587e629f3a519310f2e755a` |
| `bridge-callback-probe.exe` | `cc1757d06af1e19b379399e9361a62fbb0b53dabf08423aac66782d365ec1415` |
| `_exteraless_bridge.cp312-win_amd64.pyd` | `0a95124fbae6b045992b700d60690445dc42d72e68413c62d4736460cfc35f0f` |
| Unmodified independent review | `2c3938f5814133b9bf652a71b6697c552c2c2dc6a43bffec1a4cb18ec1835a52` |

These hashes identify the tested snapshot. Any subsequent native-source changes
require a new build and matching fingerprint before component CI or re-review.
