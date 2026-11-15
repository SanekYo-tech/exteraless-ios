# Native interpreter owner epoch

The bridge owns the originating generation in per-interpreter C module state.
The coordinator registers a **fresh random UUID per InterpreterHandle**, including
reloads of the same plugin ID. It binds that exact token on the owner's worker
before SDK `bind_owner_json` and `load_json`. Do not derive it from a predictable
host ID/counter or resolve an old request using the newest owner for a plugin ID.

This addresses stale/background work from an old interpreter. It is native
provenance for the bridge protocol, not a hostile-Python sandbox boundary.

## Python API and bootstrap order

```python
# Existing worker bootstrap has bound pluginId, installed virtualjava and
# configured exteraless_runtime. The coordinator already registered CallbackOwner.
_exteraless_bridge.xt_set_owner_token(epoch)  # raw Python str, not JSON text
_exteraless_runtime.bind_owner_json(json.dumps(epoch))
_exteraless_runtime.load_json(plugin_path)
```

`_exteraless_bridge.xt_set_owner_token(token: str) -> None`:

- Requires successful `xt_set_plugin_id` in this interpreter; otherwise
  `RuntimeError`.
- Requires **1–256 UTF-8 bytes**, no embedded NUL. Wrong type gives `TypeError`,
  empty/oversized/NUL input gives `ValueError`, invalid Unicode surrogates give
  `UnicodeEncodeError`. The byte limit is stricter than a 256-character limit;
  ordinary UUID strings satisfy both C and SDK validation.
- Stores an exact, immutable Python `str`, copying subclasses without calling
  their `__str__`, `__len__`, `encode`, `__eq__`, or `__ne__` overrides.
- Repeating the same character sequence succeeds. Changing it gives
  `RuntimeError`; failed validation/binding leaves the original binding intact.
  Comparison is exact, with no normalization or case folding.
- Has no reset/get-other-owner API. Tokens are independent across interpreters,
  are not inherited from the parent, and survive handle clears/test-realm changes
  until that interpreter's module state is cleared/freed.

The coordinator remains responsible for UUID uniqueness and for binding before
user plugin code starts. The C setter does not generate a token or run Python on
another worker.

## Native request context

Both `xt_call_host` and all seven native `BridgeBackend` operations share the
same final envelope construction:

```json
{"op":"call","fqcn":"exteraless.ios.Runtime","member":"postToOwner",
 "args":[{"__handle__":1,"__fqcn__":null},0,"default"],
 "pluginId":"example","ownerToken":"coordinator-generated-random-uuid"}
```

`pluginId` is always taken from C state. A bound `ownerToken` is always taken
from C state too. If no token is bound, **the field is absent**, even when the
Python caller supplied one. Legacy/unbound calls remain usable; Swift decides
which bootstrap/legacy operations are allowed without an epoch.

Top-level context keys are canonicalized to plain strings and all supplied
identity values are discarded **before** value marshalling. This avoids both
retaining an ignored callback as a handle and Unicode-subclass/alias keys
creating duplicate identity fields in serialized JSON. Final context injection
is repeated after marshalling. Caller dictionaries are not mutated; nested
payload fields are not treated as authoritative context.

The public `EXLPythonBridgeDispatcher` C signature and counted-buffer ownership
ABI are unchanged. The trusted epoch travels in JSON. Swift must validate it
against the captured current `CallbackOwner`, with bootstrap/unload admission
gates, before scheduling callbacks or effects. An abandoned old interpreter
continues to emit its old epoch, even if its Python request claims the new one.
Callbacks/releases must retain the original owner rather than re-resolving by ID.

## Review and native verification

- One new owned `PyObject *` in `xt_state`, with matching `Py_VISIT` and
  `Py_CLEAR`; there is no process-global token registry or cross-interpreter
  Python object sharing.
- Binding/validation executes under the current interpreter GIL, using Unicode
  C APIs rather than Python equality/string hooks. Character length is checked
  before copying/UTF-8 encoding, bounding temporary token allocation too.
- The dispatcher, GIL handling, handle transaction ledger, and response ABI keep
  their existing implementation. Identity filtering is confined to the envelope.
- `bridge_callback_probe.c` retains the original **169-call** transport/rollback
  suite, then tests absent/unbound tokens, ignored forged values, alias/duplicate
  keys and hash/equality collisions, invalid types/UTF-8/NUL/oversize, the exact
  256-byte boundary, canonical subclass
  copying, repeated binding, rejected rebinding, and all seven bound operations.
- Two OWN_GIL workers bind different epochs. A separately bound main-interpreter
  parent **uses the first child's pluginId**, proving that a pluginId-keyed
  token registry would be incorrect. It is checked before/after them using a
  temporary explicitly attached thread state, never `PyGILState_Ensure`.
  Peer activity cannot change either
  worker's token; changing a test handle realm cannot change its epoch.
  Final worker teardown is ordered: the second worker completes its native
  epoch check before the first worker's detach-in-callback test uninstalls the
  process dispatcher.

The standalone entry point remains `EXL_BRIDGE_CALLBACK_PROBE_MAIN`:

```text
bridge-callback-probe report.json python-root [python-home]
```

Run it in a fresh process with an external **30-second hard timeout**, preferably
`EXL_ENGINE_DEBUG_MEMORY=1`. It uses only local test objects and virtualjava, not
SDK plugins or network effects. Its report includes `baseline_callbacks`,
`owner_bound_callbacks`, `owner_token_authoritative`, `unbound_owner_token_removed`,
`immutable_owner_token`, `canonical_owner_token`, `owner_token_validation`,
`isolated_owner_tokens`, `parent_owner_isolated`, and `owner_bound_seven_ops`.

Observed locally on 2026-11-15: **213 native-dispatch calls passed** on Windows
CPython **3.12.10** with the debug allocator, including the unchanged **169-call
baseline** and **35 bound-epoch calls**. Parent/child isolation, all owner checks,
rollback cases, and finalization passed. The separate desktop bridge regression
run reported **24 passed, 1 skipped** (the `concurrent.interpreters` test requires
Python 3.14; OWN_GIL behavior here is covered by the C probe). Both processes had
an external 30-second timeout. New owner-token cases have not been run on iOS.

### Deep-native source fingerprint

`tools/runtime/validate_runtime.py::source_fingerprint` hashes **all** `.c`, `.h`,
`.m`, and `.modulemap` files under `python/runtime`, plus the root bridge source
and its other declared inputs. The changed bridge header and callback probe are
therefore part of the native build/probe identity, not only
`_exteraless_bridge.c`. New owner-token cases require a freshly compiled matching
runtime artifact. Do not reuse the earlier green 169-call artifact or adjust its
fingerprint to match WIP sources. This change does not modify workflows/validators.

## P2 bulk-clear remediation

The independently reproduced reentrant-clear ownership leak has a separate
[remediation and re-review handoff](native-owner-token-remediation.md). It records
detach-before-DECREF, terminal admission closure, the backend GC ownership fix,
and fresh **219-call / 27-entry-point / weakref** results with a matching full
native fingerprint. The independent review report remains unchanged.
